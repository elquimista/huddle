import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pictures and files waiting in the composer to be sent, each with a button to take it out
/// again: pictures as thumbnails, files as tiles with their icon, name and size.
struct StagedImagesRow: View {
    let images: [StagedImage]
    var files: [StagedFile] = []
    let remove: (StagedImage) -> Void
    var removeFile: (StagedFile) -> Void = { _ in }

    private static let side: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(files) { file in
                    StagedFileTile(file: file, height: Self.side) { removeFile(file) }
                }
                ForEach(images) { image in
                    Image(nsImage: image.preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .accessibilityLabel("Image to send: \(image.filename)")
                        .frame(width: Self.side, height: Self.side)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                        }
                        .overlay(alignment: .bottomLeading) {
                            if image.isAnimated {
                                Text("GIF")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.55), in: Capsule())
                                    .padding(4)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            Button { remove(image) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(.white)
                                    .frame(width: 18, height: 18)
                                    .background(Color(white: 0.25), in: Circle())
                                    .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 6, y: -6)
                            .help("Remove")
                            .accessibilityLabel("Remove \(image.filename)")
                        }
                        .help(Self.describe(image))
                }
            }
            // Room for the remove buttons, which sit on the corners.
            .padding(.top, 7)
            .padding(.trailing, 7)
            .padding(.leading, 2)
        }
        .frame(height: Self.side + 7)
    }

    private static func describe(_ image: StagedImage) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(image.data.count), countStyle: .file)
        return "\(image.filename)\n\(Int(image.pixelSize.width)) × \(Int(image.pixelSize.height)), \(size)"
    }
}

/// The composer's button for picking images to send.
struct AttachButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(isHovering ? 0.12 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help("Attach pictures or files")
        .accessibilityLabel("Attach pictures or files")
    }
}

/// Shown over the conversation while images are dragged across it.
struct DropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 34, weight: .light))
                Text("Drop to send")
                    .font(.title3.weight(.medium))
            }
            .foregroundStyle(Color.accentColor)
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

/// Catches ⌘V in a composer when the clipboard holds a picture, which a text field would ignore.
@MainActor
final class PasteInterceptor {
    /// Whether this composer's text field has the keyboard.
    var isActive = false
    var onImages: (([ImageSource]) -> Void)?
    /// Files copied in the Finder, which aren't pictures.
    var onFiles: (([URL]) -> Void)?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let images = ImagePasteboard.images(on: .general)
            if !images.isEmpty {
                self.onImages?(images)
                return nil
            }
            // Files copied in the Finder: attach them, rather than paste their names.
            let files = (NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            guard !files.isEmpty else { return event }      // text: let the field paste it
            self.onFiles?(files)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reading what was dropped: files of any kind, or pictures dragged straight out of another app.
enum ImageDrop {
    static let types: [UTType] = [.fileURL, .image]

    /// Pictures dragged out of an app, as their data; and files, as where they are (pictures among
    /// them too, which the composer sorts out).
    static func sources(from providers: [NSItemProvider]) async -> (images: [ImageSource], files: [URL]) {
        var images: [ImageSource] = []
        var files: [URL] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider) {
                files.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await data(from: provider) {
                images.append(.data(data, name: provider.suggestedName ?? "Image"))
            }
        }
        return (images, files)
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func data(from provider: NSItemProvider) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Reports the window a view is in, once it is in one.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = onWindow
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

/// Sends typing to the room's composer when nothing that takes text has the keyboard: after
/// clicking a room in the list, or a message, you can just start typing.
///
/// Only plain typing is taken: letters, digits, punctuation, space, with or without Shift.
/// Arrows, Return, Tab, Delete and anything with ⌘, ⌃ or ⌥ go where they always went, so the
/// room list can still be moved through with the arrow keys and shortcuts keep working.
@MainActor
final class TypeToCompose {
    /// Puts the keyboard in the composer.
    var focus: (() -> Void)?
    /// The window the composer is in. Typing elsewhere (a sheet, a popover, Settings) is left alone.
    weak var window: NSWindow?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = event.window else { return event }
            // While the first key waits for the composer, hold any that follow, so fast typing
            // arrives in the order it was typed.
            if !self.pending.isEmpty, window === self.window {
                self.pending.append(event)
                return nil
            }
            guard self.shouldRoute(event, in: window) else { return event }
            self.pending = [event]
            self.focus?()
            self.deliver(to: window, attempt: 0)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        pending = []
    }

    /// Keys waiting for the composer to take the keyboard, oldest first.
    private var pending: [NSEvent] = []

    private func shouldRoute(_ event: NSEvent, in window: NSWindow) -> Bool {
        // The composer's own window, not a sheet, popover or the settings window; and not while
        // an image is open over it.
        guard window === self.window, window.attachedSheet == nil, ImageViewerState.shared.item == nil else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option, .function]).isEmpty else { return false }
        // Something that takes text already has the keyboard: leave it be.
        if let editor = window.firstResponder as? NSTextView, editor.isEditable { return false }
        guard let characters = event.characters, !characters.isEmpty else { return false }
        // Typed characters only: not Return, Tab, Delete, Escape or the arrow and function keys,
        // which AppKit gives as control characters or from a private range.
        return characters.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    /// Once the composer has the keyboard, hands it the key as if it had been typed there, so
    /// input methods (accents, Chinese, Japanese, Korean) see it too. Moving the keyboard takes
    /// SwiftUI a moment, so this checks back a few times.
    private func deliver(to window: NSWindow, attempt: Int) {
        if let editor = window.firstResponder as? NSTextView, editor.isEditable {
            // Carry on from the end of anything already written, not over a selection of it.
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            let keys = pending
            pending = []
            keys.forEach(window.sendEvent)
            return
        }
        guard attempt < 12 else {
            pending = []      // the composer never took the keyboard: drop rather than hold forever
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.deliver(to: window, attempt: attempt + 1)
        }
    }
}

/// A file waiting in the composer: its icon, name and size, as tall as the pictures beside it.
private struct StagedFileTile: View {
    let file: StagedFile
    let height: CGFloat
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(for: file.type ?? .data))
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color(white: 0.25), in: Circle())
                    .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("Remove")
            .accessibilityLabel("Remove \(file.filename)")
        }
        .help(file.filename)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("File to send: \(file.filename)")
    }
}
