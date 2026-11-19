import SwiftUI

/// The panel beside a room's timeline: one thread, or the list of the room's threads.
struct ThreadPanel: View {
    enum Content: Hashable {
        case thread(String)
        case threadList
        case pinned
        case search
        case info
    }

    let account: AccountSession
    let roomID: String
    let roomName: String
    let content: Content
    /// Changes what the panel shows; nil closes it.
    let show: (Content?) -> Void

    /// True when the open thread was reached from the list, so there is a way back to it.
    @State private var cameFromList = false
    /// False for a moment as the panel arrives, so its content can fade in just behind it.
    @State private var hasSettled = false
    /// The pages laid out side by side, left to right: the one showing, or while moving from
    /// one to another, both.
    @State private var pages: [Content] = []
    /// Whether the last of `pages` is the one in view, rather than the first.
    @State private var showsLast = false
    /// Counts moves, so one that has been overtaken doesn't tidy up after the next.
    @State private var moveCount = 0
    /// A page is editing something (Room Info's name and topic), and Escape cancels that
    /// instead of closing the panel.
    @State private var pageTakesEscape = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: content)
            Divider()
            // Moving between pages slides the strip they sit in, by layout rather than by
            // shifting its picture: the scrolling parts of a page are drawn by AppKit, and
            // a shifted picture leaves them behind, one page showing through the other.
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(pages, id: \.self) { page in
                        self.page(page)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height,
                       alignment: showsLast ? .trailing : .leading)
            }
            // Whatever it shows (a thread, the list, a short "No Threads Yet"), the panel is the
            // full height of the room: shrunk to its content, it would float mid-column.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onPreferenceChange(PanelTakesEscape.self) { pageTakesEscape = $0 }
        }
        // The content fades in a beat behind the panel, so the panel seems to bring it along
        // rather than arrive already full.
        .opacity(hasSettled ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.background)
        .onAppear {
            if pages.isEmpty { pages = [content] }
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : Motion.panelContent) { hasSettled = true }
        }
        .onChange(of: content) { _, new in move(to: new) }
    }

    @ViewBuilder private func page(_ page: Content) -> some View {
        switch page {
        case .thread(let root):
            ThreadTimelineHost(account: account, roomID: roomID, root: root)
                .id(root)
        case .threadList:
            ThreadListView(account: account, roomID: roomID) { root in
                cameFromList = true
                show(.thread(root))
            }
        case .pinned:
            PinnedListView(account: account, roomID: roomID)
        case .search:
            SearchPanelView(account: account, roomID: roomID)
        case .info:
            RoomInfoPanelView(account: account, roomID: roomID)
        }
    }

    /// Slides to `new`: in from the right going into a thread, from the left going back to
    /// the list. The new page is put beside the old one first, out of sight, and the strip
    /// moves on the next turn, once both are in place. Reduce Motion swaps them with a fade.
    private func move(to new: Content) {
        if new == .threadList { cameFromList = false }
        let visible = (showsLast ? pages.last : pages.first) ?? new
        moveCount += 1
        guard visible != new else {
            pages = [new]
            showsLast = false
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.18)) {
                pages = [new]
                showsLast = false
            }
            return
        }
        // Into a thread goes deeper, from the right; out of one comes back, from the left.
        // Between the two lists, which sit side by side, it is a quick fade.
        let forward: Bool
        switch (visible, new) {
        case (_, .thread): forward = true
        case (.thread, _): forward = false
        default:
            withAnimation(.easeOut(duration: 0.18)) {
                pages = [new]
                showsLast = false
            }
            return
        }
        pages = forward ? [visible, new] : [new, visible]
        showsLast = !forward
        let count = moveCount
        DispatchQueue.main.async {
            guard count == moveCount else { return }
            // Tidied only once the strip has come fully to rest, or the swap could nudge it.
            withAnimation(Motion.panelPush, completionCriteria: .removed) {
                showsLast = forward
            } completion: {
                // Only the new page stays; it doesn't move as the strip loses the old one.
                guard count == moveCount else { return }
                pages = [new]
                showsLast = false
            }
        }
    }

    private var title: String {
        switch content {
        case .thread: "Thread"
        case .threadList: "Threads"
        case .pinned: "Pinned Messages"
        case .search: "Search"
        case .info: account.allRooms.first { $0.id == roomID }?.isDirect == true ? "Chat Info" : "Room Info"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if cameFromList, content != .threadList {
                Button {
                    show(.threadList)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("All threads")
                .accessibilityLabel("All threads")
                .transition(.opacity)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    // Swapped outright as it glides aside for the back button: a crossfade
                    // would show both words, one shifted against the other.
                    .contentTransition(.identity)
                Text(roomName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                show(nil)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(pageTakesEscape ? nil : .cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
    }
}

/// Owns one thread's timeline for as long as its panel is open.
private struct ThreadTimelineHost: View {
    let account: AccountSession
    let roomID: String
    let root: String
    @State private var timeline: RoomTimeline?
    @AppStorage(MessageLayout.key) private var chosenLayout = MessageLayout.modern

    var body: some View {
        Group {
            if let timeline {
                TimelineView(timeline: timeline, media: account.media, placeholder: "Reply in thread")
                    // The panel is narrow; the compact layout crams it.
                    .environment(\.forcedMessageLayout, chosenLayout == .irc ? .modern : nil)
                    .environment(\.bubblesOnContentBackground, true)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if timeline == nil { timeline = account.threadTimeline(roomID: roomID, root: root) }
        }
        .onDisappear {
            timeline?.stop()
            timeline = nil
        }
    }
}

private struct ThreadListView: View {
    let account: AccountSession
    let roomID: String
    let open: (String) -> Void
    @State private var list: RoomThreadList?

    var body: some View {
        Group {
            if let list {
                if list.entries.isEmpty {
                    if list.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("No Threads Yet",
                                               systemImage: "bubble.left.and.text.bubble.right",
                                               description: Text("Hover over a message and choose Reply in thread to start one."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let new = Set(account.openTimeline(for: roomID)?.newThreads.map(\.id) ?? [])
                            ForEach(list.entries) { entry in
                                ThreadListRow(entry: entry, isNew: new.contains(entry.id), media: account.media) {
                                    open(entry.id)
                                }
                                Divider().padding(.leading, 50)
                            }
                            if list.hasMore {
                                ProgressView()
                                    .controlSize(.small)
                                    .padding(12)
                                    .task(id: list.entries.count) { await list.loadMore() }
                            }
                        }
                    }
                }
            } else {
                Color.clear
            }
        }
        .onAppear {
            if list == nil { list = account.threadList(roomID: roomID) }
        }
        .onDisappear {
            list?.stop()
            list = nil
        }
    }
}

private struct ThreadListRow: View {
    let entry: ThreadListEntry
    /// Someone else has replied since you last read it, as the mark under its root says.
    let isNew: Bool
    let media: MediaLoader
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(media: media,
                           url: entry.senderAvatarURL,
                           name: entry.senderName,
                           seed: entry.senderID,
                           size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.senderName)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.latestDate.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(entry.preview)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        Text(entry.replyCount == 1 ? "1 reply" : "\(entry.replyCount) replies")
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.accentColor)
                            .fixedSize()
                        if isNew {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 7, height: 7)
                                .padding(.leading, 2)
                            Text("New replies")
                                .fontWeight(.semibold)
                                .fixedSize()
                        }
                        if let name = entry.latestReplierName {
                            Text("· latest from \(name)")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
    }
}

/// Set by a panel page while Escape is its own (to cancel an edit), so the panel's close
/// button doesn't take it too.
struct PanelTakesEscape: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}
