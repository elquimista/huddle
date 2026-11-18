import Foundation
import MatrixRustSDK
import Observation

struct ThreadListEntry: Identifiable, Equatable {
    let id: String
    var senderID: String
    var senderName: String
    var senderAvatarURL: String?
    var preview: String
    var replyCount: Int
    var latestReplierName: String?
    var latestDate: Date
}

/// All threads in one room, newest activity first.
@MainActor @Observable
final class RoomThreadList {
    private(set) var entries: [ThreadListEntry] = []
    private(set) var isLoading = true
    private(set) var hasMore = true
    private(set) var error: String?

    @ObservationIgnored private let service: ThreadListService
    @ObservationIgnored private var items: [ThreadListItem] = []
    @ObservationIgnored private var handle: TaskHandle?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    init(room: Room) {
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
        entries = items.map { item in
            let root = item.rootEvent
            let latest = item.latestEvent
            return ThreadListEntry(
                id: root.eventId,
                senderID: root.sender,
                senderName: root.senderProfile.name(fallback: root.sender),
                senderAvatarURL: root.senderProfile.avatarURL,
                preview: root.content?.preview(sender: nil) ?? "Message",
                replyCount: Int(item.numReplies),
                latestReplierName: latest.map { $0.senderProfile.name(fallback: $0.sender) },
                latestDate: Date(matrixTimestamp: latest?.timestamp ?? root.timestamp))
        }
    }
}
