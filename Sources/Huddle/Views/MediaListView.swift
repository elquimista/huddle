import AppKit
import Perception
import SwiftUI
import UniformTypeIdentifiers

/// Which of a room's media and files the panel shows: one kind at a time.
enum MediaKind: String, CaseIterable, Identifiable {
    case images, videos, audio, pdfs, files

    /// The kind last shown, in any room.
    static let key = "mediaListKind"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .images: "Images"
        case .videos: "Videos"
        case .audio: "Audio"
        case .pdfs: "PDFs"
        case .files: "Files"
        }
    }

    /// Shown as a grid of pictures rather than a list.
    var isGrid: Bool { self == .images || self == .videos }

    func count(_ count: Int) -> String {
        switch self {
        case .images: count == 1 ? "1 image" : "\(count) images"
        case .videos: count == 1 ? "1 video" : "\(count) videos"
        case .audio: count == 1 ? "1 recording or sound" : "\(count) recordings and sounds"
        case .pdfs: count == 1 ? "1 PDF" : "\(count) PDFs"
        case .files: count == 1 ? "1 file" : "\(count) files"
        }
    }

    var emptyIcon: String {
        switch self {
        case .images: "photo"
        case .videos: "film"
        case .audio: "waveform"
        case .pdfs: "doc.richtext"
        case .files: "doc"
        }
    }

    var emptyText: String {
        switch self {
        case .images: "Pictures sent here will be found here."
        case .videos: "Videos sent here will be found here."
        case .audio: "Voice messages and sound files sent here will be found here."
        case .pdfs: "PDFs sent here will be found here."
        case .files: "Documents and other files sent here, PDFs among them, will be found here."
        }
    }
}

/// A picture, video, sound or file, and the message it came in.
struct MediaItem: Identifiable {
    enum Content {
        case image(ImageAttachment)
        case video(FileAttachment, VideoDetails)
        case audio(AudioAttachment)
        case file(FileAttachment)
    }

    let message: MessageRow
    let content: Content

    var id: String { message.eventID ?? message.sender + message.date.description }

    /// One of these sent in the room; nil for anything else, or one still being sent from here.
    init?(_ message: MessageRow) {
        guard message.sendState == nil, message.eventID != nil else { return nil }
        switch message.body {
        case .image(let image): content = .image(image)
        case .audio(let audio): content = .audio(audio)
        case .file(let file):
            if let video = file.video { content = .video(file, video) } else { content = .file(file) }
        default: return nil
        }
        self.message = message
    }

    func isKind(_ kind: MediaKind) -> Bool {
        switch (kind, content) {
        case (.images, .image), (.videos, .video), (.audio, .audio), (.files, .file): true
        case (.pdfs, .file(let file)): file.isPDF
        default: false
        }
    }

    /// "Bob, 12 Nov 2026 at 9:41", for its tooltip.
    var byline: String {
        "\(message.senderName), \(message.date.formatted(date: .abbreviated, time: .shortened))"
    }
}

extension FileAttachment {
    var isPDF: Bool {
        type?.conforms(to: .pdf) == true || mimetype?.lowercased() == "application/pdf"
    }
}

/// The items sent in one month, newest first.
private struct MediaMonth: Identifiable {
    let id: String
    let title: String
    var items: [MediaItem]

    static func grouping(_ items: [MediaItem]) -> [MediaMonth] {
        let calendar = Calendar.current
        let thisYear = calendar.component(.year, from: .now)
        var months: [MediaMonth] = []
        for item in items {
            let parts = calendar.dateComponents([.year, .month], from: item.message.date)
            let id = "\(parts.year ?? 0)-\(parts.month ?? 0)"
            if months.last?.id == id {
                months[months.count - 1].items.append(item)
            } else {
                let title = parts.year == thisYear
                    ? item.message.date.formatted(.dateTime.month(.wide))
                    : item.message.date.formatted(.dateTime.month(.wide).year())
                months.append(MediaMonth(id: id, title: title, items: [item]))
            }
        }
        return months
    }
}

/// Everything sent in a room as a picture, video, sound or file, thread replies among them, in
/// its side panel: one kind at a time, newest first under the month it was sent, going back as
/// far as the room does as the list is scrolled. Pictures and videos are a grid, the rest a list.
/// A picture opens full size, a video plays in the conversation, a sound plays where it is, and a
/// file opens in its app; each one's menu goes to its message and saves it.
struct MediaListView: View {
    let account: AccountSession
    let roomID: String
    /// Shows a thread in the panel, for something sent in one.
    let openThread: (String) -> Void
    @State private var timeline: RoomTimeline?
    @AppSetting(MediaKind.key) private var kind = MediaKind.images

