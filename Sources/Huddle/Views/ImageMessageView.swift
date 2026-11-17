import AppKit
import SwiftUI

/// A picture in the timeline: a blurred stand-in while it loads, then the picture itself, sized
/// to fit without being enlarged. Animations play in place. Clicking opens it at full size.
struct ImageMessageView: View {
    let image: ImageAttachment
    let media: MediaLoader
    /// Set while this image is on its way out from this Mac.
    var sendState: MessageRow.SendState?
    /// How much has been uploaded, from 0 to 1, if known.
    var uploadProgress: Double?
    /// The picture itself, for an image that hasn't been handed over for upload yet.
    var localPreview: NSImage?
    /// Opens the image at full size. Given what is on screen now, to show until the rest loads.
    let open: (NSImage?) -> Void
    /// Stops the upload and removes the message. Nil once it has been sent.
    var cancelUpload: (() -> Void)?

    @State private var still: NSImage?
    /// The picture's true size, when the sender reported it wrongly.
    @State private var correctedSize: CGSize?
    @State private var animation: NSImage?
    @State private var hasFailed = false
    @State private var attempt = 0
    @State private var isOnScreen = false
    @Environment(\.displayScale) private var displayScale

    private struct LoadKey: Equatable {
        let url: String
        let attempt: Int
        /// Loaded again once sent: from the server then, and an animation can start.
        let isLocal: Bool
    }

    /// The frame, shaped like the picture itself once it is known.
    private var displaySize: CGSize {
        image.displaySize(for: correctedSize ?? ImageShapes.corrected(for: image) ?? image.pixelSize)
    }

    var body: some View {
        let size = displaySize
        // Rounded like everything else in the timeline, but gently on an image that is itself small.
        let radius = image.isSticker ? 0 : min(10, min(size.width, size.height) * 0.18)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            Button(action: hasFailed ? retry : { open(still) }) {
                // Every layer is held to the frame on its own. Left to size themselves, a layer
                // filling the frame takes the shape of its picture, and the stack takes the
                // largest of them: the blurred placeholder, which is always square, would make
                // the stack square and the picture would be filled into that and cut down,
                // showing only its middle.
                ZStack {
                    placeholder
                        .frame(width: size.width, height: size.height)
                        .clipped()
                    if let animation, sendState == nil {
                        AnimatedImage(image: animation, isPlaying: isOnScreen)
                            .frame(width: size.width, height: size.height)
                    } else if let still {
                        Image(nsImage: still)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size.width, height: size.height)
                            .clipped()
                            .transition(.opacity)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(shape)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            // Not `.disabled`: SwiftUI dims part of a disabled button's picture, leaving a dark band.
            .allowsHitTesting(sendState == nil)
            .accessibilityLabel(accessibilityLabel)
            .help(hasFailed ? "Try again" : "")

            if hasFailed {
                failureNote
            } else if sendState != nil {
                uploadOverlay
            } else if image.isAnimated, animation == nil, still != nil {
                // Too large to play unasked: say what it is; opening it plays it.
                badge { Text("GIF").font(.caption2.weight(.bold)).foregroundStyle(.white) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            if !image.isSticker {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
        }
        .animation(.easeOut(duration: 0.2), value: still != nil)
        // An animation only runs while it can be seen.
        .onGeometryChange(for: Bool.self) { proxy in
            guard let visible = proxy.bounds(of: .scrollView) else { return true }
            return visible.intersects(proxy.frame(in: .local))
        } action: { isOnScreen = $0 }
        .task(id: LoadKey(url: image.media.source.url(), attempt: attempt, isLocal: sendState != nil)) { await load() }
    }

    // MARK: Loading

    private func load() async {
        hasFailed = false
        if let localPreview {
            still = localPreview
            return
        }
        let size = displaySize
        // Sharp on this screen, with a little to spare for images cropped to fit.
        let side = Int((max(size.width, size.height) * displayScale * 1.2).rounded(.up))
        guard let loaded = await media.displayImage(for: image, side: max(side, 64), isLocal: sendState != nil) else {
            if !Task.isCancelled { hasFailed = still == nil }
            return
        }
        // Reshape the frame if the picture turns out not to be the shape the sender said, and
        // remember that, so the frame is right from the start next time it is drawn.
        if let corrected = image.correctedPixelSize(seeing: loaded.size) {
            ImageShapes.remember(corrected, for: image)
            correctedSize = corrected
        }
        still = loaded
        if image.isAnimated, sendState == nil {
            animation = await media.animatedImage(for: image)
        }
    }

    private func retry() {
        attempt += 1
    }

    // MARK: Pieces

    /// What is there before the picture: the sender's blur of it, or a plain tile.
    @ViewBuilder private var placeholder: some View {
        if image.isSticker {
            Color.clear
        } else if let blur = image.blurhash.flatMap(BlurCache.image(for:)) {
            Image(decorative: blur, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.primary.opacity(0.06)
                if still == nil, !hasFailed {
                    Image(systemName: "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var failureNote: some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
            Text("Couldn't load image")
                .font(.caption.weight(.medium))
            Text("Click to try again")
                .font(.caption2)
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
        .allowsHitTesting(false)
    }

    /// While sending: the picture dimmed, a ring filling as it uploads, and a way to call it off.
    private var uploadOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
            if sendState == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            } else {
                // Waiting its turn looks the same as uploading that hasn't got anywhere yet.
                Button {
                    cancelUpload?()
                } label: {
                    ZStack {
                        Circle().fill(.black.opacity(0.45))
                        Circle().stroke(.white.opacity(0.3), lineWidth: 3).padding(4)
                        Circle()
                            .trim(from: 0, to: max(0.03, min(uploadProgress ?? 0.03, 1)))
                            .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(4)
                            .animation(.linear(duration: 0.2), value: uploadProgress)
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel upload")
                .accessibilityLabel("Cancel upload")
                .accessibilityValue(uploadProgress.map { "\(Int($0 * 100)) percent" } ?? "Starting")
            }
        }
    }

    private func badge<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private var accessibilityLabel: String {
        let what = image.isSticker ? "Sticker" : (image.isAnimated ? "Animated image" : "Image")
        let name = image.caption ?? image.filename
        return name.isEmpty ? what : "\(what): \(name)"
    }
}

/// Plays an animated image (a GIF). SwiftUI's own `Image` shows only the first frame.
struct AnimatedImage: NSViewRepresentable {
    let image: NSImage
    let isPlaying: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleAxesIndependently     // the frame already has the image's shape
        view.imageFrameStyle = .none
        view.isEditable = false
        // Let SwiftUI decide the size; otherwise the view insists on the image's own.
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image !== image { view.image = image }
        if view.animates != isPlaying { view.animates = isPlaying }
    }
}

/// Decoded blurs, kept so each is worked out once however often its row is redrawn.
private enum BlurCache {
    private static let cache = NSCache<NSString, CGImage>()

    static func image(for hash: String) -> CGImage? {
        if let cached = cache.object(forKey: hash as NSString) { return cached }
        guard let image = BlurHash.image(from: hash) else { return nil }
        cache.setObject(image, forKey: hash as NSString)
        return image
    }
}

/// Images whose real shape turned out to differ from what their sender reported, by address.
@MainActor
enum ImageShapes {
    private static var sizes: [String: CGSize] = [:]

    static func corrected(for image: ImageAttachment) -> CGSize? {
        sizes[image.media.source.url()]
    }

    static func remember(_ size: CGSize, for image: ImageAttachment) {
        sizes[image.media.source.url()] = size
    }
}
