import Foundation
import MatrixRustSDK
import Observation

struct RoomSummary: Identifiable, Equatable {
    let id: String
    var name: String
    var avatarURL: String?
    var isDirect = false
    var isInvite = false
    var notifications = 0
    var mentions = 0
    var hasUnread = false
    var lastMessage: String?
    var timestamp: Date?

    var isHighlighted: Bool { isInvite || notifications > 0 || mentions > 0 }
}

/// One logged-in account: its client, sliding sync and room list.
@MainActor @Observable
final class AccountSession: Identifiable {
    nonisolated let id: String
    let userID: String
    let client: Client
    let media: MediaLoader

    private(set) var displayName: String?
    private(set) var avatarURL: String?
    private(set) var rooms: [RoomSummary] = []
    /// False until the server has sent the first page of the room list.
    private(set) var hasLoadedRooms = false
    private(set) var syncState: SyncServiceState = .idle
    private(set) var verification: VerificationState = .unknown
    private(set) var needsReauth = false
    private(set) var startError: String?
    var selectedRoomID: String?
    var searchText = "" {
        didSet { if searchText != oldValue { applyFilter() } }
    }

    /// Rooms with notifications, for the account rail and Dock badge.
    private(set) var badgeCount = 0

    @ObservationIgnored private var syncService: SyncService?
    @ObservationIgnored private var roomListService: RoomListService?
    @ObservationIgnored private var roomList: RoomList?
    @ObservationIgnored private var entries: RoomListEntriesWithDynamicAdaptersResult?
    @ObservationIgnored private var controller: RoomListDynamicEntriesController?
    @ObservationIgnored private var handles: [TaskHandle] = []
    @ObservationIgnored private var roomUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var roomHandles: [String: Room] = [:]
    @ObservationIgnored private var timelines: [String: RoomTimeline] = [:]
    @ObservationIgnored private var timelineOrder: [String] = []

    private static let pageSize: UInt32 = 200
    private static let maxCachedTimelines = 6

    init(id: String, userID: String, client: Client) {
        self.id = id
        self.userID = userID
        self.client = client
        self.media = MediaLoader(client: client)
    }

    // MARK: Lifecycle

    func start() async {
        guard syncService == nil else { return }
        do {
            if let delegateHandle = try client.setDelegate(delegate: AuthErrorDelegate { [weak self] in
                Task { @MainActor in self?.needsReauth = true }
            }) {
                handles.append(delegateHandle)
            }

            let syncService = try await client.syncService().finish()
            self.syncService = syncService
            handles.append(syncService.state(listener: SyncStateListener { [weak self] state in
                Task { @MainActor in self?.syncState = state }
            }))

            let roomListService = syncService.roomListService()
            self.roomListService = roomListService
            let roomList = try await roomListService.allRooms()
            self.roomList = roomList
            observeRooms(in: roomList)
            let loading = try roomList.loadingState(listener: RoomListLoadingListener { [weak self] state in
                Task { @MainActor in self?.hasLoadedRooms = state != .notLoaded }
            })
            hasLoadedRooms = loading.state != .notLoaded
            handles.append(loading.stateStream)

            handles.append(client.encryption().verificationStateListener(listener: VerificationListener { [weak self] state in
                Task { @MainActor in self?.verification = state }
            }))
            verification = client.encryption().verificationState()

            await syncService.start()
            startError = nil
        } catch {
            startError = error.userMessage
        }
        await loadProfile()
    }

    func stop() async {
        roomUpdatesTask?.cancel()
        handles.forEach { $0.cancel() }
        handles.removeAll()
        timelines.values.forEach { $0.stop() }
        timelines.removeAll()
        await syncService?.stop()
        syncService = nil
    }

    private func loadProfile() async {
        let client = client
        async let name = try? client.displayName()
        async let avatar = try? client.avatarUrl()
        displayName = await name
        avatarURL = await avatar ?? nil
    }

    // MARK: Room list

    private func observeRooms(in roomList: RoomList) {
        let (stream, continuation) = AsyncStream.makeStream(of: [RoomListEntriesUpdate].self)
        let entries = roomList.entriesWithDynamicAdapters(pageSize: Self.pageSize,
                                                          listener: RoomEntriesListener { continuation.yield($0) })
        self.entries = entries
        controller = entries.controller()
        handles.append(entries.entriesStream())
        applyFilter()

        // Diffs are processed strictly in order; summaries are built off the main actor.
        roomUpdatesTask = Task.detached { [weak self] in
            for await updates in stream {
                var diffs: [VectorDiff<(Room, RoomSummary)>] = []
                for update in updates {
                    diffs.append(await update.diff.map { room in (room, await RoomSummary.make(from: room)) })
                }
                await self?.apply(diffs)
            }
        }
    }