    var body: some View { WithPerceptionTracking {
        VStack(spacing: 0) {
            Picker("Show", selection: $kind) {
                ForEach(MediaKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let timeline {
                MediaKindList(account: account, roomID: roomID, timeline: timeline, kind: kind,
                              openThread: openThread)
                    // Each kind from its top, newest first.
                    .id(kind)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if timeline == nil { timeline = account.mediaTimeline(roomID: roomID) }
        }
        .onDisappear {
            if let timeline {
                AudioPlayback.shared.stop(owner: timeline)
                timeline.stop()
            }
            timeline = nil
        }
    } }
}

private struct MediaKindList: View {
    let account: AccountSession
    let roomID: String
    let timeline: RoomTimeline
    let kind: MediaKind
    let openThread: (String) -> Void
    @State private var search = Search()

    /// How the look back through the room is going. It goes on while things of this kind turn
    /// up, and stops for the user to say once none has for a while: a room's whole history can
    /// be thousands of requests to the server (3,000 messages took 158, and 23 seconds), where
    /// what's been looked through already, kept on this Mac, goes by in moments.
    private struct Search {
        /// When the search started, was taken up again, or last found something.
        var since = Date.now
        /// How many had been found then.
        var found = 0
        /// Goes up when the user says to look further, to start the loader again.
        var round = 0
        /// Stopped, nothing having turned up for a while, until the user says to look further.
        var isPaused = false
    }

    /// Looking goes on as long as something turns up at least this often.
    private static let patience: TimeInterval = DevHooks.mediaSearchPatience ?? 10

    /// Whether to ask for older messages again, with `count` found so far. Notes a find, and
    /// stops once there hasn't been one for a while.
    private func looksFurther(count: Int) -> Bool {
        if count > search.found {
            search.found = count
            search.since = .now
        }
        guard Date.now.timeIntervalSince(search.since) < Self.patience else {
            search.isPaused = true
            return false
        }
        return true
    }

    /// Stopped, with more of the room to look through.
    private var isPaused: Bool { search.isPaused && timeline.hasMoreHistory }

    private func lookFurther() {
        search.since = .now
        search.isPaused = false
        search.round += 1
    }

    var body: some View { WithPerceptionTracking {
        let items = timeline.rows.reversed().compactMap { $0.message.flatMap(MediaItem.init) }.filter { $0.isKind(kind) }
        if items.isEmpty {
            VStack(spacing: 0) {
                if isPaused {
                    EmptyState {
                        Label("No \(kind.title) Found Yet", systemImage: kind.emptyIcon)
                    } description: {
                        Text("None in the latest messages here. Looking further back may take a while in a long conversation.")
                    } actions: {
                        Button("Look Further Back", action: lookFurther)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if timeline.isLoading || timeline.hasMoreHistory {
                    // Further back, as long as there's anywhere to look.
                    VStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking back through the room…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { loader(count: 0) }
                } else {
                    EmptyState("No \(kind.title)", systemImage: kind.emptyIcon,
                               description: Text(kind.emptyText))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(MediaMonth.grouping(items)) { month in WithPerceptionTracking {
                        Section {
                            if kind.isGrid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 2)], spacing: 2) {
                                    ForEach(month.items) { item in WithPerceptionTracking {
                                        MediaTile(item: item, media: account.media) { shown in open(item, shown) }
                                            .contextMenu { WithPerceptionTracking { menu(for: item) } }
                                    } }
                                }
                                .padding(.horizontal, 2)
                                .padding(.bottom, 2)
                            } else {
                                ForEach(month.items) { item in WithPerceptionTracking {
                                    MediaListRow(item: item, media: account.media, owner: timeline)
                                        .contextMenu { WithPerceptionTracking { menu(for: item) } }
                                    Divider().padding(.leading, 12)
                                } }
                            }
                        } header: {
                            Text(month.title)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.background)
                        }
                    } }
                    footer(count: items.count)
                }
            }
        }
    } }

