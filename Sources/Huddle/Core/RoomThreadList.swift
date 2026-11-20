import Foundation
import MatrixRustSDK
import Perception

struct ThreadListEntry: Identifiable, Equatable {
    let id: String
    var senderID: String
    var senderName: String
    var senderAvatarURL: String?
    var preview: String
    var replyCount: Int
    var latestReplierName: String?
    /// When the latest reply was sent; the root's date until that is known.
    var latestDate: Date
    /// Whether `latestDate` is the latest reply's own date yet.
    var latestDateIsKnown: Bool
    /// The latest reply is someone else's, not yours.
    var latestIsOthers: Bool
}

/// All threads in one room, newest activity first.
///
/// Two things the SDK's list gets wrong are put right here. A thread's latest reply, as the
/// server gives it, carries the root's date rather than its own, so its own is looked up. And
/// any reply the SDK comes across later is taken for the latest and counted as one more, even
/// an older one loaded as the room scrolls back; only a reply later than the latest is taken
/// here, and counted once.
@MainActor @Perceptible
final class RoomThreadList {
    private(set) var entries: [ThreadListEntry] = []
    private(set) var isLoading = true
    private(set) var hasMore = true
    private(set) var error: String?

    @PerceptionIgnored private let room: Room
    @PerceptionIgnored private let service: ThreadListService
    @PerceptionIgnored private var items: [ThreadListItem] = []
    @PerceptionIgnored private var handle: TaskHandle?
    @PerceptionIgnored private var updatesTask: Task<Void, Never>?
    /// Told whenever the entries change.
    @PerceptionIgnored var onChange: (() -> Void)?
    /// Looks up the latest replies' dates down the list only as far as the first one older than
    /// this: the server lists threads by their latest activity, so the rest are older still.
    /// Nil looks them all up.
    @PerceptionIgnored private let datesBack: Date?
    /// Each thread's replies the SDK has given as its latest, by root event ID.
    @PerceptionIgnored private var threads: [String: Replies] = [:]
    /// Replies' own dates, by event ID, as looked up.
    @PerceptionIgnored private var replyDates: [String: Date] = [:]
    /// Replies whose date couldn't be had (deleted, or the request failed): not asked again.
    @PerceptionIgnored private var undated: Set<String> = []
    @PerceptionIgnored private var lookups: Task<Void, Never>?
    /// Set once a reply older than `datesBack` has been found.
    @PerceptionIgnored private var lookedFarEnough = false

    private struct Reply {
        let eventID: String
        let name: String
        let isOthers: Bool
    }

    private struct Replies {
        /// The latest reply when the thread was first listed, and its count of replies then.
        let first: String
        let count: Int
        var byID: [String: Reply]
    }

    /// The user's own name for someone (ContactNames.swift), set by whoever made the list.
    var contactName: (String) -> String? = { _ in nil }

    init(room: Room, datesBack: Date? = nil) {
        self.room = room
        self.datesBack = datesBack
        service = room.threadListService()
        let (stream, continuation) = AsyncStream.makeStream(of: [ThreadListUpdate].self)
        handle = service.subscribeToItemsUpdates(listener: ThreadEntriesListener { continuation.yield($0) })
        items = service.items()
        rebuild()
        updatesTask = Task { [weak self] in
            for await updates in stream {
                guard let self else { return }
                for update in updates { self.items.apply(update.diff) }
                self.rebuild()
            }
        }
        Task { await loadMore() }
    }

    func stop() {
        updatesTask?.cancel()
        handle?.cancel()
        lookups?.cancel()
    }

    func loadMore() async {
        guard hasMore else { return }
        do {
            try await service.paginate()
            if case .idle(let endReached) = service.paginationState() {
                hasMore = !endReached
            }
        } catch {
            self.error = error.actionMessage
            hasMore = false
        }
        isLoading = false
    }

    private func rebuild() {
        var missing: [String] = []
        entries = items.map { item in
            let root = item.rootEvent
            let rootDate = Date(matrixTimestamp: root.timestamp)
            var replies: Replies?
            if let event = item.latestEvent {
                let reply = Reply(eventID: event.eventId, name: contactName(event.sender) ?? event.senderProfile.name(fallback: event.sender),
                                  isOthers: !event.isOwn)
                // A reply dated after its root carries its own date: one the SDK came across
                // itself. Dated as the root, it came from the server's list and needs looking up.
                if event.timestamp > root.timestamp, replyDates[event.eventId] == nil {
                    replyDates[event.eventId] = Date(matrixTimestamp: event.timestamp)
                }
                var known = threads[root.eventId]
                    ?? Replies(first: event.eventId, count: Int(item.numReplies), byID: [:])
                known.byID[event.eventId] = reply
                threads[root.eventId] = known
                replies = known
                if replyDates[event.eventId] == nil, !undated.contains(event.eventId) {
                    missing.append(event.eventId)
                }
            }
            let candidates = replies.map { Array($0.byID.values) } ?? []
            let dated = candidates.compactMap { reply in replyDates[reply.eventID].map { (reply, $0) } }
            let latest = dated.max { $0.1 < $1.1 }
            // Counted from the replies when first listed, plus each later one since.
            var count = replies?.count ?? Int(item.numReplies)
            if let replies, let first = replyDates[replies.first] {
                count += dated.filter { $0.1 > first }.count
            }
            return ThreadListEntry(
                id: root.eventId,
                senderID: root.sender,
                senderName: contactName(root.sender) ?? root.senderProfile.name(fallback: root.sender),
                senderAvatarURL: root.senderProfile.avatarURL,
                preview: root.content?.preview(sender: nil) ?? "Message",
                replyCount: count,
                latestReplierName: latest?.0.name ?? item.latestEvent.map { contactName($0.sender) ?? $0.senderProfile.name(fallback: $0.sender) },
                latestDate: latest?.1 ?? rootDate,
                latestDateIsKnown: latest != nil,
                latestIsOthers: latest?.0.isOthers ?? false)
        }
        onChange?()
        lookUpDates(missing)
    }

    /// Looks up the replies' own dates, one at a time down the list, then lists them again.
    private func lookUpDates(_ eventIDs: [String]) {
        guard lookups == nil, !lookedFarEnough, !eventIDs.isEmpty else { return }
        lookups = Task { [weak self, room] in
            for eventID in eventIDs {
                guard let self, !Task.isCancelled else { return }
                guard let event = try? await room.loadOrFetchEvent(eventId: eventID) else {
                    // Not to be had: the root's date stands for it.
                    self.undated.insert(eventID)
                    continue
                }
                let date = Date(matrixTimestamp: event.timestamp())
                self.replyDates[eventID] = date
                if let datesBack = self.datesBack, date < datesBack {
                    self.lookedFarEnough = true
                    break
                }
            }
            self?.lookups = nil
            self?.rebuild()
        }
    }
}
