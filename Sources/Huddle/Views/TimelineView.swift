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

    /// Whether the newest message is on screen; new messages only auto-scroll when it is.
    @State private var isAtBottom = true
    @State private var pinnedBeforeResize = true
    private static let bottomID = "timeline-bottom"

    private struct ReadTrigger: Equatable {
        let lastRow: String?
        let isAtBottom: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if timeline.hasMoreHistory, !timeline.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            // Asks again after each request for as long as the spinner stays visible.
                            .task(id: timeline.historyRequests) { await timeline.loadOlder() }
                    }
                    ForEach(timeline.rows) { row in
                        TimelineRowView(row: row, timeline: timeline, media: media, onOpenThread: onOpenThread)
                            .id(row.id)
                        if row.id == threadRootRowID {
                            RepliesDivider(count: replyCount)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onAppear {
                            isAtBottom = true
                            pinnedBeforeResize = true
                        }
                        .onDisappear {
                            isAtBottom = false
                            // Cleared a beat later, so a resize that pushes the newest message out
                            // of view still knows it was there.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                if !isAtBottom { pinnedBeforeResize = false }
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            // A room opens at its newest message. A thread starts at its root message, so a short
            // one sits under the header; a long one is then scrolled to its newest reply.
            .defaultScrollAnchor(timeline.threadRoot == nil ? .bottom : .top)
            .onChange(of: timeline.rows.last?.id) { previousLast, _ in
                if previousLast == nil {
                    // First content: lazy row heights settle over a few layout passes.
                    settleAtBottom(proxy)
                } else if isAtBottom {
                    scrollToBottom(proxy)
                }
            }
            .onAppear {
                if !timeline.rows.isEmpty { settleAtBottom(proxy) }
            }
            // Opening or closing the side panel changes the width and re-wraps every message;
            // if the newest message was in view, keep it there.
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { _ in
                if pinnedBeforeResize { settleAtBottom(proxy) }
            }
            .onChange(of: timeline.prependCount) {
                // Older messages were added above: stay on the message the user was reading.
                if let anchor = timeline.prependAnchorID, !isAtBottom {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom, !timeline.rows.isEmpty {
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

    /// In a thread, the root message's row: replies are set off below it.
    private var threadRootRowID: String? {
        guard timeline.threadRoot != nil else { return nil }
        return timeline.rows.first(where: \.isMessage)?.id
    }

    private var replyCount: Int {
        max(timeline.rows.filter(\.isMessage).count - 1, 0)
    }

    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        for delay in [0, 0.05, 0.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        // After layout, so the newest row has its final height.
        DispatchQueue.main.async {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
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
        .padding(.top, message.showsHeader ? 8 : 1)
        .padding(.bottom, 1)
        .opacity(message.sendState == .sending ? 0.55 : 1)
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
