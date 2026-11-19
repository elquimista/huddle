import AppKit
import SwiftUI

/// Which image the full-size viewer is showing, if any. One viewer for the whole window.
@MainActor @Observable
final class ImageViewerState {
    static let shared = ImageViewerState()

    struct Item: Identifiable {
        let id = UUID()
        let image: ImageAttachment
        let media: MediaLoader
        /// What the timeline was already showing, so there is something on screen at once.
        let placeholder: NSImage?
    }

    private(set) var item: Item?

    func open(_ image: ImageAttachment, media: MediaLoader, placeholder: NSImage?) {
        item = Item(image: image, media: media, placeholder: placeholder)
    }

    func close() {
        item = nil
    }
}

/// Puts the viewer over the entire window: title bar, toolbar and all. A SwiftUI overlay stops
/// below the title bar, leaving a bright strip of toolbar above a darkened window. So the
/// viewer goes in a view of its own, added to the window's frame above its other contents,
/// where the window's rounded corners still clip it.
@MainActor
final class ImageViewerPresenter {
    static let shared = ImageViewerPresenter()
    private var host: NSView?

    func show(_ item: ImageViewerState.Item?) {
        guard let item else { return dismiss() }
        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first { $0.canBecomeMain && $0.isVisible }
        guard let frame = window?.contentView?.superview else { return }
        host?.removeFromSuperview()

        let view = NSHostingView(rootView: ImageViewer(item: item) { ImageViewerState.shared.close() })
        // A plain view over the window: it draws under the title bar instead of keeping clear
        // of it, and it leaves the window's toolbar and title to the main content.
        view.safeAreaRegions = []
        view.sceneBridgingOptions = []
        // The SwiftUI view sits inside a plain one. Added to the window's frame directly, a
        // hosting view is taken for window content, and the sidebar loses its place under the
        // toolbar.
        let container = NSView(frame: frame.bounds)
        container.autoresizingMask = [.width, .height]
        container.alphaValue = 0
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        frame.addSubview(container, positioned: .above, relativeTo: nil)
        host = container
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            container.animator().alphaValue = 1
        }
    }

    private func dismiss() {
        guard let view = host else { return }
        host = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            view.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in view.removeFromSuperview() }
        })
    }
}

/// An image at full size over the whole window: zoom, rotate, drag around, copy, save.
/// Clicking outside the picture, or pressing Escape, closes it.
struct ImageViewer: View {
    let item: ImageViewerState.Item
    let close: () -> Void

    @State private var full: NSImage?
    @State private var hasFailed = false
    @State private var attempt = 0
    /// 1 is the size that fits the window.
    @State private var zoom: CGFloat = 1
    /// Quarter turns clockwise. Not kept within 0…3, so each turn animates the short way round.
    @State private var turns = 0
    @State private var offset: CGSize = .zero
    @State private var dragOrigin: CGSize?
    @State private var container: CGRect = .zero
    @State private var input = ViewerInput()
    @State private var notice: String?

    /// Longest edge, in pixels, an image is decoded at for viewing.
    private static let largestSide = 8192
    /// Space kept clear around the picture for the bars at the top and bottom.
    private static let margin = CGSize(width: 48, height: 76)

