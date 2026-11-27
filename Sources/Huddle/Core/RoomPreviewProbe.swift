import Foundation
import MatrixRustSDK

/// What the user's read receipts in a room say of its threads.
struct ThreadActivity: Equatable {
    /// Threads with a reply from someone else after where the user has read them to, by root
    /// event ID: the date of the newest such reply.
    var unread: [String: Date] = [:]
    /// Nothing from anyone else in the main conversation after where the user has read it to.
    /// Nil when the messages at hand can't tell: where it was read to is further back.
    var mainIsRead: Bool?
}

/// Watches a room's newest events without opening it, for three things the SDK's room list
/// doesn't say: a reaction that came after its newest message, whether that message is a reply
/// in a thread, and which threads have replies the user hasn't read.
///
/// The SDK's own unread counts take a room as one line of messages, so reading the newest
/// message in the main conversation counts every earlier thread reply as read. Here each thread
/// is measured against the user's receipt in that thread (or one for the whole room, or their
/// own reply in it), as the server measures it, and the main conversation against its own.
///
/// It reads what the SDK has cached for the room and listens for more. It never asks the server
/// for history: what keeps the cache fresh is the room being subscribed (`AccountSession` keeps
/// the rooms on screen, and the open ones, subscribed), which brings its newest events in with
/// each sync.
@MainActor
final class RoomPreviewProbe {
    private let room: Room
    private let ownUserID: String
    private let report: (ReactionPreview?) -> Void
    private let reportThreadReply: (Date?) -> Void
    private let reportThreads: (ThreadActivity) -> Void
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
    /// Whether reactions are worked out and reported: not while the room's own timeline is
    /// open, which reports them itself.
    var reportsReactions = true {
        didSet {
            guard reportsReactions, !oldValue else { return }
            reported = false
            update()
        }
    }

    // Threads
    private var threadsTask: Task<Void, Never>?
    private var threadsAgain = false
    private var lastThreads: ThreadActivity?
    /// The facts taken from each item, kept for as long as the SDK keeps the same item (it
    /// changes one by replacing it): reading them crosses into the SDK and back. The item is
    /// held too, so no other can take its place in memory, and its identity, meanwhile.
    private var facts: [ObjectIdentifier: (item: TimelineItem, facts: EventFacts)] = [:]
    /// Read here, before the receipt sent for it has come back with a sync: the event it was
    /// read up to, by thread root ("" for the whole room).
    private var readHere: [String: String] = [:]
    /// As last worked out: the events at hand, where each is among them by ID, and where the
    /// user has read up to in each thread (by root; "" for the main conversation).
    private var lastEvents: [EventFacts] = []
    private var lastPositions: [String: Int] = [:]
    private var lastPoints: [String: [ReadPoint]] = [:]

    private struct EventFacts {
        let id: String?
        /// The root of the thread it's a reply in; nil in the main conversation.
        let root: String?
        let isOwn: Bool
        /// Something that makes a room unread: a message, not a reaction, an edit or a change
        /// to the room.
        let isMessage: Bool
        let date: Date
    }

    /// Where the user has read up to: an event among those at hand (everything up to it), or,
    /// for one further back, the time of the receipt.
    private enum ReadPoint {
        case at(Int)
        case dated(Date)

        func covers(_ index: Int, _ event: EventFacts) -> Bool {
            switch self {
            case .at(let point): index <= point
            case .dated(let date): event.date <= date
            }
        }

        var isAmongEvents: Bool { if case .at = self { true } else { false } }
    }

    /// The newest events looked at for threads. Older thread replies are taken as read.
    private static let eventsLookedAt = 1000

    /// The user's names for people changed: the preview said again.
    func namesChanged() {
        reported = false
        update()
    }

