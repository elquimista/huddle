import AppKit
import AVFoundation
import MatrixRustSDK
import Observation

/// What a video message says about the film before it's downloaded, as the sender reported it.
struct VideoDetails: Equatable {
    /// A still the sender made, shown until the video is played.
    let thumbnail: MediaRef?
    let thumbnailPixelSize: CGSize?
    let pixelSize: CGSize?
    let duration: TimeInterval?
    /// A blurred stand-in for the still, while that loads.
    let blurhash: String?
    /// For a video being sent from here: the film itself, on this Mac.
    let localURL: URL?

    static func size(_ width: UInt64?, _ height: UInt64?) -> CGSize? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    /// "0:42", "12:05", "1:02:03".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
                         : String(format: "%d:%02d", minutes, rest)
    }
}

/// A still from a video being sent, which goes with it as its thumbnail: other apps show it, and
/// its blur, until the video is played.
struct VideoPoster: Sendable {
    /// JPEG.
    let data: Data
    let pixelSize: CGSize
    let blurhash: String?

    static func make(from asset: AVAsset) async -> VideoPoster? {
        guard let still = await still(of: asset, side: 800),
              let data = ImagePreparer.encode(still, as: .jpeg, quality: 0.8) else { return nil }
        return VideoPoster(data: data, pixelSize: CGSize(width: still.width, height: still.height),
                           blurhash: ImagePreparer.scaled(data, to: 32).flatMap { BlurHash.hash(for: $0) })
    }

    /// The film's opening picture, turned the way it plays, no larger than `side` pixels on its
    /// longer edge: what the player shows before it starts, so the two match.
    static func still(of asset: AVAsset, side: Int) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        // The nearest frame that can be decoded on its own will do, rather than decoding up to it.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: .zero).image
    }
}

enum VideoPlayError: Error {
    case download
    /// Downloaded, but not something macOS can play.
    case unplayable
}

/// Videos downloaded (and decrypted) for playing, kept on disk so playing one again, or taking
/// its still, doesn't fetch it again. Each file goes when its handle does, which the SDK made
/// in a folder of its own; the oldest go once they add up to more than a gigabyte.
actor VideoFiles {
    private struct Entry {
        let handle: MediaFileHandle
        let url: URL
        let bytes: UInt64
    }

    private var entries: [String: Entry] = [:]
    /// Keys, least recently used first.
    private var order: [String] = []
    private var downloads: [String: Task<Entry, Error>] = [:]
    private static let limit: UInt64 = 1 << 30

    /// The video on disk, if it has been downloaded.
    func downloaded(_ media: MediaRef) -> URL? {
        entries[media.source.url()]?.url
    }

    /// The video on disk, downloaded first if need be. Asked for twice at once, it's fetched once.
    func file(for media: MediaRef, named filename: String, mimetype: String, client: Client) async throws -> URL {
        let key = media.source.url()
        if let entry = entries[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return entry.url
        }
        let download = downloads[key] ?? Task {
            // Named with its extension, which is how the player knows what kind of film it is.
            let handle = try await client.getMediaFile(mediaSource: media.source, filename: filename,
                                                       mimeType: mimetype, useCache: false, tempDir: nil)
            let url = URL(fileURLWithPath: try handle.path())
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
            guard bytes > 0 else { throw VideoPlayError.download }
            return Entry(handle: handle, url: url, bytes: bytes)
        }
        downloads[key] = download
        defer { downloads[key] = nil }
        let entry = try await download.value
        if entries[key] == nil {
            entries[key] = entry
            order.append(key)
            trim()
        }
        return entries[key]?.url ?? entry.url
    }

    private func trim() {
        var total = entries.values.reduce(0) { $0 + $1.bytes }
        // The newest stays whatever its size: it's the one wanted now.
        while total > Self.limit, order.count > 1 {
            let oldest = order.removeFirst()
            total -= entries.removeValue(forKey: oldest)?.bytes ?? 0
        }
    }
}

/// Plays video messages in the conversation, one at a time, for the whole app: starting one
/// stops another, and an audio message, which stops a video in turn.
@MainActor @Observable
final class VideoPlayback {
    static let shared = VideoPlayback()

    enum Phase: Equatable {
        /// Downloading, or finding out whether it plays.
        case loading
        case ready
    }

    /// The message whose video is loaded or loading.
    private(set) var currentID: String?
    private(set) var phase: Phase?
    private(set) var player: AVPlayer?
    /// Why a message's video wouldn't play, by message, until it's tried again.
    private(set) var failures: [String: VideoPlayError] = [:]
    /// The size films turned out to be once played, by address, for those whose sender didn't
    /// say or said wrongly: their frame takes that shape from then on.
    private(set) var shapes: [String: CGSize] = [:]
    /// Likewise their length, for those sent without one.
    private(set) var durations: [String: TimeInterval] = [:]

    @ObservationIgnored private var loading: Task<Void, Never>?
    /// The timeline the video was started from, so leaving it can stop it.
    @ObservationIgnored private var owner: ObjectIdentifier?
    /// Goes up whenever what is loaded changes; late answers about older videos are dropped.
    @ObservationIgnored private var session = 0
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var endObserver: NSObjectProtocol?

    func phase(of id: String) -> Phase? { currentID == id ? phase : nil }

