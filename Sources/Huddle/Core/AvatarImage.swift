import AppKit
import ImageIO
import MatrixRustSDK
import UniformTypeIdentifiers

/// A picture made ready to be a room's or a person's: the middle square of it, scaled to 512
/// pixels across (or less, if smaller), as JPEG, or PNG if it has see-through parts.
struct AvatarImage {
    let data: Data
    let mimeType: String
    let info: ImageInfo
    /// For showing before it's uploaded.
    let preview: NSImage

    init(contentsOf url: URL) throws {
        let file = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(file as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary),
              let square = Self.squared(image, side: 512) else {
            throw AvatarImageError.unreadable
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(square.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        guard let encoded = ImagePreparer.encode(square, as: type, quality: 0.85) else {
            throw AvatarImageError.unreadable
        }
        data = encoded
        mimeType = type.preferredMIMEType ?? "image/jpeg"
        info = ImageInfo(height: UInt64(square.height), width: UInt64(square.width), mimetype: mimeType,
                         size: UInt64(encoded.count), thumbnailInfo: nil, thumbnailSource: nil,
                         blurhash: nil, isAnimated: false)
        preview = NSImage(cgImage: square, size: NSSize(width: square.width, height: square.height))
    }

    /// The middle square of a picture, scaled to `side` pixels across (or less, if smaller),
    /// with see-through parts only if the picture had any.
    private static func squared(_ image: CGImage, side: Int) -> CGImage? {
        let length = min(image.width, image.height)
        let crop = CGRect(x: (image.width - length) / 2, y: (image.height - length) / 2, width: length, height: length)
        guard let cropped = image.cropping(to: crop) else { return nil }
        let target = min(side, length)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: alpha.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        return context.makeImage()
    }
}

enum AvatarImageError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable: "That picture couldn't be read. Try a JPEG, PNG or HEIC image."
        }
    }
}