    var body: some View {
        // Everything that isn't the picture or a control is "outside": clicking it closes.
        Color.black.opacity(0.84)
            .contentShape(Rectangle())
            .onTapGesture(perform: close)
            .accessibilityElement()
            .accessibilityLabel("Close image")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, close)
            // Laid over the backdrop, not beside it: zoomed in, the picture is far larger than
            // the window, and must not stretch the viewer to match.
            .overlay { picture }
            .overlay { bars }
            .clipped()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                container = $0
                input.container = $0
                offset = clamped(offset)
            }
            // Light controls on the dark backdrop, whatever the app's own appearance.
            .environment(\.colorScheme, .dark)
            .onAppear {
                input.onKey = handle(key:)
                input.onZoom = { factor, anchor in setZoom(zoom * factor, anchor: anchor) }
                input.onPan = { delta in offset = clamped(CGSize(width: offset.width + delta.width, height: offset.height + delta.height)) }
                input.start()
            }
            .onDisappear { input.stop() }
            .task(id: attempt) { await load() }
            .accessibilityAddTraits(.isModal)
    }

    private var bars: some View {
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                if let notice {
                    Text(notice)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                        .transition(.opacity)
                }
                controls
            }
            .padding(16)
    }

    // MARK: Picture

    private var shown: NSImage? { full ?? item.placeholder }

    /// The image's own size, one point per pixel: from the image once loaded, from the message
    /// until then. (The loaded image is given its pixel dimensions as its size. Its list of
    /// representations is no guide: AppKit adds a double-sized one after drawing on a Retina screen.)
    private var naturalSize: CGSize {
        if let full, full.size.width > 0, full.size.height > 0 { return full.size }
        // Until then the timeline's idea of its shape, which corrects a wrongly reported size.
        if let size = ImageShapes.corrected(for: item.image) ?? item.image.pixelSize { return size }
        return item.placeholder?.size ?? CGSize(width: 400, height: 300)
    }

    private var isSideways: Bool { abs(turns) % 2 == 1 }

    /// How much the image is scaled to fit the window, never above its own size.
    private var fitScale: CGFloat {
        let natural = naturalSize
        let turned = isSideways ? CGSize(width: natural.height, height: natural.width) : natural
        let room = CGSize(width: max(container.width - Self.margin.width * 2, 80),
                          height: max(container.height - Self.margin.height * 2, 80))
        return min(1, room.width / max(turned.width, 1), room.height / max(turned.height, 1))
    }

    /// The size the picture takes on screen, after turning.
    private var displayedSize: CGSize {
        let scale = fitScale * zoom
        let natural = naturalSize
        return isSideways ? CGSize(width: natural.height * scale, height: natural.width * scale)
                          : CGSize(width: natural.width * scale, height: natural.height * scale)
    }

    private var picture: some View {
        let scale = fitScale * zoom
        let natural = naturalSize
        return ZStack {
            if let shown {
                Group {
                    if item.image.isAnimated, let full {
                        AnimatedImage(image: full, isPlaying: true)
                    } else {
                        Image(nsImage: shown)
                            .resizable()
                            .interpolation(.high)
                    }
                }
                .frame(width: natural.width * scale, height: natural.height * scale)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
                .rotationEffect(.degrees(Double(turns) * 90))
                .offset(offset)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { toggleZoom() }
                .onTapGesture {}          // a click on the picture is not a click outside it
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let origin = dragOrigin ?? offset
                            dragOrigin = origin
                            offset = clamped(CGSize(width: origin.width + value.translation.width,
                                                    height: origin.height + value.translation.height))
                        }
                        .onEnded { _ in dragOrigin = nil }
                )
                .accessibilityLabel(item.image.caption ?? item.image.filename)
                .accessibilityAddTraits(.isImage)
            }
            if hasFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 26))
                    Text("This image couldn’t be loaded.")
                    Button("Try Again") { attempt += 1 }
                        .controlSize(.large)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if full == nil {
                ProgressView()
                    .controlSize(shown == nil ? .regular : .small)
                    .padding(10)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
    }

    private func load() async {
        hasFailed = false
        do {
            let data = try await item.media.imageFile(source: item.image.media.source)
            let isAnimated = item.image.isAnimated
            let side = Self.largestSide
            let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
                // An animation keeps its frames. Anything else is decoded the right way up (a
                // phone photo is often stored on its side, with a note saying so), and no larger
                // than is useful, so a huge photo doesn't take hundreds of megabytes.
                if isAnimated, MediaLoader.decodes(data, within: MediaLoader.viewerMemory) { return NSImage(data: data) }
                guard let image = ImagePreparer.scaled(data, to: side) else { return nil }
                return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            }.value
            guard let decoded else { throw CocoaError(.fileReadCorruptFile) }
            full = decoded
        } catch {
            if !Task.isCancelled { hasFailed = true }
        }
    }

    // MARK: Zoom, turn, move

    private var zoomRange: ClosedRange<CGFloat> {
        // Out to a quarter of the fitted size; in to at least 8 times it, and always far enough
        // to see a large photo at 5 times its own size.
        0.25...max(8, 5 / max(fitScale, 0.01))
    }

    /// - Parameter anchor: the point to zoom about, measured from the middle of the window.
    private func setZoom(_ value: CGFloat, anchor: CGPoint = .zero) {
        let target = min(max(value, zoomRange.lowerBound), zoomRange.upperBound)
        guard zoom > 0, target != zoom else { return }
        let ratio = target / zoom
        // What is under the anchor stays under it.
        let moved = CGSize(width: (offset.width - anchor.x) * ratio + anchor.x,
                           height: (offset.height - anchor.y) * ratio + anchor.y)
        zoom = target
        offset = clamped(moved)
    }

    private func step(_ factor: CGFloat) {
        withAnimation(.snappy(duration: 0.18)) { setZoom(zoom * factor) }
    }

    private func fit() {
        withAnimation(.snappy(duration: 0.2)) {
            zoom = 1
            offset = .zero
        }
    }

    /// One image point per screen point: "100%".
    private func actualSize() {
        withAnimation(.snappy(duration: 0.2)) { setZoom(1 / max(fitScale, 0.01)) }
    }

    /// Double-click: in to full size (or double, for an image already at full size), then back.
    private func toggleZoom() {
        if abs(zoom - 1) > 0.01 {
            fit()
        } else if fitScale < 0.99 {
            actualSize()
        } else {
            step(2)
        }
    }

    private func turn(_ quarters: Int) {
        withAnimation(.snappy(duration: 0.25)) {
            turns += quarters
            offset = clamped(offset)
        }
    }

    /// Keeps the picture from being dragged off: it can move only as far as it overflows.
    private func clamped(_ value: CGSize) -> CGSize {
        let size = displayedSize
        let limitX = max(0, (size.width - container.width) / 2 + Self.margin.width)
        let limitY = max(0, (size.height - container.height) / 2 + Self.margin.height)
        guard size.width > container.width - Self.margin.width * 2 || size.height > container.height - Self.margin.height * 2 else {
            return .zero
        }
        return CGSize(width: min(max(value.width, -limitX), limitX), height: min(max(value.height, -limitY), limitY))
    }

    // MARK: Keys

    /// True if the key was used, so it goes no further.
    private func handle(key: ViewerInput.Key) -> Bool {
        switch key {
        case .close: close()
        case .zoomIn: step(1.25)
        case .zoomOut: step(0.8)
        case .fit: fit()
        case .actualSize: actualSize()
        case .turnRight: turn(1)
        case .turnLeft: turn(-1)
        case .copy: copy()
        case .save: AttachmentSaver.save(item.image, media: item.media)
        case .move(let dx, let dy):
            withAnimation(.snappy(duration: 0.12)) {
                offset = clamped(CGSize(width: offset.width + dx, height: offset.height + dy))
            }
        }
        return true
    }

    private func copy() {
        Task {
            guard let data = try? await item.media.imageFile(source: item.image.media.source) else { return }
            ImagePasteboard.copy(data)
            withAnimation(.easeOut(duration: 0.15)) { notice = "Copied" }
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(.easeOut(duration: 0.3)) { notice = nil }
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.image.suggestedFilename)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Spacer(minLength: 12)
            ViewerButton(symbol: "xmark", help: "Close (Esc)", action: close)
                .background(.regularMaterial, in: Circle())
                .clipShape(Circle())
        }
    }

    private var details: String {
        let size = naturalSize
        var parts = ["\(Int(size.width)) × \(Int(size.height))"]
        if let bytes = item.image.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private var controls: some View {
        HStack(spacing: 2) {
            ViewerButton(symbol: "minus.magnifyingglass", help: "Zoom Out (−)") { step(0.8) }
                .disabled(zoom <= zoomRange.lowerBound)
            Button(action: fit) {
                Text("\(Int((fitScale * zoom * 100).rounded()))%")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .frame(width: 54, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Fit to Window (0)")
            .accessibilityLabel("Zoom")
            .accessibilityValue("\(Int((fitScale * zoom * 100).rounded())) percent")
            .accessibilityHint("Fits the image to the window")
            ViewerButton(symbol: "plus.magnifyingglass", help: "Zoom In (+)") { step(1.25) }
                .disabled(zoom >= zoomRange.upperBound)
            separator
            ViewerButton(symbol: "rotate.left", help: "Rotate Left (L)") { turn(-1) }
            ViewerButton(symbol: "rotate.right", help: "Rotate Right (R)") { turn(1) }
            separator
            ViewerButton(symbol: "doc.on.doc", help: "Copy Image (⌘C)", action: copy)
            ViewerButton(symbol: "square.and.arrow.down", help: "Save Image As… (⌘S)") {
                AttachmentSaver.save(item.image, media: item.media)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .onTapGesture {}      // the gaps between buttons are not "outside"
    }

    private var separator: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 5)
    }
}

/// A round-cornered symbol button for the viewer's bars.
private struct ViewerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .opacity(isEnabled ? 1 : 0.35)
                .frame(width: 34, height: 30)
                .background(isHovering && isEnabled ? Color.white.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
    }
}

/// Keys, the scroll wheel and pinches while the viewer is open. Everything is taken here, so
/// nothing reaches the conversation underneath: typing doesn't land in the composer, and
/// scrolling doesn't move the messages.
@MainActor
final class ViewerInput {
    enum Key {
        case close, zoomIn, zoomOut, fit, actualSize, turnRight, turnLeft, copy, save
        case move(CGFloat, CGFloat)
    }

    var onKey: ((Key) -> Bool)?
    /// A zoom factor, and the point to zoom about, measured from the middle of the viewer.
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onPan: ((CGSize) -> Void)?
    /// The viewer's frame in the window, measured from the window's top left.
    var container: CGRect = .zero
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .magnify]) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown: return self.keyDown(event)
            case .scrollWheel:
                // A mouse wheel zooms; two fingers on a trackpad move the picture, or zoom with ⌘ held.
                if event.hasPreciseScrollingDeltas, !event.modifierFlags.contains(.command) {
                    self.onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                } else {
                    let amount = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
                    self.onZoom?(exp(amount), self.anchor(for: event))
                }
                return nil
            case .magnify:
                self.onZoom?(1 + event.magnification, self.anchor(for: event))
                return nil
            default:
                return event
            }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func keyDown(_ event: NSEvent) -> NSEvent? {
        let command = event.modifierFlags.contains(.command)
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let key: Key?
        switch (event.keyCode, character) {
        case (53, _), (49, _): key = command ? nil : .close       // Escape, Space
        case (123, _): key = .move(80, 0)                          // arrows move the picture
        case (124, _): key = .move(-80, 0)
        case (125, _): key = .move(0, -80)
        case (126, _): key = .move(0, 80)
        case (_, "+"), (_, "="): key = .zoomIn
        case (_, "-"): key = .zoomOut
        case (_, "0"): key = .fit
        case (_, "1"): key = .actualSize
        case (_, "r"): key = .turnRight
        case (_, "l"): key = .turnLeft
        case (_, "c") where command: key = .copy
        case (_, "s") where command: key = .save
        case (_, "w") where command: key = .close
        default: key = nil
        }
        if let key, onKey?(key) == true { return nil }
        // Other shortcuts (Quit, Hide, Minimise) still work; plain typing goes nowhere.
        return command ? event : nil
    }

    /// Where the pointer is, measured from the middle of the viewer.
    private func anchor(for event: NSEvent) -> CGPoint {
        // The viewer fills the window, so the window's own coordinates will do, turned to
        // measure down from the top as the viewer does.
        guard let window = event.window, container.width > 0 else { return .zero }
        let point = event.locationInWindow
        return CGPoint(x: point.x - container.midX, y: (window.frame.height - point.y) - container.midY)
    }
}