    /// Plays a message's video, downloading it first. Asked again while it downloads, gives up.
    func play(id: String, file: FileAttachment, media: MediaLoader, owner: AnyObject) {
        if currentID == id, phase == .loading {
            stop()
            return
        }
        stop()
        let session = session
        currentID = id
        phase = .loading
        failures[id] = nil
        self.owner = ObjectIdentifier(owner)
        AudioPlayback.shared.stop()

        loading = Task { [weak self] in
            do {
                let url = try await media.videoFile(for: file)
                let asset = AVURLAsset(url: url)
                guard (try? await asset.load(.isPlayable)) == true else { throw VideoPlayError.unplayable }
                let shape = await Self.shape(of: asset)
                let duration = (try? await asset.load(.duration))?.seconds
                guard let self, self.session == session else { return }
                if let key = file.media?.source.url() {
                    if let shape, !Self.sameShape(shape, file.video?.pixelSize) { self.shapes[key] = shape }
                    if file.video?.duration == nil, let duration, duration.isFinite, duration > 0 {
                        self.durations[key] = duration
                    }
                }
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player.isMuted = DevHooks.mutesAudio
                self.watch(player)
                self.player = player
                self.phase = .ready
                player.play()
            } catch {
                guard let self, self.session == session, !Task.isCancelled else { return }
                let failure = error as? VideoPlayError ?? .download
                self.stop()
                self.failures[id] = failure
            }
        }
    }

    /// The film's size as it plays, turned the way its camera was held.
    private static func shape(of asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let turned = natural.applying(transform)
        let size = CGSize(width: abs(turned.width), height: abs(turned.height))
        return size.width > 0 && size.height > 0 ? size : nil
    }

    private static func sameShape(_ size: CGSize, _ reported: CGSize?) -> Bool {
        guard let reported else { return false }
        return abs((size.width / size.height) / (reported.width / reported.height) - 1) <= 0.04
    }

    /// Pauses the video playing, leaving it where it is: for an audio message starting.
    func pause() {
        player?.pause()
    }

    func stop() {
        session += 1
        loading?.cancel()
        loading = nil
        observations = []
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        currentID = nil
        phase = nil
        owner = nil
    }

    /// Stops the video if it was started from this timeline, which is going away.
    func stop(owner: AnyObject) {
        if self.owner == ObjectIdentifier(owner) { stop() }
    }

    /// Whichever way it's started (here, or the player's own controls), it stops audio playing;
    /// and at its end it goes back to the start, ready to play again.
    private func watch(_ player: AVPlayer) {
        observations = [player.observe(\.timeControlStatus) { player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor in AudioPlayback.shared.stop() }
        }]
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
        }
    }
}

extension MediaLoader {
    /// A video, on disk, to play.
    func videoFile(for file: FileAttachment) async throws -> URL {
        if let local = file.video?.localURL { return local }
        guard let media = file.media else { throw VideoPlayError.download }
        do {
            return try await videoFiles.file(for: media, named: Self.playableName(for: file),
                                             mimetype: file.mimetype ?? "video/mp4", client: client)
        } catch let error as VideoPlayError {
            throw error
        } catch {
            throw VideoPlayError.download
        }
    }

    /// The sender's name for it, with an extension saying what it is if it lacks one.
    private static func playableName(for file: FileAttachment) -> String {
        let name = file.safeFilename
        guard (name as NSString).pathExtension.isEmpty else { return name }
        let ext = file.mimetype.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? "mp4"
        return "\(name).\(ext)"
    }

    /// Videos no larger than this have their still taken from the film itself, downloading it
    /// unasked, when the sender didn't send one. Larger ones wait to be played.
    static let largestPosterDownload: UInt64 = 20 * 1024 * 1024

    /// A video's still, if it has been made already: for drawing it in the first frame its
    /// message is drawn in, rather than a frame later.
    func cachedVideoPoster(for file: FileAttachment, side: Int) -> NSImage? {
        guard let video = file.video else { return nil }
        let id = file.media?.source.url() ?? video.localURL?.absoluteString ?? file.filename
        return cachedImage(forKey: "\(id)#poster\(side)")
    }

    /// A still for a video, about `side` pixels on its longer edge: the sender's, or else one
    /// taken from the film, if it's here already, or small enough to fetch.
    func videoPoster(for file: FileAttachment, side: Int) async -> NSImage? {
        guard let video = file.video else { return nil }
        let id = file.media?.source.url() ?? video.localURL?.absoluteString ?? file.filename
        if let cached = cachedVideoPoster(for: file, side: side) { return cached }
        var still: CGImage?
        if let thumbnail = video.thumbnail,
           let data = try? await client.getMediaContent(mediaSource: thumbnail.source) {
            still = ImagePreparer.scaled(data, to: side)
        }
        if still == nil {
            var url = video.localURL
            if url == nil, let media = file.media {
                url = await videoFiles.downloaded(media)
                if url == nil, let size = file.size, size <= Self.largestPosterDownload {
                    url = try? await videoFile(for: file)
                }
            }
            if let url { still = await VideoPoster.still(of: AVURLAsset(url: url), side: side) }
        }
        guard let still else { return nil }
        let image = NSImage(cgImage: still, size: CGSize(width: still.width, height: still.height))
        storeImage(image, forKey: "\(id)#poster\(side)", cost: still.width * still.height * 4)
        return image
    }
}
