import AppKit
import ImageIO
import MatrixRustSDK
import UniformTypeIdentifiers

/// An image message as the timeline shows it.
struct ImageAttachment: Equatable {
    let media: MediaRef
    /// A smaller copy the sender made. In encrypted rooms the server can't make one, so this is
    /// the only way to show the picture without downloading all of it.
    let thumbnail: MediaRef?
    /// The thumbnail's size, as the sender reported it.
    let thumbnailPixelSize: CGSize?
    let filename: String
    let caption: String?
    /// As the sender reported it; nil if they didn't.
    let pixelSize: CGSize?
    let mimetype: String?
    let byteCount: UInt64?
    /// A blurred stand-in to show while the picture loads.
    let blurhash: String?
    let isAnimated: Bool
    let isSticker: Bool

    init(_ content: ImageMessageContent) {
        self.init(source: content.source, info: content.info, filename: content.filename,
                  caption: content.caption, isSticker: false)
    }

    /// For an image still waiting to be uploaded. It has no address yet, so it gets one of its
    /// own that nothing will ever be fetched from.
    init(staged: StagedImage, caption: String?, id: UUID) {
        media = MediaRef(source: try! MediaSource.fromUrl(url: "mxc://queued.invalid/\(id.uuidString)"))
        thumbnail = nil
        thumbnailPixelSize = nil
        filename = staged.filename
        self.caption = caption
        pixelSize = staged.pixelSize
        mimetype = staged.mimetype
        byteCount = UInt64(staged.data.count)
        blurhash = staged.blurhash
        isAnimated = staged.isAnimated
        isSticker = false
    }

    init(sticker source: MediaSource, info: ImageInfo, name: String) {
        self.init(source: source, info: info, filename: name, caption: nil, isSticker: true)
    }

    private init(source: MediaSource, info: ImageInfo?, filename: String, caption: String?, isSticker: Bool) {
        media = MediaRef(source: source)
        thumbnail = info?.thumbnailSource.map(MediaRef.init(source:))
        if let width = info?.thumbnailInfo?.width, let height = info?.thumbnailInfo?.height, width > 0, height > 0 {
            thumbnailPixelSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        } else {
            thumbnailPixelSize = nil
        }
        self.filename = filename
        self.caption = caption
        if let width = info?.width, let height = info?.height, width > 0, height > 0 {
            pixelSize = CGSize(width: CGFloat(width), height: CGFloat(height))
        } else {
            pixelSize = nil
        }
        mimetype = info?.mimetype
        byteCount = info?.size
        blurhash = info?.blurhash
        isAnimated = info?.isAnimated ?? (info?.mimetype == "image/gif")
        self.isSticker = isSticker
    }

    // MARK: Layout

    /// Largest an image is drawn in the timeline, in points.
    static let maximumSize = CGSize(width: 360, height: 300)
    /// Even a sliver of an image (a very tall screenshot, a panorama) stays big enough to click.
    private static let minimumSide: CGFloat = 72
    private static let stickerSide: CGFloat = 128

    /// How big to draw the image, going by the size the sender reported.
    var displaySize: CGSize { displaySize(for: pixelSize) }

    /// How big to draw an image of this many pixels: its own size if that fits, otherwise scaled
    /// down to fit the box. Never scaled up. An extreme shape is cropped rather than reduced to
    /// a sliver.
    /// - Parameter maxWidth: the width there is room for, if less than the usual box.
    func displaySize(for pixelSize: CGSize?, maxWidth: CGFloat = .infinity) -> CGSize {
        Self.fitted(pixelSize, maxWidth: maxWidth, isSticker: isSticker)
    }

