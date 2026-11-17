import SwiftUI

/// The panel beside a room's timeline: one thread, or the list of the room's threads.
struct ThreadPanel: View {
    enum Content: Equatable {
        case thread(String)
        case threadList
    }

    let account: AccountSession
    let roomID: String
    let roomName: String
    let content: Content
    /// Changes what the panel shows; nil closes it.
    let show: (Content?) -> Void

    /// True when the open thread was reached from the list, so there is a way back to it.
    @State private var cameFromList = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch content {
            case .thread(let root):
                ThreadTimelineHost(account: account, roomID: roomID, root: root)
                    .id(root)
            case .threadList:
                ThreadListView(account: account, roomID: roomID) { root in
                    cameFromList = true
                    show(.thread(root))
                }
            }
        }
        .background(.background)
        .onChange(of: content) { _, new in
            if new == .threadList { cameFromList = false }
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
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(content == .threadList ? "Threads" : "Thread")
                    .font(.headline)
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
            .keyboardShortcut(.cancelAction)
            .help("Close")
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

    var body: some View {
        Group {
            if let timeline {
                TimelineView(timeline: timeline, media: account.media, placeholder: "Reply in thread")
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
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(list.entries) { entry in
                                ThreadListRow(entry: entry, media: account.media) { open(entry.id) }
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
        .onHover { isHovering = $0 }
    }
}