    init(room: Room, report: @escaping (ReactionPreview?) -> Void,
         reportThreadReply: @escaping (Date?) -> Void,
         reportThreads: @escaping (ThreadActivity) -> Void) {
        self.room = room
        self.report = report
        self.reportThreadReply = reportThreadReply
        self.reportThreads = reportThreads
        ownUserID = room.ownUserId()
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        threadsTask?.cancel()
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
        reportNewestThreadReply()
        recheckThreads()
        guard reportsReactions else { return }
        var rows: [TimelineRow] = []
        var names: [String: String] = [:]
        for item in items {
            guard let event = item.asEvent(),
                  case .message(let message)? = TimelineRow.Kind(event: event, ownUserID: ownUserID, contactName: contactName) else { continue }
            names[message.sender] = message.senderName
            rows.append(TimelineRow(id: item.uniqueId().id, kind: .message(message)))
        }
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

    // MARK: Threads

    /// Read here, in a thread (or, with nil, the whole room): taken as read up to its newest
    /// event now, without waiting for the receipt to come back.
    func markRead(thread root: String?) {
        for item in items.reversed() {
            guard let event = item.asEvent(), case .eventId(let id) = event.eventOrTransactionId else { continue }
            if let root {
                guard case .msgLike(let message) = event.content, message.threadRoot == root else { continue }
            }
            readHere[root ?? ""] = id
            break
        }
        recheckThreads()
    }

    /// Works out again which threads are unread: after new events, or a receipt sent or come
    /// in. Several asked for at once are worked out once.
    func recheckThreads() {
        guard threadsTask == nil else {
            threadsAgain = true
            return
        }
        threadsTask = Task { [weak self] in
            // A moment for more of the same burst to arrive.
            try? await Task.sleep(for: .milliseconds(250))
            while let self, !Task.isCancelled {
                self.threadsAgain = false
                let activity = await self.threadActivity()
                guard !Task.isCancelled else { return }
                if activity != self.lastThreads {
                    self.lastThreads = activity
                    self.reportThreads(activity)
                }
                guard self.threadsAgain else {
                    self.threadsTask = nil
                    return
                }
            }
        }
    }

    private func threadActivity() async -> ThreadActivity {
        var known: [ObjectIdentifier: (item: TimelineItem, facts: EventFacts)] = [:]
        var events: [EventFacts] = []
        for item in items.suffix(Self.eventsLookedAt) {
            let key = ObjectIdentifier(item)
            if let facts = facts[key]?.facts ?? Self.facts(of: item) {
                known[key] = (item, facts)
                events.append(facts)
            }
        }
        facts = known

        var position: [String: Int] = [:]
        for (index, event) in events.enumerated() { if let id = event.id { position[id] = index } }
        func point(_ receipt: UserReceipt?) -> ReadPoint? {
            guard let receipt else { return nil }
            if let index = position[receipt.eventId] { return .at(index) }
            return receipt.receipt.timestamp.map { .dated(Date(matrixTimestamp: $0)) }
        }
        func pointReadHere(_ key: String) -> ReadPoint? { readHere[key].flatMap { position[$0] }.map { .at($0) } }
        func receipt(_ thread: ReceiptThread) async -> UserReceipt? {
            try? await room.loadUserReceipt(receiptType: .read, thread: thread, userId: ownUserID)
        }

        // A receipt for the whole room covers every thread too; the user's own message covers
        // what came before it, where it was sent.
        let roomPoints = [point(await receipt(.unthreaded)), pointReadHere("")].compactMap { $0 }
        var newestOthers: [String: Int] = [:]
        var newestOwn: [String: Int] = [:]
        for (index, event) in events.enumerated() where event.isMessage {
            let key = event.root ?? ""
            if event.isOwn { newestOwn[key] = index } else { newestOthers[key] = index }
        }

        var activity = ThreadActivity()
        var points: [String: [ReadPoint]] = [:]
        for (root, index) in newestOthers where !root.isEmpty {
            var threadPoints = roomPoints
            if let own = newestOwn[root] { threadPoints.append(.at(own)) }
            if let here = pointReadHere(root) { threadPoints.append(here) }
            if !threadPoints.contains(where: { $0.covers(index, events[index]) }) {
                // Only now ask for the thread's own receipt: most threads are settled without.
                if let threadPoint = point(await receipt(.thread(threadRootEventId: root))) {
                    threadPoints.append(threadPoint)
                }
                if !threadPoints.contains(where: { $0.covers(index, events[index]) }) {
                    activity.unread[root] = events[index].date
                }
            }
            points[root] = threadPoints
        }

        var mainPoints = roomPoints
        if let main = point(await receipt(.main)) { mainPoints.append(main) }
        if let own = newestOwn[""] { mainPoints.append(.at(own)) }
        points[""] = mainPoints
        if mainPoints.contains(where: \.isAmongEvents) {
            activity.mainIsRead = newestOthers[""].map { index in
                mainPoints.contains { $0.covers(index, events[index]) }
            } ?? true
        }
        lastEvents = events
        lastPositions = position
        lastPoints = points
        return activity
    }

    /// Whether an event, in the thread with this root ("" for the main conversation), has been
    /// read, as last worked out. Nil when it isn't among the events at hand, or was never
    /// looked at.
    func isRead(eventID: String, thread root: String) -> Bool? {
        guard let index = lastPositions[eventID], let points = lastPoints[root] else { return nil }
        return points.contains { $0.covers(index, lastEvents[index]) }
    }

    private static func facts(of item: TimelineItem) -> EventFacts? {
        guard let event = item.asEvent() else { return nil }
        var id: String?
        if case .eventId(let eventID) = event.eventOrTransactionId { id = eventID }
        var root: String?
        var isMessage = false
        switch event.content {
        case .msgLike(let content):
            root = content.threadRoot
            switch content.kind {
            case .redacted, .other: break
            default: isMessage = true
            }
        case .callInvite, .rtcNotification:
            isMessage = true
        default:
            break
        }
        return EventFacts(id: id, root: root, isOwn: event.isOwn, isMessage: isMessage,
                          date: Date(matrixTimestamp: event.timestamp))
    }
}
