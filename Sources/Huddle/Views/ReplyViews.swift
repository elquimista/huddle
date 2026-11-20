import SwiftUI
import Perception

/// What a message row can ask the timeline around it to do.
struct MessageActions {
    /// Opens a message's thread. Nil inside a thread, where there is nothing further to open.
    var openThread: ((String) -> Void)?
    /// Starts a reply to a message in the composer.
    var reply: (MessageRow) -> Void
    /// Goes to the message a reply answers.
    var showOriginal: (ReplyPreview) -> Void
    /// Opens an image at full size, with what the timeline is showing of it to start from.
    var openImage: (ImageAttachment, NSImage?) -> Void
    /// Starts editing a message in the composer.
    var edit: (MessageRow) -> Void
    /// Asks whether to delete a message, and does.
    var delete: (MessageRow) -> Void
    /// Offers to send a message on to other rooms.
    var forward: (MessageRow) -> Void
}

/// The message being answered, shown above a reply: a bar in the sender's colour, their name,
/// and a line of what they said. Clicking it goes to that message.
struct ReplyQuoteView: View {
    let reply: ReplyPreview
    /// True while older history is being loaded to find the message.
    var isSearching = false
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.nameColorRoom) private var room

    var body: some View { WithPerceptionTracking {
        Button(action: action) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(reply.tint(inRoom: room))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    if reply.state == .ready {
                        Text(reply.senderName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(reply.tint(inRoom: room))
                    }
                    ReplySnippet(reply: reply)
                }
                if isSearching {
                    ProgressView()
                        .controlSize(.mini)
                        .padding(.leading, 2)
                }
            }
            .padding(.vertical, 3)
            .padding(.trailing, 10)
            // The bar is as tall as the text beside it, no taller.
            .fixedSize(horizontal: false, vertical: true)
            .background(isHovering && reply.state == .ready ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(reply.state != .ready)
        .onHoverInFrontWindow { isHovering = $0 }
        .help(reply.state == .ready ? "Go to this message" : "")
        // No wider than it needs: in a bubble, a short quote keeps the bubble short.
        .widthCap(460)
        .accessibilityLabel(reply.state == .ready ? "In reply to \(reply.senderName): \(reply.text)" : reply.placeholder)
        .accessibilityHint(reply.state == .ready ? "Goes to that message" : "")
    } }
}

/// Above the composer while writing a reply: who and what is being answered, and a way out.
struct ReplyComposerBar: View {
    let reply: ReplyPreview
    let cancel: () -> Void
    @Environment(\.nameColorRoom) private var room

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 8) {
            Capsule()
                .fill(reply.tint(inRoom: room))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(reply.senderName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reply.tint(inRoom: room))
                ReplySnippet(reply: reply)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel reply (Esc)")
            .accessibilityLabel("Cancel reply")
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    } }
}

/// Above the composer while editing a message: what it said before, and a way out.
struct EditComposerBar: View {
    let original: ReplyPreview
    let isCaption: Bool
    let cancel: () -> Void

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(isCaption ? "Editing caption" : "Editing message")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                ReplySnippet(reply: original)
            }
            Spacer(minLength: 8)
            Button(action: cancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .background(.quaternary, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel editing (Esc)")
            .accessibilityLabel("Cancel editing")
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    } }
}

/// One line standing for a message: its text, or what kind of thing it is.
struct ReplySnippet: View {
    let reply: ReplyPreview

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 4) {
            if reply.state == .ready, let icon = reply.icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(reply.state == .ready ? reply.text : reply.placeholder)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
    } }
}

extension ReplyPreview {
    /// The sender's colour, the same one their name has in the room's conversation.
    @MainActor func tint(inRoom roomID: String?) -> Color {
        state == .ready ? NameColors.shared.color(for: sender, inRoom: roomID) : Color.secondary.opacity(0.5)
    }

    /// What to say in place of the message while it loads, or if it can't be had.
    var placeholder: String {
        state == .loading ? "Loading message…" : "The original message isn’t available"
    }
}
