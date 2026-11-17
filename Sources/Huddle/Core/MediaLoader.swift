import AppKit
import MatrixRustSDK

/// Fetches (and decrypts) thumbnails through the SDK, with an in-memory cache.
final class MediaLoader: @unchecked Sendable {
    private let client: Client
    private let cache = NSCache<NSString, NSImage>()
    /// Audio files as sent, and what the player plays (the same bytes, or a decoded copy).
    private let audioFiles = NSCache<NSString, NSData>()
    private let playableFiles = NSCache<NSString, NSData>()
    /// Images as sent, for the full-size viewer and for animations.
    private let imageFiles = NSCache<NSString, NSData>()
    private let knownUploadLimit = Locked<UInt64?>(nil)

    init(client: Client) {
        self.client = client
        cache.totalCostLimit = 64 * 1024 * 1024
        audioFiles.totalCostLimit = 48 * 1024 * 1024
        playableFiles.totalCostLimit = 96 * 1024 * 1024
        imageFiles.totalCostLimit = 96 * 1024 * 1024
    }

    // MARK: Images

    /// A picture decoded at the size the timeline draws it. A large photo is never decoded in
    /// full for this: that would cost tens of megabytes of memory per picture.
    ///
    /// - Parameters:
    ///   - side: the longer edge wanted, in pixels.
    ///   - isLocal: the image is being sent from here and isn't on the server yet.
    func displayImage(for image: ImageAttachment, side: Int, isLocal: Bool) async -> NSImage? {
        let key = "\(image.media.source.url())#display\(side)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        if DevHooks.imageLoadDelay > 0 { try? await Task.sleep(for: .seconds(DevHooks.imageLoadDelay)) }

        guard let (data, isWhole) = await displayData(for: image, side: side, isLocal: isLocal),
              var scaled = ImagePreparer.scaled(data, to: side) else { return nil }
        // A smaller copy that isn't the shape of the picture is either cropped (some apps make
        // their thumbnails by cutting a square out of the middle) or the picture's reported size
        // is wrong. The picture itself settles which, and is what gets shown.
        if !isWhole, !image.hasReportedShape(CGSize(width: scaled.width, height: scaled.height)),
           let whole = try? await imageFile(source: image.media.source),
           let rescaled = ImagePreparer.scaled(whole, to: side) {
            scaled = rescaled
        }
        let result = NSImage(cgImage: scaled, size: CGSize(width: scaled.width, height: scaled.height))
        cache.setObject(result, forKey: key, cost: scaled.width * scaled.height * 4)
        return result
    }

    /// The smallest download that will do for the timeline, and whether it is the whole picture
    /// rather than a smaller copy of it.
    private func displayData(for image: ImageAttachment, side: Int, isLocal: Bool) async -> (Data, Bool)? {
        let isEncrypted = image.media.source.toJson().contains("\"key\"")
        if isLocal || isEncrypted {
            // The server can't scale these: one is still on this Mac, the other it can't read.
            // The sender's own thumbnail will do if it is sharp enough for the size wanted, and
            // the same shape as the picture.
            if let thumbnail = image.thumbnail,
               isLocal || ((image.thumbnailPixelSize.map { max($0.width, $0.height) } ?? 0) >= CGFloat(side) * 0.6
                           && image.hasReportedShape(image.thumbnailPixelSize ?? .zero)),
               let data = try? await client.getMediaContent(mediaSource: thumbnail.source) {
                return (data, false)
            }
            return (try? await imageFile(source: image.media.source)).map { ($0, true) }
        }
        if let data = try? await client.getMediaThumbnail(mediaSource: image.media.source, width: UInt64(side), height: UInt64(side)) {
            return (data, false)
        }
        return (try? await imageFile(source: image.media.source)).map { ($0, true) }
    }

    /// An image exactly as it was sent, for viewing at full size, copying, saving, or animating.
    func imageFile(source: MediaSource) async throws -> Data {
        let key = source.url() as NSString
        if let cached = imageFiles.object(forKey: key) { return cached as Data }
        guard let data = try? await client.getMediaContent(mediaSource: source), !data.isEmpty else {
            throw AudioLoadError.download
        }
        imageFiles.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// An animated image with all its frames, for playing in place. Nil if it is too big to be
    /// worth downloading unasked, or can't be had.
    func animatedImage(for image: ImageAttachment) async -> NSImage? {
        guard image.isAnimated, (image.byteCount ?? 0) <= Self.largestAutoplay,
              let data = try? await imageFile(source: image.media.source) else { return nil }
        return NSImage(data: data)
    }

    /// Animations larger than this show their first frame until opened.
    static let largestAutoplay: UInt64 = 8 * 1024 * 1024

    /// The largest file this account's server accepts, if it has been learnt yet. Asking for
    /// it also starts finding out, so it is there next time; nothing here waits on the network.
    var uploadLimit: UInt64? {
        if let known = knownUploadLimit.value { return known }
        Task.detached { [client, knownUploadLimit] in
            if let limit = try? await client.getMaxMediaUploadSize() { knownUploadLimit.value = limit }
        }
        return nil
    }

    // MARK: Audio

    /// An audio message's file exactly as it was sent, downloaded (and decrypted) once.
    func audioFile(source: MediaSource) async throws -> Data {
        let key = source.url() as NSString
        if let cached = audioFiles.object(forKey: key) { return cached as Data }
        guard let data = try? await client.getMediaContent(mediaSource: source), !data.isEmpty else {
            throw AudioLoadError.download
        }
        audioFiles.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    /// The same audio in a form `AVAudioPlayer` plays. Runs off the main thread.
    func playableAudio(source: MediaSource) async throws -> Data {
        let key = source.url() as NSString
        if let cached = playableFiles.object(forKey: key) { return cached as Data }
        let playable = try AudioPreparer.playableData(from: try await audioFile(source: source))
        playableFiles.setObject(playable as NSData, forKey: key, cost: playable.count)
        return playable
    }

    func cached(url: String, size: Int) -> NSImage? {
        cache.object(forKey: "\(url)#\(size)" as NSString)
    }

    func thumbnail(url: String, size: Int) async -> NSImage? {
        guard let source = try? MediaSource.fromUrl(url: url) else { return nil }
        return await thumbnail(source: source, size: size)
    }

    func thumbnail(source: MediaSource, size: Int) async -> NSImage? {
        let key = "\(source.url())#\(size)" as NSString
        if let image = cache.object(forKey: key) { return image }
        let pixels = UInt64(size * 2)
        guard let data = try? await client.getMediaThumbnail(mediaSource: source, width: pixels, height: pixels),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key, cost: data.count)
        return image
    }
}

/// A value that can be read and written from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