    private func apply(_ diffs: [VectorDiff<(Room, RoomSummary)>]) {
        var rooms = rooms
        for diff in diffs {
            rooms.apply(diff.mapValues { room, summary in
                roomHandles[summary.id] = room
                return summary
            })
        }
        self.rooms = rooms
        // A search narrows `rooms`, so only count while the list is unfiltered.
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            badgeCount = rooms.reduce(0) { $0 + ($1.isHighlighted ? 1 : 0) }
        }
    }

    private func applyFilter() {
        var filters: [RoomListEntriesDynamicFilterKind] = [.nonLeft, .nonSpace, .deduplicateVersions]
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            filters.append(.normalizedMatchRoomName(pattern: query))
        }
        _ = controller?.setFilter(kind: .all(filters: filters))
    }

    func loadMoreRooms() {
        controller?.addOnePage()
    }

    // MARK: Rooms

    func room(id: String) -> Room? {
        roomHandles[id] ?? (try? client.getRoom(roomId: id))
    }

    /// The live timeline for a room, kept warm for the most recently opened rooms.
    func timeline(for roomID: String) -> RoomTimeline? {
        if let existing = timelines[roomID] {
            touch(roomID)
            return existing
        }
        guard let room = room(id: roomID) else { return nil }
        let timeline = RoomTimeline(room: room)
        timelines[roomID] = timeline
        touch(roomID)
        if let roomListService {
            Task.detached { try? await roomListService.setRoomSubscriptions(roomIds: [roomID]) }
        }
        return timeline
    }

    private func touch(_ roomID: String) {
        timelineOrder.removeAll { $0 == roomID }
        timelineOrder.append(roomID)
        while timelineOrder.count > Self.maxCachedTimelines {
            let evicted = timelineOrder.removeFirst()
            timelines.removeValue(forKey: evicted)?.stop()
        }
    }

    func acceptInvite(roomID: String) async throws {
        try await room(id: roomID)?.join()
    }

    func leave(roomID: String) async throws {
        try await room(id: roomID)?.leave()
        timelines.removeValue(forKey: roomID)?.stop()
        if selectedRoomID == roomID { selectedRoomID = nil }
    }

    // MARK: Encryption

    func recover(with recoveryKey: String) async throws {
        try await client.encryption().recover(recoveryKey: recoveryKey)
    }
}

extension RoomSummary {
    static func make(from room: Room) async -> RoomSummary {
        var summary = RoomSummary(id: room.id(), name: room.displayName() ?? room.id())
        if let info = try? await room.roomInfo() {
            summary.name = info.displayName ?? info.canonicalAlias ?? "Empty room"
            summary.avatarURL = info.avatarUrl
            summary.isDirect = info.isDirect
            summary.isInvite = info.membership == .invited
            summary.notifications = Int(info.numUnreadNotifications)
            summary.mentions = Int(info.numUnreadMentions)
            summary.hasUnread = info.numUnreadMessages > 0 || info.isMarkedUnread
            if summary.avatarURL == nil, info.isDirect, info.heroes.count == 1 {
                summary.avatarURL = info.heroes[0].avatarUrl
            }
        }
        switch await room.latestEvent() {
        case .none:
            break
        case .remote(let timestamp, let sender, let isOwn, let profile, let content):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            let prefix = isOwn ? "You" : (summary.isDirect ? nil : profile.name(fallback: sender))
            summary.lastMessage = content.preview(sender: prefix)
        case .local(let timestamp, _, _, let content, _):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            summary.lastMessage = content.preview(sender: "You")
        case .remoteInvite(let timestamp, let inviter, let profile):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            summary.lastMessage = inviter.map { "Invited by \(profile.name(fallback: $0))" } ?? "Invitation"
        }
        return summary
    }
}

extension Date {
    init(matrixTimestamp: Timestamp) {
        self.init(timeIntervalSince1970: TimeInterval(matrixTimestamp) / 1000)
    }
}

extension ProfileDetails {
    var displayName: String? {
        if case .ready(let displayName, _, _, _, _) = self { return displayName }
        return nil
    }

    var avatarURL: String? {
        if case .ready(_, _, let avatarUrl, _, _) = self { return avatarUrl }
        return nil
    }

    func name(fallback userID: String) -> String {
        displayName ?? userID
    }
}
