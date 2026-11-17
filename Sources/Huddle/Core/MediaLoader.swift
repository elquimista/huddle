import AppKit
import MatrixRustSDK

/// Fetches (and decrypts) thumbnails through the SDK, with an in-memory cache.
final class MediaLoader: @unchecked Sendable {
    private let client: Client
    private let cache = NSCache<NSString, NSImage>()
    /// Audio files as sent, and what the player plays (the same bytes, or a decoded copy).
    private let audioFiles = NSCache<NSString, NSData>()
    private let playableFiles = NSCache<NSString, NSData>()

    init(client: Client) {
        self.client = client
        cache.totalCostLimit = 64 * 1024 * 1024
        audioFiles.totalCostLimit = 48 * 1024 * 1024
        playableFiles.totalCostLimit = 96 * 1024 * 1024
    }

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
