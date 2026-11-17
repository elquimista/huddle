import MatrixRustSDK
import SwiftUI

/// A scrolling list of messages with a composer: a room's timeline, or one thread's.
struct TimelineView: View {
    let timeline: RoomTimeline
    let media: MediaLoader
    var placeholder = "Message"
    /// Opens a message's thread. Nil inside a thread, where there is nothing further to open.
    var onOpenThread: ((String) -> Void)?
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    /// Whether the newest message is on screen.
    @State private var isAtBottom = true
    /// The intent to stay on the newest message. Unlike `isAtBottom` it survives the moment a
    /// batch of messages or a resize pushes the newest one out of view, so the view can follow.
    @State private var followsNewest = true
    /// Whether the top of the loaded history is on screen, which is when to fetch more.
    @State private var historyEdgeVisible = false
    private static let bottomID = "timeline-bottom"

    private struct ReadTrigger: Equatable {
        let lastRow: String?
        let isAtBottom: Bool
    }

    private struct HistoryTrigger: Equatable {
        let edgeVisible: Bool
        let finishedRequests: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy on purpose. A lazy stack only estimates the height of rows it hasn't
                // drawn, so scrolling to the newest message lands in the wrong place, gets
                // corrected a frame later (flicker), and sometimes leaves the view blank.
                VStack(alignment: .leading, spacing: 0) {
                    if timeline.hasMoreHistory, !timeline.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { historyEdgeVisible = $0 }
                    }
                    ForEach(timeline.rows) { row in
                        TimelineRowView(row: row, timeline: timeline, media: media, onOpenThread: onOpenThread)
                            .id(row.id)
                        if row.id == threadRootRowID {
                            RepliesDivider(count: replyCount)
                        }
                    }
                    // The very last thing in the scroll view, with nothing below it: scrolling to it
                    // is scrolling to the end. The gap under the newest message sits above it.
                    Color.clear
                        .frame(height: 8)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { visible in
                            isAtBottom = visible
                            if visible {
                                followsNewest = true
                            } else {
                                // Cleared a beat later, so content that pushes the newest message
                                // out of view can still be followed.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                    if !isAtBottom { followsNewest = false }
                                }
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // Rows keep changing height after they first appear: messages decrypt, reactions
                // and thread summaries arrive, more batches load. Whenever the content's height
                // changes while following the newest message, go back to the end.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }) { _ in
                    if followsNewest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            // A room opens at its newest message. A thread starts at its root message, so a short
            // one sits under the header; a long one is then scrolled to its newest reply.
            .defaultScrollAnchor(timeline.threadRoot == nil ? .bottom : .top)
            .onChange(of: timeline.rows.last?.id) { previousLast, _ in
                // The first content, or a new message while following the newest.
                if previousLast == nil || followsNewest { scrollToBottom(proxy) }
            }
            .onAppear {
                if !timeline.rows.isEmpty { scrollToBottom(proxy) }
            }
            // Opening or closing the side panel changes the width and re-wraps every message;
            // if the newest message was in view, keep it there once the change has finished.
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { _ in
                guard followsNewest else { return }
                scrollToBottom(proxy)
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if followsNewest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }
            .onChange(of: timeline.prependCount) {
                // Older messages were added above. On the newest message, stay there; otherwise
                // stay on the message being read. Someone at the top edge is reading history even
                // if they left the newest message only a moment ago.
                if isAtBottom || (followsNewest && !historyEdgeVisible) {
                    scrollToBottom(proxy)
                } else if let anchor = timeline.prependAnchorID {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            // Fetches history while its top edge is on screen, again after each request finishes.
            .task(id: HistoryTrigger(edgeVisible: historyEdgeVisible, finishedRequests: timeline.historyRequests)) {
                if historyEdgeVisible, timeline.hasMoreHistory { await timeline.loadOlder() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom, !followsNewest, !timeline.rows.isEmpty {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(.separator) }
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Jump to latest")
                }
            }
            .overlay {
                if timeline.isLoading { ProgressView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(proxy) }
        }
        // Runs when a new message arrives and when the newest one scrolls into view.
        .task(id: ReadTrigger(lastRow: timeline.rows.last?.id, isAtBottom: isAtBottom)) {
            if isAtBottom, !timeline.rows.isEmpty { await timeline.markAsRead() }
        }
        .onAppear { composerFocused = true }
    }

    /// Whether a view inside the scroll view is within, or just outside, the visible area.
    private static func isOnScreen(_ geometry: GeometryProxy) -> Bool {
        guard let visible = geometry.bounds(of: .scrollView) else { return false }
        return visible.insetBy(dx: 0, dy: -24).intersects(geometry.frame(in: .local))
    }

    /// In a thread, the root message's row: replies are set off below it.
    private var threadRootRowID: String? {
        guard timeline.threadRoot != nil else { return nil }
        return timeline.rows.first(where: \.isMessage)?.id
    }

    private var replyCount: Int {
        max(timeline.rows.filter(\.isMessage).count - 1, 0)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        followsNewest = true
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = timeline.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit { send(proxy) }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
                Button { send(proxy) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .help("Send (Return). Option-Return for a new line.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        // Not Divider: inside the room's HStack it would draw itself vertically.
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        scrollToBottom(proxy)
        Task { await timeline.send(text) }
    }
}

private struct RepliesDivider: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(count == 0 ? "No replies yet" : count == 1 ? "1 reply" : "\(count) replies")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct TimelineRowView: View {
    let row: TimelineRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let onOpenThread: ((String) -> Void)?

    var body: some View {
        switch row.kind {
        case .message(let message):
            MessageView(message: message, timeline: timeline, media: media, onOpenThread: onOpenThread)
        case .notice(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .dateDivider(let date):
            Text(date.formatted(date: .complete, time: .omitted))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 6)
        case .readMarker:
            HStack(spacing: 8) {
                VStack { Divider() }
                Text("New")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct MessageView: View {
    let message: MessageRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let onOpenThread: ((String) -> Void)?

    /// Opens this message's thread, when it can have one from here.
    private var openThread: (() -> Void)? {
        guard let onOpenThread, let eventID = message.eventID else { return nil }
        return { onOpenThread(eventID) }
    }
    @State private var isHovering = false

    private static let quickReactions = ["👍", "❤️", "😂", "🎉"]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.showsHeader {
                AvatarView(media: media,
                           url: message.senderAvatarURL,
                           name: message.senderName,
                           seed: message.sender,
                           size: 32)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if message.showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message.senderName)
                            .fontWeight(.semibold)
                            .foregroundStyle(AvatarView.color(for: message.sender))
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                bodyView
                if !message.reactions.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(message.reactions) { reaction in
                            Button {
                                Task { await timeline.toggleReaction(reaction.key, on: message.itemID) }
                            } label: {
                                Text("\(reaction.key) \(reaction.count)")
                                    .font(.callout)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(reaction.isOwn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if let thread = message.thread, let openThread {
                    ThreadChip(thread: thread, media: media, action: openThread)
                }
                if message.sendState == .failed {
                    Button("Failed to send. Retry") {
                        Task { await timeline.retry(message.itemID) }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
        // A gutter on the right for read receipts, so they never sit on top of the text.
        .padding(.trailing, ReceiptView.gutter)
        .padding(.top, message.showsHeader ? 8 : 1)
        .padding(.bottom, 1)
        .opacity(message.sendState == .sending ? 0.55 : 1)
        .overlay(alignment: .bottomTrailing) {
            ReceiptView(message: message, media: media)
                .padding(.bottom, 3)
        }
        .overlay(alignment: .topTrailing) {
            if isHovering, message.sendState == nil {
                HStack(spacing: 2) {
                    ForEach(Self.quickReactions, id: \.self) { emoji in
                        Button(emoji) {
                            Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                    }
                    if let openThread {
                        Divider().frame(height: 14)
                        Button(action: openThread) {
                            Image(systemName: "bubble.left.and.text.bubble.right")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(3)
                        .help("Reply in thread")
                    }
                }
                .padding(.horizontal, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.separator) }
                .offset(y: -6)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let openThread {
                Button(message.thread == nil ? "Reply in Thread" : "Open Thread", action: openThread)
            }
            if case .text(let text) = message.body {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
    }

    @ViewBuilder private var bodyView: some View {
        switch message.body {
        case .text(let text):
            (Text(text.linkified) + Text(message.isEdited ? " (edited)" : "").font(.caption).foregroundStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .emote(let text):
            Text("* \(message.senderName) \(text)")
                .italic()
                .textSelection(.enabled)
        case .image(let ref, let caption, let aspectRatio):
            VStack(alignment: .leading, spacing: 4) {
                MediaImageView(media: media, ref: ref, aspectRatio: aspectRatio)
                    .padding(.vertical, 3)
                if let caption {
                    Text(caption.linkified).textSelection(.enabled)
                }
            }
        case .attachment(let icon, let name):
            Label(name, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .undecryptable:
            Label("Waiting for encryption keys", systemImage: "lock")
                .foregroundStyle(.secondary)
        case .redacted:
            Label("Message deleted", systemImage: "trash")
                .foregroundStyle(.secondary)
        case .unsupported(let text):
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// What sits at the right of a message: who has read up to it (group rooms), or how far your
/// own message has got (one grey tick while sending, two grey when sent, two coloured when read).
private struct ReceiptView: View {
    static let gutter: CGFloat = 64
    private static let maxAvatars = 3

    let message: MessageRow
    let media: MediaLoader
    @State private var showsReaders = false

    var body: some View {
        if !message.readers.isEmpty {
            Button {
                showsReaders = true
            } label: {
                HStack(spacing: 3) {
                    if message.readers.count > Self.maxAvatars {
                        Text("+\(message.readers.count - Self.maxAvatars)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: -4) {
                        ForEach(message.readers.prefix(Self.maxAvatars).reversed()) { reader in
                            AvatarView(media: media, url: reader.avatarURL, name: reader.name, seed: reader.id, size: 16)
                                .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read by " + message.readers.map(\.name).formatted(.list(type: .and)))
            .popover(isPresented: $showsReaders, arrowEdge: .trailing) {
                ReadersList(readers: message.readers, media: media)
            }
        } else if let delivery = message.delivery {
            DeliveryMark(delivery: delivery, readDate: message.readDate,
                         readDateIsExact: message.readDateIsExact)
        }
    }
}

/// One grey tick while sending, two grey once the server has it, two coloured once read.
private struct DeliveryMark: View {
    let delivery: MessageRow.Delivery
    var readDate: Date?
    var readDateIsExact = false

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if delivery != .sending {
                Image(systemName: "checkmark").offset(x: 5)
            }
        }
        // Same width in every state, so the first tick doesn't shift when the second appears.
        .padding(.trailing, 5)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(delivery == .read ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        .help(label)
        .accessibilityLabel(label)
    }

    /// The message's own time is already shown beside the sender, so this adds only what isn't:
    /// the state, and when it was read if that is actually known.
    private var label: String {
        switch delivery {
        case .sending:
            return "Sending…"
        case .sent:
            return "Sent"
        case .read:
            // A receipt marks only the last message someone read. Earlier messages are known to
            // be read, but not when, so they get no time.
            if let readDate, readDateIsExact {
                return "Read \(Self.describe(readDate))"
            }
            return "Read"
        }
    }

    private static func describe(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }
}

private struct ReadersList: View {
    let readers: [MessageRow.Reader]
    let media: MediaLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read by")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(readers) { reader in
                HStack(spacing: 8) {
                    AvatarView(media: media, url: reader.avatarURL, name: reader.name, seed: reader.id, size: 22)
                    Text(reader.name)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    if let date = reader.date {
                        Text(date.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

/// "3 replies · Last reply 2 hours ago" under a message, Slack style. Opens the thread.
private struct ThreadChip: View {
    let thread: ThreadInfo
    let media: MediaLoader
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let sender = thread.latestSender {
                    AvatarView(media: media,
                               url: thread.latestSenderAvatarURL,
                               name: thread.latestSenderName ?? sender,
                               seed: sender,
                               size: 18)
                }
                Text(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                if thread.hasNewReplies {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text("New replies")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                } else if isHovering {
                    Text("View thread")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let date = thread.latestDate {
                    Text("Last reply \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 22)
            .padding(.vertical, 4)
            .frame(maxWidth: 340, alignment: .leading)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.trailing, 8)
            }
            .background(isHovering ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.separator.opacity(isHovering ? 1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.leading, -6)
        .padding(.top, 1)
    }
}

private struct MediaImageView: View {
    let media: MediaLoader
    let ref: MediaRef
    let aspectRatio: Double
    @State private var image: NSImage?

    private var size: CGSize {
        let width = min(360, 280 * max(aspectRatio, 0.5))
        return CGSize(width: width, height: min(width / aspectRatio, 420))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.quaternary)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .task(id: ref.source.url()) {
            image = await media.thumbnail(source: ref.source, size: 400)
        }
    }
}

extension String {
    /// Plain text with URLs turned into clickable links.
    var linkified: AttributedString {
        var result = AttributedString(self)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        for match in detector.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let url = match.url,
                  let range = Range(match.range, in: self),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}
