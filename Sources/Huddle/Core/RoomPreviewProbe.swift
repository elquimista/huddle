import Foundation
import MatrixRustSDK

/// Watches a room's newest events without opening it, to notice a reaction that came after its
/// newest message, and whether that message is a reply in a thread. The SDK's own "latest
/// event", which the room list shows, leaves reactions out and doesn't say it's in a thread.
///
/// It reads what the SDK has cached for the room and listens for more. It never asks the server
/// for history: what keeps the cache fresh is the room being subscribed (`AccountSession` keeps
/// the rooms on screen subscribed), which brings its newest events in with each sync.
@MainActor
final class RoomPreviewProbe {
    private let room: Room
    private let ownUserID: String
    private let report: (ReactionPreview?) -> Void
    private let reportThreadReply: (Date?) -> Void
    private var timeline: Timeline?
    private var listener: TaskHandle?
    private var task: Task<Void, Never>?
    private var items: [TimelineItem] = []
    private var latest: ReactionPreview?
    private var reported = false
    private var threadReply: Date?
    private var reportedThreadReply = false
    /// The user's own name for someone (ContactNames.swift), set by the account.
    var contactName: (String) -> String? = { _ in nil }

    /// The user's names for people changed: the preview said again.
    func namesChanged() {
        reported = false
        update()
    }

    init(room: Room, report: @escaping (ReactionPreview?) -> Void,
         reportThreadReply: @escaping (Date?) -> Void) {
        self.room = room
        self.report = report
        self.reportThreadReply = reportThreadReply
        ownUserID = room.ownUserId()
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        listener?.cancel()
        listener = nil
        timeline = nil
    }

    private func run() async {
        guard let timeline = try? await room.timelineWithConfiguration(configuration: TimelineConfiguration(
            // With replies in threads, as the SDK's latest event has them.
            focus: .live(hideThreadedEvents: false),
            filter: .all,
            internalIdPrefix: nil,
            dateDividerMode: .daily,
            trackReadReceipts: .disabled,
            reportUtds: false)) else { return }
        guard !Task.isCancelled else { return }
        self.timeline = timeline
        let (stream, continuation) = AsyncStream.makeStream(of: [TimelineDiff].self)
        listener = await timeline.addListener(listener: TimelineDiffListener { continuation.yield($0) })
        for await diffs in stream {
            guard !Task.isCancelled else { break }
            for diff in diffs { items.apply(diff.diff) }
            update()
        }
    }

    private func update() {
        var rows: [TimelineRow] = []
        var names: [String: String] = [:]
        for item in items {
            guard let event = item.asEvent(),
                  case .message(let message)? = TimelineRow.Kind(event: event, ownUserID: ownUserID, contactName: contactName) else { continue }
            names[message.sender] = message.senderName
            rows.append(TimelineRow(id: item.uniqueId().id, kind: .message(message)))
        }
        reportNewestThreadReply()
        let newest = ReactionPreview.newest(in: rows, ownUserID: ownUserID, name: { names[$0] })
        // Nothing to say until there is something: an empty cache mustn't wipe a preview
        // another source (an open room) has already given.
        guard !rows.isEmpty, newest != latest || !reported else { return }
        latest = newest
        reported = true
        report(newest)
    }

    /// The date of the newest event, when it's a reply in a thread.
    private func reportNewestThreadReply() {
        guard let newest = items.last(where: { $0.asEvent() != nil })?.asEvent() else { return }
        var date: Date?
        if case .msgLike(let message) = newest.content, message.threadRoot != nil {
            date = Date(matrixTimestamp: newest.timestamp)
        }
        guard date != threadReply || !reportedThreadReply else { return }
        threadReply = date
        reportedThreadReply = true
        reportThreadReply(date)
    }
}
