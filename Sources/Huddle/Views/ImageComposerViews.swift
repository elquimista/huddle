import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Images waiting in the composer to be sent, each with a button to take it out again.
struct StagedImagesRow: View {
    let images: [StagedImage]
    let remove: (StagedImage) -> Void

    private static let side: CGFloat = 64

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
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
        .onHover { isHovering = $0 }
        .help("Attach images")
        .accessibilityLabel("Attach images")
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
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34, weight: .light))
                Text("Drop images to send")
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
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v" else { return event }
            let images = ImagePasteboard.images(on: .general)
            guard !images.isEmpty else { return event }      // text: let the field paste it
            self.onImages?(images)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Reading what was dropped: image files, or pictures dragged straight out of another app.
enum ImageDrop {
    static let types: [UTType] = [.fileURL, .image]

    static func sources(from providers: [NSItemProvider]) async -> [ImageSource] {
        var sources: [ImageSource] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await fileURL(from: provider) {
                if (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true {
                    sources.append(.file(url))
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await data(from: provider) {
                sources.append(.data(data, name: provider.suggestedName ?? "Image"))
            }
        }
        return sources
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