    /// How big to draw a picture (or a video) of this many pixels, as `displaySize(for:)` says.
    /// One of unknown size gets a frame of `unknownShape`, width to height.
    static func fitted(_ pixelSize: CGSize?, maxWidth: CGFloat = .infinity, isSticker: Bool = false,
                       unknownShape: CGFloat = 4 / 3, maxHeight: CGFloat = maximumSize.height) -> CGSize {
        let roomy = max(min(maxWidth, Self.maximumSize.width), 120)
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            let width = min(unknownShape > 1.5 ? 320 : 280, roomy)
            return CGSize(width: width, height: (width / unknownShape).rounded())
        }
        let limit = isSticker ? CGSize(width: Self.stickerSide, height: Self.stickerSide)
                              : CGSize(width: roomy, height: maxHeight)
        let scale = min(1, limit.width / pixelSize.width, limit.height / pixelSize.height)
        let fitted = CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        // Small images keep their size; only large ones squeezed thin by the box are widened.
        let floor = min(Self.minimumSide, max(pixelSize.width, pixelSize.height))
        return CGSize(width: min(max(fitted.width, min(floor, pixelSize.width)), limit.width).rounded(),
                      height: max(fitted.height, min(floor, pixelSize.height)).rounded())
    }

    /// The image's real size, judged from a copy of it that has been loaded (which may be
    /// smaller, but has the true shape). Nil if the reported size already has that shape.
    ///
    /// Senders get this wrong more often than you'd think: some report width and height the
    /// wrong way round, and phone photos are often stored on their side with a note saying
    /// which way up they go, and reported at their stored, sideways, size. Drawn by the reported
    /// size, such a photo gets a frame of the wrong shape and is cropped to fill it.
    func correctedPixelSize(seeing loaded: CGSize) -> CGSize? {
        guard loaded.width > 0, loaded.height > 0 else { return nil }
        guard let reported = pixelSize else { return loaded }
        guard !hasReportedShape(loaded) else { return nil }
        // Keep the reported scale: the loaded copy is usually a smaller thumbnail.
        let scale = max(reported.width, reported.height) / max(loaded.width, loaded.height)
        return CGSize(width: (loaded.width * scale).rounded(), height: (loaded.height * scale).rounded())
    }

    /// Whether a copy of this size has the same shape as the picture is reported to have.
    /// Unknown counts as yes: there is nothing to compare with.
    func hasReportedShape(_ size: CGSize) -> Bool {
        guard let reported = pixelSize, size.width > 0, size.height > 0 else { return true }
        let ratio = (size.width / size.height) / (reported.width / reported.height)
        return abs(ratio - 1) <= 0.04
    }

    /// A name to save or preview the image under, with an extension that matches what it is.
    var suggestedFilename: String {
        let base = (filename as NSString).lastPathComponent
        let type = mimetype.flatMap { UTType(mimeType: $0) }
        if !base.isEmpty, !(base as NSString).pathExtension.isEmpty { return base }
        let stem = base.isEmpty ? "Image" : base
        return type?.preferredFilenameExtension.map { "\(stem).\($0)" } ?? stem
    }
}

/// An image picked, pasted or dropped, made ready to send and waiting in the composer.
struct StagedImage: Identifiable, @unchecked Sendable {
    let id = UUID()
    let filename: String
    /// The bytes that will be uploaded.
    let data: Data
    let mimetype: String
    let pixelSize: CGSize
    let isAnimated: Bool
    /// A smaller JPEG or PNG for recipients to show in the timeline. Nil for an image that is
    /// small already, and for animations.
    let thumbnail: (data: Data, size: CGSize, mimetype: String)?
    let blurhash: String?
    /// For showing in the composer.
    let preview: NSImage
}

enum ImagePreparationError: Error, Equatable {
    case notAnImage(name: String)
    case tooLarge(name: String, limit: UInt64)

    var message: String {
        switch self {
        case .notAnImage(let name):
            return "“\(name)” isn’t an image Huddle can send."
        case .tooLarge(let name, let limit):
            let megabytes = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)
            return "“\(name)” is larger than this server accepts (\(megabytes))."
        }
    }
}

/// Where an image to send came from.
enum ImageSource {
    case file(URL)
    case data(Data, name: String)
}

/// Turns a picked, pasted or dropped image into what gets uploaded. Runs off the main thread.
enum ImagePreparer {
    /// Formats every Matrix client can show. Anything else (HEIC, TIFF, BMP) is converted.
    private static let sendableAsIs: [UTType] = [.jpeg, .png, .gif, .webP]
    private static let thumbnailSide = 800

