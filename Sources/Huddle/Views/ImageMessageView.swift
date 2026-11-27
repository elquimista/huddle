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
    /// Why the picture wasn't loaded unasked, if it is too large to be.
    @State private var withheld: MediaLoader.Withheld?
    /// Clicked to be shown, whatever its size.
    @State private var isAskedFor = false
    @State private var attempt = 0
    @State private var isOnScreen = false
    /// Whether all of the picture is above the middle of what shows of the conversation, where
    /// what's being read is (`ReadingPlace`).
    @State private var isAboveReading = false
    @Environment(\.displayScale) private var displayScale
    @Environment(\.readingPlace) private var readingPlace

    private struct LoadKey: Equatable {
        let url: String
        let attempt: Int
        /// Loaded again once sent: from the server then, and an animation can start.
        let isLocal: Bool
        let isAskedFor: Bool
    }

    /// The frame, shaped like the picture itself once it is known.
    @Environment(\.messageContentWidth) private var contentWidth

    private var displaySize: CGSize {
        image.displaySize(for: correctedSize ?? ImageShapes.corrected(for: image) ?? image.pixelSize,
                          maxWidth: contentWidth)
    }

    /// How many pixels across the copy for the timeline is: sharp on this screen, with a little to
    /// spare for images cropped to fit.
    private var loadSide: Int {
        let size = displaySize
        return max(Int((max(size.width, size.height) * displayScale * 1.2).rounded(.up)), 64)
    }

    /// The picture, from the cache in the first frame the message is drawn in, where it's there:
    /// left to `task`, it came a frame later, so a conversation drawn anew (another room, another
    /// space) showed its placeholders for a moment first.
    private var shownStill: NSImage? {
        still ?? localPreview ?? media.cachedDisplayImage(for: image, side: loadSide)
    }

    var body: some View {
        let size = displaySize
        let still = shownStill
        // Rounded like everything else in the timeline, but gently on an image that is itself small.
        let radius = image.isSticker ? 0 : min(10, min(size.width, size.height) * 0.18)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            Button(action: hasFailed ? retry : (withheld != nil && still == nil ? showAnyway : { open(still) })) {
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
            .help(hasFailed ? "Try again" : (withheld != nil && still == nil ? "Download and show this picture" : ""))

            if hasFailed {
                failureNote
            } else if let withheld, still == nil {
                withheldNote(withheld)
            } else if let sendState {
                UploadOverlay(sendState: sendState, uploadProgress: uploadProgress, cancel: cancelUpload)
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
        // An animation only runs while it can be seen.
        .onGeometryChange(for: Placement.self) { proxy in
            guard let visible = proxy.bounds(of: .scrollView) else { return Placement(isOnScreen: true, isAboveReading: false) }
            let frame = proxy.frame(in: .local)
            return Placement(isOnScreen: visible.intersects(frame), isAboveReading: frame.maxY <= visible.midY)
        } action: { placement in
            isOnScreen = placement.isOnScreen
            isAboveReading = placement.isAboveReading
        }
        .task(id: LoadKey(url: image.media.source.url(), attempt: attempt, isLocal: sendState != nil, isAskedFor: isAskedFor)) {
            await load()
        }
    }

    private struct Placement: Equatable {
        let isOnScreen: Bool
        let isAboveReading: Bool
    }

    // MARK: Loading

    private func load() async {
        hasFailed = false
        if let localPreview {
            still = localPreview
            return
        }
        let loaded: NSImage
        switch await media.displayImage(for: image, side: loadSide, isLocal: sendState != nil, askedFor: isAskedFor) {
        case .shown(let image):
            loaded = image
        case .withheld(let reason):
            if !Task.isCancelled { withheld = reason }
            return
        case .failed:
            if !Task.isCancelled { hasFailed = still == nil }
            return
        }
        // Reshape the frame if the picture turns out not to be the shape the sender said, and
        // remember that, so the frame is right from the start next time it is drawn. At once,
        // not as the picture fades in: a frame changing size over several frames carries every
        // message under it along. Above what's being read, the conversation moves with it, so
        // that stays put, and the picture grows or shrinks upward.
        if let corrected = image.correctedPixelSize(seeing: loaded.size) {
            let before = displaySize.height
            ImageShapes.remember(corrected, for: image)
            if isAboveReading {
                readingPlace?.changeAbove(by: image.displaySize(for: corrected, maxWidth: contentWidth).height - before)
            }
            correctedSize = corrected
        }
        withAnimation(.easeOut(duration: 0.2)) { still = loaded }
        if image.isAnimated, sendState == nil {
            animation = await media.animatedImage(for: image)
        }
    }

    private func retry() {
        attempt += 1
    }

    private func showAnyway() {
        isAskedFor = true
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
                if still == nil, !hasFailed, withheld == nil {
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
            Text("Couldn’t load image")
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

    /// For a picture too large to fetch, or to decode, unasked: what it is, and that clicking
    /// shows it. A spinner once clicked, while it downloads. Where the frame is too small for
    /// that, just the symbol. White on the sender's blur, dimmed; on a plain tile, in the
    /// tile's own grey.
    private func withheldNote(_ reason: MediaLoader.Withheld) -> some View {
        let isOnBlur = !image.isSticker && image.blurhash.flatMap(BlurCache.image(for:)) != nil
        // As tall either way, so the words don't move when it's clicked.
        let symbol = Group {
            if isAskedFor {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 22))
            }
        }
        .frame(height: 26)
        return ViewThatFits {
            VStack(spacing: 4) {
                symbol
                Text(isAskedFor ? "Loading Picture…" : "Show Picture")
                    .font(.caption.weight(.semibold))
                Text(Self.describe(reason))
                    .font(.caption2)
                    .monospacedDigit()
                    .opacity(0.8)
            }
            .fixedSize()
            .padding(8)
            symbol
        }
        .foregroundStyle(isOnBlur ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .modifier(DarkIf(isOnBlur))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isOnBlur ? .black.opacity(0.35) : .clear)
        .allowsHitTesting(false)
    }

    /// Dark appearance (a light spinner) for what is drawn on a dimmed picture.
    private struct DarkIf: ViewModifier {
        let isOn: Bool
        init(_ isOn: Bool) { self.isOn = isOn }
        func body(content: Content) -> some View {
            if isOn { content.environment(\.colorScheme, .dark) } else { content }
        }
    }

    /// "34 MB", or "40,000 × 40,000 pixels".
    private static func describe(_ reason: MediaLoader.Withheld) -> String {
        switch reason {
        case .bytes(let count):
            ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
        case .pixels(let width, let height):
            "\(width.formatted()) × \(height.formatted()) pixels"
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
        let label = name.isEmpty ? what : "\(what): \(name)"
        guard let withheld, still == nil else { return label }
        return "\(label), not downloaded (\(Self.describe(withheld))). Click to show it."
    }
}

/// While a picture or video is sent: it dimmed, a ring filling as it uploads, and a way to call
/// it off.
struct UploadOverlay: View {
    let sendState: MessageRow.SendState
    let uploadProgress: Double?
    let cancel: (() -> Void)?

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            if sendState == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
            } else {
                // Waiting its turn looks the same as uploading that hasn't got anywhere yet.
                Button {
                    cancel?()
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
enum BlurCache {
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
