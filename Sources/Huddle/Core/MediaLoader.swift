import AppKit
import MatrixRustSDK

/// Fetches (and decrypts) thumbnails through the SDK, with an in-memory cache.
final class MediaLoader: @unchecked Sendable {
    private let client: Client
    private let cache = NSCache<NSString, NSImage>()

    init(client: Client) {
        self.client = client
        cache.totalCostLimit = 64 * 1024 * 1024
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