    static func prepare(_ source: ImageSource, uploadLimit: UInt64?) throws -> StagedImage {
        switch source {
        case .file(let url):
            let name = url.lastPathComponent
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                throw ImagePreparationError.notAnImage(name: name)
            }
            return try prepare(data: data, name: name, uploadLimit: uploadLimit)
        case .data(let data, let name):
            return try prepare(data: data, name: name, uploadLimit: uploadLimit)
        }
    }

    private static func prepare(data original: Data, name: String, uploadLimit: UInt64?) throws -> StagedImage {
        guard let source = CGImageSourceCreateWithData(original as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source) as String?,
              var type = UTType(identifier),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0 else {
            throw ImagePreparationError.notAnImage(name: name)
        }
        // Orientations 5 to 8 are the camera held sideways: the stored width is the shown height.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let pixelSize = orientation >= 5 ? CGSize(width: rawHeight, height: rawWidth) : CGSize(width: rawWidth, height: rawHeight)
        let largestSide = Int(max(pixelSize.width, pixelSize.height))

        // Whether any of it is see-through, as the file itself says. (A decoded image always
        // claims to have transparency, whether or not it uses it.)
        let hasTransparency = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false

        var data = original
        var filename = (name as NSString).lastPathComponent
        if !sendableAsIs.contains(type) {
            guard let image = scaled(source, to: largestSide) else { throw ImagePreparationError.notAnImage(name: name) }
            type = hasTransparency ? .png : .jpeg
            guard let converted = encode(image, as: type, quality: 0.9) else { throw ImagePreparationError.notAnImage(name: name) }
            data = converted
            // A new format needs a new extension; an image sent as it is keeps its name.
            let stem = (filename as NSString).deletingPathExtension
            filename = (stem.isEmpty ? "Image" : stem) + (type == .png ? ".png" : ".jpg")
        }
        if filename.isEmpty { filename = "Image." + (type.preferredFilenameExtension ?? "jpg") }
        let isAnimated = CGImageSourceGetCount(source) > 1 && sendableAsIs.contains(type) && type != .jpeg

        if let uploadLimit, uploadLimit > 0, UInt64(data.count) > uploadLimit {
            throw ImagePreparationError.tooLarge(name: name, limit: uploadLimit)
        }

        var thumbnail: (data: Data, size: CGSize, mimetype: String)?
        if !isAnimated, largestSide > thumbnailSide || data.count > 400_000,
           var small = scaled(source, to: min(thumbnailSide, largestSide)) {
            var reportedSize = CGSize(width: small.width, height: small.height)
            if DevHooks.cropsThumbnails {
                // Reported at its uncropped size, as the worst-behaved apps do, so that only
                // looking at the thumbnail itself gives it away.
                let side = min(small.width, small.height)
                small = small.cropping(to: CGRect(x: (small.width - side) / 2, y: (small.height - side) / 2,
                                                  width: side, height: side)) ?? small
            }
            let smallType: UTType = hasTransparency ? .png : .jpeg
            if let encoded = encode(small, as: smallType, quality: 0.8), encoded.count < data.count {
                if !DevHooks.cropsThumbnails { reportedSize = CGSize(width: small.width, height: small.height) }
                thumbnail = (encoded, reportedSize, smallType.preferredMIMEType ?? "image/jpeg")
            }
        }

        guard let previewImage = scaled(source, to: min(256, largestSide)) else {
            throw ImagePreparationError.notAnImage(name: name)
        }
        return StagedImage(
            filename: filename,
            data: data,
            mimetype: type.preferredMIMEType ?? "image/jpeg",
            pixelSize: pixelSize,
            isAnimated: isAnimated,
            thumbnail: thumbnail,
            blurhash: scaled(source, to: 32).flatMap { BlurHash.hash(for: $0) },
            preview: NSImage(cgImage: previewImage, size: CGSize(width: previewImage.width, height: previewImage.height)))
    }

    /// The image's first frame, turned the right way up, no larger than `side` pixels on its
    /// longer edge. Decodes straight to that size, which is far cheaper than decoding in full.
    static func scaled(_ source: CGImageSource, to side: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func scaled(_ data: Data, to side: Int) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { scaled($0, to: side) }
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

/// Reads images off a pasteboard (a paste, or something being dragged in), and puts one on it.
enum ImagePasteboard {
    private static let dataTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"), (.tiff, "tiff"),
    ]

    /// The images a pasteboard offers: image files if it has any, otherwise picture data.
    ///
    /// Picture data that comes with ordinary text is left alone, because that is what copying
    /// from a word processor or spreadsheet looks like, and there the text is what is wanted.
    /// Text that is just a web address doesn't count: browsers add it when an image is copied.
    static func images(on pasteboard: NSPasteboard) -> [ImageSource] {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let imageFiles = urls.filter { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
        }
        if !imageFiles.isEmpty { return imageFiles.map(ImageSource.file) }
        guard urls.isEmpty else { return [] }      // files, but not pictures

        guard let (type, fileExtension) = dataTypes.first(where: { pasteboard.data(forType: $0.0) != nil }),
              let data = pasteboard.data(forType: type) else { return [] }
        if let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let isAddress = !text.contains(where: \.isWhitespace) && ["http", "https", "file", "data"].contains(URL(string: text)?.scheme ?? "")
            if !isAddress { return [] }
        }
        return [.data(data, name: "Pasted image.\(fileExtension)")]
    }

    /// Puts a picture on the general pasteboard, as other apps expect to find one.
    @MainActor
    static func copy(_ data: Data) {
        guard let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}
