import AppKit
import ImageIO
import MatrixRustSDK

/// Fetches (and decrypts) thumbnails through the SDK, with an in-memory cache.
final class MediaLoader: @unchecked Sendable {
    let client: Client
    private let cache = NSCache<NSString, NSImage>()
    /// Audio files as sent, and what the player plays (the same bytes, or a decoded copy).
    private let audioFiles = NSCache<NSString, NSData>()
    private let playableFiles = NSCache<NSString, NSData>()
    /// Images as sent, for the full-size viewer and for animations.
    private let imageFiles = NSCache<NSString, NSData>()
    /// Videos downloaded for playing (VideoPlayback.swift).
    let videoFiles = VideoFiles()
    /// What files really weigh, for those downloaded unasked.
    let sizes = MediaSizes()
    private let knownUploadLimit = Locked<UInt64?>(nil)

    init(client: Client) {
        self.client = client
        cache.totalCostLimit = 64 * 1024 * 1024
        audioFiles.totalCostLimit = 48 * 1024 * 1024
        playableFiles.totalCostLimit = 96 * 1024 * 1024
        imageFiles.totalCostLimit = 96 * 1024 * 1024
    }

    // MARK: Images

    /// What a picture came to for the timeline.
    enum DisplayImage {
        case shown(NSImage)
        /// Not shown until asked for, being too large (`Withheld`).
        case withheld(Withheld)
        case failed

        var image: NSImage? {
            if case .shown(let image) = self { image } else { nil }
        }
    }

    /// Why a picture wasn't downloaded, or decoded, without being asked for.
    enum Withheld: Equatable {
        /// The file is larger than is downloaded unasked: this many bytes.
        case bytes(UInt64)
        /// The picture has more pixels than are decoded unasked. A small file can unpack to
        /// gigabytes: a 190 KB PNG of 40,000 × 40,000 one-bit pixels took 1.5 GB to scale down.
        case pixels(width: Int, height: Int)

        /// Whether Huddle shows it at all, when asked: not one of more than `largestShownPixels`.
        var canBeShown: Bool {
            guard case .pixels(let width, let height) = self else { return true }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            return !overflow && pixels <= MediaLoader.largestShownPixels
        }
    }

    private enum Refusal: Error {
        case withheld(Withheld)
    }

    /// Pictures larger than this are shown when clicked rather than downloaded unasked (when the
    /// server can't make a smaller copy, as in encrypted rooms).
    static let largestAutomaticPicture: UInt64 = 20 * 1024 * 1024
    /// A thumbnail larger than this is no thumbnail: the picture itself is used instead.
    static let largestAutomaticThumbnail: UInt64 = 2 * 1024 * 1024
    /// Pictures with more pixels than this (64 megapixels: a 48-megapixel phone photo, or a
    /// panorama, fits) are decoded only when asked for. Some formats are decoded whole even to
    /// be scaled down, which at this size is up to 256 MB.
    static let largestAutomaticPixels = 64 * 1024 * 1024
    /// Pictures with more pixels than this (256 megapixels: 16,384 × 16,384) aren't decoded even
    /// when asked for, in the conversation or the viewer: that could be a gigabyte. They can be
    /// saved, and opened in another app.
    static let largestShownPixels = 256 * 1024 * 1024

    /// A picture decoded at the size the timeline draws it. A large photo is never decoded in
    /// full for this: that would cost tens of megabytes of memory per picture.
    ///
    /// - Parameters:
    ///   - side: the longer edge wanted, in pixels.
    ///   - isLocal: the image is being sent from here and isn't on the server yet.
    ///   - askedFor: the user clicked to see it, whatever its size.
    func displayImage(for image: ImageAttachment, side: Int, isLocal: Bool, askedFor: Bool = false) async -> DisplayImage {
        let key = Self.displayKey(for: image, side: side) as NSString
        if let cached = cache.object(forKey: key) { return .shown(cached) }
        if DevHooks.imageLoadDelay > 0 { try? await Task.sleep(for: .seconds(DevHooks.imageLoadDelay)) }

        let unasked = !isLocal && !askedFor
        // One being sent from here was checked as it was chosen.
        let pixelLimit = isLocal ? nil : (unasked ? Self.largestAutomaticPixels : Self.largestShownPixels)
        do {
            let (data, isWhole) = try await displayData(for: image, side: side, isLocal: isLocal, unasked: unasked,
                                                        pixelLimit: pixelLimit)
            guard var scaled = ImagePreparer.scaled(data, to: side) else { return .failed }
            // A smaller copy that isn't the shape of the picture is either cropped (some apps
            // make their thumbnails by cutting a square out of the middle) or the picture's
            // reported size is wrong. The picture itself settles which, and is what gets shown,
            // if it may be fetched.
            if !isWhole, !image.hasReportedShape(CGSize(width: scaled.width, height: scaled.height)),
               let whole = try? await wholePicture(image, unasked: unasked, pixelLimit: pixelLimit),
               let rescaled = ImagePreparer.scaled(whole, to: side) {
                scaled = rescaled
            }
            let result = NSImage(cgImage: scaled, size: CGSize(width: scaled.width, height: scaled.height))
            cache.setObject(result, forKey: key, cost: scaled.width * scaled.height * 4)
            return .shown(result)
        } catch Refusal.withheld(let reason) {
            return .withheld(reason)
        } catch {
            return .failed
        }
    }