    /// Going further back while there's more (or a button to, once nothing has turned up for a
    /// while); once there isn't, how many there are.
    @ViewBuilder private func footer(count: Int) -> some View {
        Group {
            if isPaused {
                VStack(spacing: 8) {
                    Text("\(kind.count(count)) in the latest messages")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Look Further Back", action: lookFurther)
                        .controlSize(.small)
                }
            } else if timeline.hasMoreHistory {
                ProgressView()
                    .controlSize(.small)
                    .background { loader(count: count) }
            } else {
                Text(kind.count(count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func loader(count: Int) -> some View {
        HistoryLoader(timeline: timeline, round: search.round) { looksFurther(count: count) }
    }

    private func open(_ item: MediaItem, _ shown: NSImage?) {
        switch item.content {
        case .image(let image): ImageViewerState.shared.open(image, media: account.media, placeholder: shown)
        // It plays in place in the conversation.
        default: show(item)
        }
    }

    private func show(_ item: MediaItem) {
        if let root = item.message.threadRootID {
            openThread(root)
        } else if let eventID = item.message.eventID {
            account.timeline(for: roomID)?.requestedJump = eventID
        }
    }

    @ViewBuilder private func menu(for item: MediaItem) -> some View {
        Button(item.message.threadRootID == nil ? "Show in Conversation" : "Show in Thread") { show(item) }
        Divider()
        let media = account.media
        switch item.content {
        case .image(let image):
            Button("Open") { ImageViewerState.shared.open(image, media: media, placeholder: nil) }
            Button("Save Image As…") { AttachmentSaver.save(image, media: media) }
        case .video(let file, _):
            Button("Save Video As…") { AttachmentSaver.save(file, media: media) }
        case .audio(let audio):
            Button("Save Audio As…") { AttachmentSaver.save(audio, media: media) }
        case .file(let file):
            Button("Save File As…") { AttachmentSaver.save(file, media: media) }
        }
    }
}

/// Asks for older messages while it's on screen, again as each request finishes, until the room's
/// start or `shouldGoOn` says to stop: at the foot of the list, or in place of it while nothing of
/// the kind has turned up yet.
private struct HistoryLoader: View {
    let timeline: RoomTimeline
    /// Changes when the user asks to look further, which starts it again.
    let round: Int
    let shouldGoOn: () -> Bool

    private struct Trigger: Equatable {
        let isReady: Bool
        let requests: Int
        let round: Int
    }

    var body: some View { WithPerceptionTracking {
        Color.clear
            .task(id: Trigger(isReady: !timeline.isLoading, requests: timeline.historyRequests, round: round)) {
                guard !timeline.isLoading, timeline.hasMoreHistory, shouldGoOn() else { return }
                await timeline.loadOlder()
            }
    } }
}

/// A picture or a video's still, square, filling its place in the grid.
private struct MediaTile: View {
    let item: MediaItem
    let media: MediaLoader
    /// Opens it, given what's shown of it so far.
    let open: (NSImage?) -> Void
    @State private var loaded: NSImage?
    /// Too large to load unasked: opening it loads it.
    @State private var isWithheld = false

    /// Big enough to fill a square of the grid from the shorter side of a wide picture.
    private static let side = 360

    private var cached: NSImage? {
        switch item.content {
        case .image(let image): media.cachedDisplayImage(for: image, side: Self.side)
        case .video(let file, _): media.cachedVideoPoster(for: file, side: Self.side)
        default: nil
        }
    }

    var body: some View {
        let shown = loaded ?? cached
        Button { open(shown) } label: {
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let shown {
                        Image(nsImage: shown)
                            .resizable()
                            .scaledToFill()
                    } else if case .video = item.content {
                        Image(systemName: "film")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    } else if isWithheld {
                        Image(systemName: "arrow.down.circle")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if case .video(_, let video) = item.content { VideoBadge(duration: video.duration) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.byline)
        .accessibilityLabel(accessibilityLabel)
        .task(id: item.id) {
            guard loaded == nil else { return }
            switch item.content {
            case .image(let image):
                let result = await media.displayImage(for: image, side: Self.side, isLocal: false)
                loaded = result.image
                if case .withheld = result { isWithheld = true }
            case .video(let file, _): loaded = await media.videoPoster(for: file, side: Self.side)
            default: break
            }
        }
    }

    private var accessibilityLabel: String {
        if case .video = item.content { "Video from \(item.byline)" }
        else if isWithheld { "Image from \(item.byline), too large to load without opening it" }
        else { "Image from \(item.byline)" }
    }
}

/// A video's mark in the grid: that it plays, and for how long.
private struct VideoBadge: View {
    let duration: TimeInterval?

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8, weight: .bold))
            if let duration {
                Text(Duration.seconds(duration.rounded()).formatted(.time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .padding(5)
    }
}

/// A sound or a file in the list: who sent it and when, above it as the conversation shows it,
/// a player for the sound and a tile to open for the file.
private struct MediaListRow: View {
    let item: MediaItem
    let media: MediaLoader
    /// The timeline whose sounds stop playing when the panel closes.
    let owner: RoomTimeline
    @Environment(\.nameColorRoom) private var nameColorRoom

    var body: some View { WithPerceptionTracking {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.message.senderName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(NameColors.shared.color(for: item.message.sender, inRoom: nameColorRoom))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(item.message.date.roomListLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(item.message.date.formatted(date: .long, time: .shortened))
            }
            switch item.content {
            case .audio(let audio):
                AudioMessageView(id: item.message.eventID ?? audio.media.source.url(), audio: audio,
                                 media: media, owner: owner)
                    .environment(\.messageContentWidth, 300)
            case .file(let file), .video(let file, _):
                FileMessageView(file: file, media: media)
            case .image:
                EmptyView()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    } }
}
