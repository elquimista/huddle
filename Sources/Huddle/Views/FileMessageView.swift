import AppKit
import SwiftUI

/// A file in the conversation: its icon, name, size and kind. Clicked, it downloads and opens in
/// its usual app; its menu also saves it. While it is being sent, how far along it is, and a
/// button to stop.
struct FileMessageView: View {
    let file: FileAttachment
    let media: MediaLoader
    var sendState: MessageRow.SendState?
    var uploadProgress: Double?
    /// Stops sending it, while it is being sent.
    var cancelUpload: (() -> Void)?

    @State private var isOpening = false
    @State private var isHovering = false
    @State private var failure: String?

    /// Wide enough for most names, and the same for every file, so they line up.
    private static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: open) {
                HStack(spacing: 10) {
                    Image(nsImage: file.icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // Room for what sits over the right end: the spinner or the stop button.
                    Color.clear.frame(width: 22, height: 22)
                }
                .padding(.leading, 10)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .frame(width: Self.width, alignment: .leading)
                .background(Color.primary.opacity(isHovering && canOpen ? 0.08 : 0.05),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            // Never disabled, which would grey it out (and the stop button over it): a click
            // while it can't be opened simply does nothing.
            .help(canOpen ? "Open “\(file.filename)”" : file.filename)
            .accessibilityLabel("\(file.filename), \(status)")
            .accessibilityHint(canOpen ? "Opens the file" : "")
            .onHover { isHovering = $0 }
            // Over the tile, not inside it, so the stop button is a control of its own.
            .overlay(alignment: .trailing) {
                trailing.padding(.trailing, 12)
            }
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .task(id: file.media?.source.url()) {
            // Dev testing: each file shown is saved where HUDDLE_DEV_DOWNLOAD_TO says.
            if let folder = DevHooks.fileDownloadFolder, let source = file.media, sendState == nil {
                try? await media.download(source, mimetype: file.mimetype,
                                          to: folder.appendingPathComponent(file.safeFilename))
            }
        }
    }

    /// On the server, and not being fetched already.
    private var canOpen: Bool { file.media != nil && sendState == nil && !isOpening }

    private var status: String {
        switch sendState {
        case .waiting: return "Waiting to send"
        case .sending:
            if let uploadProgress, let size = file.size {
                let sent = ByteCountFormatter.string(fromByteCount: Int64(Double(size) * uploadProgress), countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                return "Sending… \(sent) of \(total)"
            }
            return "Sending…"
        case .failed, nil:
            return isOpening ? "Downloading…" : file.details
        }
    }

    @ViewBuilder private var trailing: some View {
        if isOpening {
            ProgressView().controlSize(.small)
        } else if sendState == .sending || sendState == .waiting, let cancelUpload {
            // How far it has got, ringed around a button to stop it.
            Button(action: cancelUpload) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.03, min(uploadProgress ?? 0.03, 1)))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: uploadProgress)
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 22, height: 22)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop sending")
            .accessibilityLabel("Stop sending")
            .accessibilityValue(uploadProgress.map { "\(Int($0 * 100)) percent" } ?? "Starting")
        }
    }

    private func open() {
        guard canOpen else { return }
        isOpening = true
        failure = nil
        Task {
            defer { isOpening = false }
            do {
                try await media.open(file)
            } catch {
                failure = "It couldn’t be downloaded. Check your connection and try again."
            }
        }
    }
}
