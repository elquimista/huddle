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

/// Along the top of a room with pinned messages: one of them, and the way to all of them.
/// Clicking it goes to that message; the arrows show the others in turn, without going there;
/// the pin and View All open them all beside the conversation; and it can be put away.
struct PinnedBanner: View {
    /// Most recently pinned first.
    let messages: [MessageRow]
    let index: Int
    /// The user's own names for people, for mentions in the message.
    let contactName: (String) -> String?
    let showAll: (() -> Void)?
    /// Goes to the message shown.
    let go: () -> Void
    /// Shows the next one pinned before (1) or after (-1) it, round and round.
    let step: (Int) -> Void
    /// Puts the banner away in this room.
    let hide: () -> Void
    @State private var isHovering = false
    @Environment(\.nameColorRoom) private var nameColorRoom

    var body: some View {
        let message = messages[index]
        let preview = ReplyPreview(replyingTo: message, contactName: contactName)
        HStack(spacing: 8) {
            PinIndicator(count: messages.count, index: index)
            Button(action: { showAll?() }) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(pinTint)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("All pinned messages")
            .accessibilityLabel("All pinned messages")
            Button(action: go) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(messages.count > 1 ? "Pinned message \(index + 1) of \(messages.count)" : "Pinned message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    // The message itself rolls up to make way for the next one.
                    ZStack(alignment: .leading) {
                        snippet(message, preview)
                            .id(message.eventID)
                            .transition(.push(from: .bottom))
                    }
                    .clipped()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to this message")
            .accessibilityLabel("Pinned message\(messages.count > 1 ? " \(index + 1) of \(messages.count)" : ""), from \(message.senderName): \(preview?.text ?? "")")
            .accessibilityHint("Goes to this message")
            if messages.count > 1 {
                HStack(spacing: 0) {
                    stepButton("chevron.up", help: "The one pinned after it") { step(-1) }
                    stepButton("chevron.down", help: "The one pinned before it") { step(1) }
                }
            }
            if let showAll {
                Button("View All", action: showAll)
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .help("All pinned messages")
            }
            Button(action: hide) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide in this room. Room ▸ Show Pinned Banner brings it back.")
            .accessibilityLabel("Hide pinned messages banner")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .onHoverInFrontWindow { isHovering = $0 }
    }

    private func stepButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func snippet(_ message: MessageRow, _ preview: ReplyPreview?) -> some View {
        HStack(spacing: 4) {
            Text(message.senderName)
                .fontWeight(.semibold)
                .foregroundStyle(NameColors.shared.color(for: message.sender, inRoom: nameColorRoom))
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

/// All of a room's pinned messages, in the side panel, most recently pinned first: each in
/// full, as the conversation shows it (its text to read and select, a picture to open, a file
/// to open, a sound or a video to play), with who sent it and when. Each one goes to its
/// message in the conversation (or opens its thread), and can be unpinned by those who may.
struct PinnedListView: View {
    let account: AccountSession
    let roomID: String
    /// Shows a thread in the panel, for a message pinned in one.
    let openThread: (String) -> Void
    @State private var pins: RoomTimeline?
    /// How wide a message's content can be: the panel's width, less the row's margins.
    @State private var contentWidth: CGFloat = 300

    var body: some View {
        Group {
            if let pins {
                let messages = ordered(pins)
                if !messages.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages, id: \.itemID) { message in
                                PinnedRow(message: message, pins: pins, media: account.media,
                                          canUnpin: pins.permissions.canPin) {
                                    go(to: message)
                                } unpin: {
                                    guard let eventID = message.eventID else { return }
                                    Task { await pins.setPinned(false, eventID: eventID) }
                                }
                                Divider()
                            }
                            bannerNote
                        }
                        .environment(\.messageContentWidth, contentWidth)
                    }
                    .onGeometryChange(for: CGFloat.self, of: { max($0.size.width - PinnedRow.margin * 2, 120) }) {
                        contentWidth = $0
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
            if let pins {
                AudioPlayback.shared.stop(owner: pins)
                VideoPlayback.shared.stop(owner: pins)
                pins.stop()
            }
            pins = nil
        }
    }

    /// Where the banner has been put away in this room: a way to have it back.
    @ViewBuilder private var bannerNote: some View {
        if account.hiddenPinBanners.contains(roomID) {
            HStack(spacing: 6) {
                Text("The banner is hidden in this room.")
                    .foregroundStyle(.secondary)
                Button("Show Banner") { account.hiddenPinBanners.remove(roomID) }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
    }

    private func go(to message: MessageRow) {
        if let root = message.threadRootID {
            openThread(root)
        } else if let eventID = message.eventID {
            account.timeline(for: roomID)?.requestedJump = eventID
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

/// One pinned message, in full: who sent it and when, then the message as the conversation
/// draws it. Pointed at, Go to Message and Unpin at its top right; the same in its menu, with
/// Copy Text.
private struct PinnedRow: View {
    let message: MessageRow
    let pins: RoomTimeline
    let media: MediaLoader
    let canUnpin: Bool
    let go: () -> Void
    let unpin: () -> Void
    @State private var isHovering = false
    @Environment(\.nameColorRoom) private var nameColorRoom

    static let margin: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AvatarView(media: media, url: message.senderAvatarURL, name: message.senderName,
                           seed: message.sender, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text(message.senderName)
                        .fontWeight(.semibold)
                        .foregroundStyle(NameColors.shared.color(for: message.sender, inRoom: nameColorRoom))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            content
        }
        .padding(Self.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            if isHovering {
                HStack(spacing: 0) {
                    ActionButton(help: message.threadRootID == nil ? "Go to Message" : "Show in Thread", action: go) {
                        Image(systemName: "arrow.forward.circle")
                    }
                    if canUnpin {
                        ActionButton(help: "Unpin", action: unpin) {
                            Image(systemName: "pin.slash")
                        }
                    }
                }
                .padding(3)
                .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator) }
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
        }
        .contentShape(Rectangle())
        .onHoverInFrontWindow { isHovering = $0 }
        .contextMenu {
            Button(message.threadRootID == nil ? "Go to Message" : "Show in Thread", action: go)
            if let text = copyableText {
                Button("Copy Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            if canUnpin {
                Divider()
                Button("Unpin", action: unpin)
            }
        }
        .accessibilityAction(named: message.threadRootID == nil ? "Go to Message" : "Show in Thread", go)
        .accessibilityAction(named: "Unpin") { if canUnpin { unpin() } }
    }

    /// When it was sent, the day included, and whether in a thread.
    private var subtitle: String {
        let when = message.date.pinnedLabel
        return message.threadRootID == nil ? when : "\(when) · In a thread"
    }

    private var copyableText: String? {
        switch message.body {
        case .text(let text), .emote(let text): text
        case .image(let image): image.caption
        case .file(let file): file.caption
        case .audio(let audio): audio.caption
        default: nil
        }
    }

    private func styled(_ text: String) -> AttributedString {
        MessageFormatter.renderCached(text: text, html: message.html, mentionsRoom: message.mentionsRoom,
                                      ownUserID: pins.ownUserID, names: pins.nameVersion,
                                      name: pins.knownName(for:))
    }

    private func caption(_ caption: String?) -> some View {
        Group {
            if let caption {
                Text(styled(caption))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.body {
        case .text(let text):
            Text(styled(text))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .emote(let text):
            (Text("* \(message.senderName) ") + Text(styled(text)))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .image(let image):
            ImageMessageView(image: image, media: media, open: { shown in
                ImageViewerState.shared.open(image, media: media, placeholder: shown)
            })
            caption(image.caption)
        case .file(let file):
            if let video = file.video, file.isPlayableVideo, file.media != nil {
                VideoMessageView(id: message.eventID ?? file.filename, file: file, video: video, media: media, owner: pins)
            } else {
                FileMessageView(file: file, media: media)
            }
            caption(file.caption)
        case .audio(let audio):
            AudioMessageView(id: message.eventID ?? audio.media.source.url(), audio: audio, media: media, owner: pins)
            caption(audio.caption)
        default:
            let preview = ReplyPreview(replyingTo: message, contactName: pins.knownName(for:))
            Text(preview?.text ?? "")
                .foregroundStyle(.secondary)
        }
    }
}

extension Date {
    /// "Today at 6:06 PM", "Yesterday at 6:06 PM", "Nov 24 at 6:06 PM", or "Nov 24, 2025" further
    /// back: when a pinned message was sent, which can be long ago.
    var pinnedLabel: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "Today at \(time)" }
        if calendar.isDateInYesterday(self) { return "Yesterday at \(time)" }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return "\(formatted(.dateTime.month(.abbreviated).day())) at \(time)"
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }
}