    /// The smallest download that will do for the timeline, and whether it is the whole picture
    /// rather than a smaller copy of it.
    private func displayData(for image: ImageAttachment, side: Int, isLocal: Bool, unasked: Bool,
                             pixelLimit: Int?) async throws -> (Data, Bool) {
        let isEncrypted = image.media.source.toJson().contains("\"key\"")
        if isLocal || isEncrypted {
            // The server can't scale these: one is still on this Mac, the other it can't read.
            // The sender's own thumbnail will do if it is sharp enough for the size wanted, and
            // the same shape as the picture.
            if let thumbnail = image.thumbnail,
               isLocal || ((image.thumbnailPixelSize.map { max($0.width, $0.height) } ?? 0) >= CGFloat(side) * 0.6
                           && image.hasReportedShape(image.thumbnailPixelSize ?? .zero)),
               let data = await senderThumbnail(thumbnail.source, claimed: image.thumbnailByteCount, unasked: unasked,
                                                pixelLimit: pixelLimit) {
                return (data, false)
            }
            return (try await wholePicture(image, unasked: unasked, pixelLimit: pixelLimit), true)
        }
        // The server's own copy, made by it, though a server that can't make one may send the
        // picture itself.
        if let data = try? await client.getMediaThumbnail(mediaSource: image.media.source, width: UInt64(side), height: UInt64(side)),
           Self.fits(data, pixelLimit) {
            return (data, false)
        }
        return (try await wholePicture(image, unasked: unasked, pixelLimit: pixelLimit), true)
    }

    /// A thumbnail its sender made, if it is small enough to fetch (unasked) and decode. Nil
    /// otherwise, and the picture itself is used.
    private func senderThumbnail(_ source: MediaSource, claimed: UInt64?, unasked: Bool, pixelLimit: Int?) async -> Data? {
        if unasked, await exceeds(source, claimed: claimed, limit: Self.largestAutomaticThumbnail) != nil { return nil }
        guard let data = try? await client.getMediaContent(mediaSource: source), Self.fits(data, pixelLimit) else { return nil }
        return data
    }

    /// The whole picture: only if the file isn't too large to download unasked, and the picture
    /// in it has no more pixels than `pixelLimit`.
    private func wholePicture(_ image: ImageAttachment, unasked: Bool, pixelLimit: Int?) async throws -> Data {
        let source = image.media.source
        if unasked, imageFiles.object(forKey: source.url() as NSString) == nil,
           let size = await exceeds(source, claimed: image.byteCount, limit: Self.largestAutomaticPicture) {
            throw Refusal.withheld(.bytes(size))
        }
        let data = try await imageFile(source: source)
        if let pixelLimit, let pixels = Self.excessPixels(in: data, limit: pixelLimit) { throw Refusal.withheld(pixels) }
        return data
    }

    private static func fits(_ data: Data, _ pixelLimit: Int?) -> Bool {
        pixelLimit.map { excessPixels(in: data, limit: $0) == nil } ?? true
    }

    /// The file's size, if it is larger than `limit`: by the server's word where it gives one,
    /// as the message's is only its sender's. One the sender says is too large is taken at
    /// their word.
    func exceeds(_ source: MediaSource, claimed: UInt64?, limit: UInt64) async -> UInt64? {
        if let claimed, claimed > limit { return claimed }
        guard let size = await sizes.size(of: source, client: client) else { return nil }
        return size > limit ? size : nil
    }

    /// The picture's size, read from its header, if it has more pixels than `limit` (by default,
    /// those decoded unasked).
    nonisolated static func excessPixels(in data: Data, limit: Int = largestAutomaticPixels) -> Withheld? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        return overflow || pixels > limit ? .pixels(width: width, height: height) : nil
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
        let source = image.media.source
        guard image.isAnimated else { return nil }
        if imageFiles.object(forKey: source.url() as NSString) == nil,
           await exceeds(source, claimed: image.byteCount, limit: Self.largestAutoplay) != nil { return nil }
        guard let data = try? await imageFile(source: source),
              // The size the sender reported may be missing or wrong; the file's own counts.
              data.count <= Self.largestAutoplay,
              Self.decodes(data, within: Self.autoplayMemory) else { return nil }
        return NSImage(data: data)
    }

    /// Animations larger than this show their first frame until opened.
    static let largestAutoplay: UInt64 = 8 * 1024 * 1024
    /// What an animation playing in place may take decoded, and one opened in the viewer.
    static let autoplayMemory = 128 * 1024 * 1024
    static let viewerMemory = 512 * 1024 * 1024

    /// Whether an image, all its frames decoded, fits in `bytes`: read from its header before
    /// decoding, as a small file can unpack to gigabytes (a "decompression bomb").
    nonisolated static func decodes(_ data: Data, within bytes: Int) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        let frames = max(CGImageSourceGetCount(source), 1)
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels > 0 else { return false }
        let (total, overflowed) = pixels.multipliedReportingOverflow(by: frames * 4)
        return !overflowed && total <= bytes
    }

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

    /// A picture's copy for the timeline, if it has been made already: for drawing it in the
    /// first frame its message is drawn in, rather than a frame later.
    func cachedDisplayImage(for image: ImageAttachment, side: Int) -> NSImage? {
        cache.object(forKey: Self.displayKey(for: image, side: side) as NSString)
    }

    private static func displayKey(for image: ImageAttachment, side: Int) -> String {
        "\(image.media.source.url())#display\(side)"
    }

    func cachedImage(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func storeImage(_ image: NSImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
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
        // Decoded no larger than asked for: a server without thumbnails may send the original,
        // which could be huge.
        guard let data = try? await client.getMediaThumbnail(mediaSource: source, width: pixels, height: pixels),
              Self.excessPixels(in: data) == nil,
              let scaled = ImagePreparer.scaled(data, to: size * 2) else { return nil }
        let image = NSImage(cgImage: scaled, size: CGSize(width: scaled.width, height: scaled.height))
        // What it takes in memory, as the cache's limit means, not the compressed file's size.
        cache.setObject(image, forKey: key, cost: scaled.width * scaled.height * 4)
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
