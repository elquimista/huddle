import SwiftUI

/// The colour of pins wherever they appear: a pushpin's.
private let pinTint = Color.orange

/// "Pinned", beside a pinned message's time or above its text.
struct PinnedMark: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(pinTint)
            Text("Pinned")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Along the top of a room with pinned messages: one of them, and a way to all of them.
/// Clicking it goes to that message; the next click goes to the one pinned before it.
struct PinnedBanner: View {
    /// Most recently pinned first.
    let messages: [MessageRow]
    let index: Int
    let showAll: (() -> Void)?
    let select: () -> Void
    @State private var isHovering = false

    var body: some View {
        let message = messages[index]
        let preview = ReplyPreview(replyingTo: message)
        HStack(spacing: 10) {
            Button(action: select) {
                HStack(spacing: 10) {
                    PinIndicator(count: messages.count, index: index)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(pinTint)
                            Text(messages.count > 1 ? "Pinned message \(index + 1) of \(messages.count)" : "Pinned message")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                        // The message itself rolls up to make way for the next one.
                        ZStack(alignment: .leading) {
                            snippet(message, preview)
                                .id(message.eventID)
                                .transition(.push(from: .bottom))
                        }
                        .clipped()
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(messages.count > 1 ? "Go to this message. Click again for the one pinned before it." : "Go to this message")
            .accessibilityLabel("Pinned message\(messages.count > 1 ? " \(index + 1) of \(messages.count)" : ""), from \(message.senderName): \(preview?.text ?? "")")
            .accessibilityHint("Goes to this message")
            if let showAll {
                Button("View All", action: showAll)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .help("All pinned messages")
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .onHoverInFrontWindow { isHovering = $0 }
    }

    private func snippet(_ message: MessageRow, _ preview: ReplyPreview?) -> some View {
        HStack(spacing: 4) {
            Text(message.senderName)
                .fontWeight(.semibold)
                .foregroundStyle(AvatarView.color(for: message.sender))
            if let icon = preview?.icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(preview?.text ?? "")
                .foregroundStyle(.primary)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.tail)
    }
}

/// A short stack of bars, one per pinned message (a few at a time when there are many), with
/// the one showing lit.
private struct PinIndicator: View {
    let count: Int
    let index: Int

    var body: some View {
        let shown = min(count, 3)
        let first = count <= 3 ? 0 : min(max(index - 1, 0), count - 3)
        VStack(spacing: 2) {
            ForEach(0..<shown, id: \.self) { offset in
                Capsule()
                    .fill(first + offset == index ? AnyShapeStyle(pinTint) : AnyShapeStyle(.quaternary))
            }
        }
        .frame(width: 3, height: 30)
        .animation(.snappy(duration: 0.25), value: index)
        .accessibilityHidden(true)
    }
}

/// All of a room's pinned messages, in the side panel. Clicking one goes to it in the
/// conversation.
struct PinnedListView: View {
    let account: AccountSession
    let roomID: String
    @State private var pins: RoomTimeline?

    var body: some View {
        Group {
            if let pins {
                let messages = ordered(pins)
                if !messages.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages, id: \.itemID) { message in
                                PinnedRow(message: message, media: account.media,
                                          canUnpin: pins.permissions.canPin) {
                                    guard let eventID = message.eventID else { return }
                                    account.timeline(for: roomID)?.requestedJump = eventID
                                } unpin: {
                                    guard let eventID = message.eventID else { return }
                                    Task { await pins.setPinned(false, eventID: eventID) }
                                }
                                Divider().padding(.leading, 50)
                            }
                        }
                    }
                } else if pins.isLoading || !pins.pinnedEventIDs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No Pinned Messages",
                                           systemImage: "pin",
                                           description: Text("Pin a message from its \u{22EF} menu to keep it here, where everyone in the room can find it."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if pins == nil { pins = account.pinnedTimeline(roomID: roomID) }
        }
        .onDisappear {
            pins?.stop()
            pins = nil
        }
    }

    /// Most recently pinned first.
    private func ordered(_ pins: RoomTimeline) -> [MessageRow] {
        var byID: [String: MessageRow] = [:]
        for case let message? in pins.rows.map(\.message) {
            if let id = message.eventID { byID[id] = message }
        }
        return pins.pinnedEventIDs.reversed().compactMap { byID[$0] }
    }
}

private struct PinnedRow: View {
    let message: MessageRow
    let media: MediaLoader
    let canUnpin: Bool
    let open: () -> Void
    let unpin: () -> Void
    @State private var isHovering = false

    var body: some View {
        let preview = ReplyPreview(replyingTo: message)
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(media: media, url: message.senderAvatarURL, name: message.senderName,
                           seed: message.sender, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.senderName)
                            .fontWeight(.semibold)
                            .foregroundStyle(AvatarView.color(for: message.sender))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(message.date.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .opacity(isHovering && canUnpin ? 0 : 1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let icon = preview?.icon {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(preview?.text ?? "")
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if isHovering, canUnpin {
                ActionButton(help: "Unpin", action: unpin) {
                    Image(systemName: "pin.slash")
                }
                .padding(.top, 5)
                .padding(.trailing, 6)
            }
        }
        .onHoverInFrontWindow { isHovering = $0 }
        .help("Go to this message")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Unpin") { if canUnpin { unpin() } }
    }
}
