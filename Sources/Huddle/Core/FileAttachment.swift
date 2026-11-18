import AppKit
import AVFoundation
import MatrixRustSDK
import UniformTypeIdentifiers

/// A file in a message, shown as a tile to open or save: a document, an archive, a video, or
/// anything else that isn't drawn in place.
struct FileAttachment: Equatable {
    /// Where it is on the server; nil for one still waiting to be sent from here.
    let media: MediaRef?
    let filename: String
    let caption: String?
    let mimetype: String?
    let size: UInt64?
    let isVideo: Bool

    init(_ content: FileMessageContent) {
        media = MediaRef(source: content.source)
        filename = content.filename
        caption = content.caption
        mimetype = content.info?.mimetype
        size = content.info?.size
        isVideo = false
    }

    init(_ content: VideoMessageContent) {
        media = MediaRef(source: content.source)
        filename = content.filename
        caption = content.caption
        mimetype = content.info?.mimetype
        size = content.info?.size
        isVideo = true
    }

    /// One of ours, waiting in the queue to be sent.
    init(staged: StagedFile, caption: String?) {
        media = nil
        filename = staged.filename
        self.caption = caption
        mimetype = staged.mimetype
        size = staged.size
        isVideo = staged.kind.isVideo
    }

    /// What kind of file it is: by its name, or failing that, by its MIME type.
    var type: UTType? {
        let ext = (filename as NSString).pathExtension
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext)) ?? mimetype.flatMap { UTType(mimeType: $0) }
    }

    /// "2.4 MB · PDF document", or what of it is known.
    var details: String {
        let size = size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [size, type?.localizedDescription].compactMap { $0 }.joined(separator: " · ")
    }

    /// The icon Finder shows for files of its kind.
    var icon: NSImage { NSWorkspace.shared.icon(for: type ?? (isVideo ? .movie : .data)) }

    /// The name to suggest when saving: the sender's, made safe (no invisible characters
    /// turning the extension round, no folders).
    var safeFilename: String {
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        let cleaned = String(String.UnicodeScalarView(filename.unicodeScalars.filter { !invisible.contains($0) }))
        let name = (cleaned as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.hasPrefix(".") ? "File" + name : name
    }
}

/// A file picked, dropped or pasted, waiting in the composer to be sent. It stays on disk until
/// it is: the upload reads it from there, so a large one is never held in memory.
struct StagedFile: Identifiable, Sendable {
    enum Kind: Sendable {
        case file
        /// Sent as a video or audio message, so other apps can play it in place.
        case video(duration: TimeInterval?, size: CGSize?)
        case audio(duration: TimeInterval?)

        var isVideo: Bool { if case .video = self { true } else { false } }
    }

    let id = UUID()
    let url: URL
    let filename: String
    let size: UInt64
    let mimetype: String
    let kind: Kind

    var type: UTType? { UTType(filenameExtension: url.pathExtension) }
}

enum FilePreparationError: Error, Equatable {
    case unreadable(name: String)
    case folder(name: String)
    case empty(name: String)
    case tooLarge(name: String, limit: UInt64)

    var message: String {
        switch self {
        case .unreadable(let name): "“\(name)” couldn't be read."
        case .folder(let name): "“\(name)” is a folder. Compress it first to send it as one file."
        case .empty(let name): "“\(name)” is empty."
        case .tooLarge(let name, let limit):
            "“\(name)” is larger than this server accepts (\(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)))."
        }
    }
}

/// Readies a file to send: what it is, how big, and for a video or recording, how long and how
/// large it plays, which apps show before downloading it.
enum FilePreparer {
    static func prepare(_ url: URL, uploadLimit: UInt64?) async throws -> StagedFile {
        let name = url.lastPathComponent
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey]) else {
            throw FilePreparationError.unreadable(name: name)
        }
        if values.isDirectory == true { throw FilePreparationError.folder(name: name) }
        guard let size = values.fileSize.map(UInt64.init), FileManager.default.isReadableFile(atPath: url.path) else {
            throw FilePreparationError.unreadable(name: name)
        }
        guard size > 0 else { throw FilePreparationError.empty(name: name) }
        if let uploadLimit, size > uploadLimit { throw FilePreparationError.tooLarge(name: name, limit: uploadLimit) }

        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        let mimetype = type.preferredMIMEType ?? "application/octet-stream"
        var kind = StagedFile.Kind.file
        if type.conforms(to: .movie) || type.conforms(to: .audio) {
            let asset = AVURLAsset(url: url)
            let duration = try? await asset.load(.duration).seconds
            let seconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            if type.conforms(to: .movie) {
                let track = try? await asset.loadTracks(withMediaType: .video).first
                var dimensions: CGSize?
                if let track, let natural = try? await track.load(.naturalSize),
                   let transform = try? await track.load(.preferredTransform) {
                    let turned = natural.applying(transform)
                    dimensions = CGSize(width: abs(turned.width), height: abs(turned.height))
                }
                // A movie the system can't read (or one with no picture) still goes, as a file.
                if track != nil { kind = .video(duration: seconds, size: dimensions) }
            } else if seconds != nil {
                kind = .audio(duration: seconds)
            }
        }
        return StagedFile(url: url, filename: name, size: size, mimetype: mimetype, kind: kind)
    }
}

/// Opening and saving the files people send.
extension MediaLoader {
    /// Downloads a file to a folder of Huddle's own, only this user can read, marked as
    /// downloaded (so macOS checks it before anything opens it), and opens it in its usual app.
    func open(_ file: FileAttachment) async throws {
        guard let media = file.media else { return }
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "app.huddle.Huddle") + ".files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(file.safeFilename)
        try await download(media, mimetype: file.mimetype, to: url)
        _ = await MainActor.run { NSWorkspace.shared.open(url) }
    }

    /// Downloads a file, decrypted, to `destination`, marked as downloaded.
    func download(_ media: MediaRef, mimetype: String?, to destination: URL) async throws {
        let handle = try await client.getMediaFile(mediaSource: media.source, filename: destination.lastPathComponent,
                                                   mimeType: mimetype ?? "application/octet-stream",
                                                   useCache: false, tempDir: nil)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
        guard try handle.persist(path: destination.path) else { throw AudioLoadError.download }
        var marked = destination
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Huddle",
                                       kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload]
        try? marked.setResourceValues(values)
    }

    /// Clears files downloaded for opening more than a day ago: anything worth keeping was saved
    /// somewhere with Save File As. Newer ones may still be open in another app.
    static func clearOpenedFiles() {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "app.huddle.Huddle") + ".files", isDirectory: true)
        guard let downloads = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let dayAgo = Date().addingTimeInterval(-24 * 3600)
        for download in downloads {
            let made = (try? download.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if made < dayAgo { try? manager.removeItem(at: download) }
        }
    }
}
