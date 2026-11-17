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
    /// False when the room's details could not be read, so the counts above mean nothing.
    var hasCounts = false
    var lastMessage: String?
    var timestamp: Date?

    var isHighlighted: Bool { isInvite || notifications > 0 || mentions > 0 }
    /// Addressed to you personally: an invitation, a mention, or a direct message.
    var isUrgent: Bool { isInvite || mentions > 0 || (isDirect && notifications > 0) }
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
    /// For rooms opened this session: a reaction that came after the room's newest message.
    private(set) var reactionPreviews: [String: ReactionPreview] = [:]
    /// What the panel beside each room's timeline shows, so it is still there on coming back.
    var sidePanels: [String: ThreadPanel.Content] = [:]
    var searchText = "" {
        didSet { if searchText != oldValue { applyFilter() } }
    }

    /// Rooms with notifications, for the account rail and Dock badge.
    private(set) var badgeCount = 0
    /// Rooms that need attention now: mentions, direct messages and pending invitations.
    private(set) var urgentCount = 0

    @ObservationIgnored private var syncService: SyncService?
    @ObservationIgnored private var roomListService: RoomListService?
    @ObservationIgnored private var roomList: RoomList?
    @ObservationIgnored private var entries: RoomListEntriesWithDynamicAdaptersResult?
    @ObservationIgnored private var controller: RoomListDynamicEntriesController?
    @ObservationIgnored private var handles: [TaskHandle] = []
    @ObservationIgnored private var roomUpdatesTask: Task<Void, Never>?
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var restartAttempts = 0
    @ObservationIgnored private var pendingClears: Set<String> = []
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

            // Offline mode: when the network drops (or the Mac sleeps) the service waits for the
            // server to be reachable and resumes by itself instead of ending in an error.
            let syncService = try await client.syncService().withOfflineMode().finish()
            self.syncService = syncService
            handles.append(syncService.state(listener: SyncStateListener { [weak self] state in
                Task { @MainActor in self?.syncStateChanged(to: state) }
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

            Notifier.shared.activate()
            // Lets an image being sent show how far its upload has got.
            client.enableSendQueueUploadProgress(enable: true)
            await client.registerNotificationHandler(listener: NotificationListener { [weak self] item, roomID in
                Task { @MainActor in
                    guard let self, self.syncService != nil else { return }
                    Notifier.shared.handle(item, roomID: roomID, account: self)
                }
            })

            await syncService.start()
            startError = nil
        } catch {
            startError = error.userMessage
        }
        await loadProfile()
    }

    /// The SDK never restarts a sync that ended in an error (a server error, a timeout, a
    /// rejected request), so do it here, backing off while it keeps failing.
    private func syncStateChanged(to state: SyncServiceState) {
        syncState = state
        switch state {
        case .running:
            restartAttempts = 0
            restartTask?.cancel()
            restartTask = nil
            // A send that failed for want of a connection switches its room's queue off.
            // Now that there is one again, switch them back on so what is waiting goes out.
            let client = client
            Task.detached { await client.enableAllSendQueues(enable: true) }
        case .error, .terminated:
            guard restartTask == nil, syncService != nil, !needsReauth else { return }
            let delay = min(60.0, 2.0 * pow(2.0, Double(restartAttempts)))
            restartAttempts += 1
            restartTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                self.restartTask = nil
                guard let syncService = self.syncService, !self.needsReauth else { return }
                await syncService.start()
            }
        case .idle, .offline:
            break
        }
    }

    func stop() async {
        restartTask?.cancel()
        restartTask = nil
        roomUpdatesTask?.cancel()
        handles.forEach { $0.cancel() }
        handles.removeAll()
        timelines.values.forEach { $0.stop() }
        timelines.removeAll()
        let syncService = syncService
        self.syncService = nil
        await syncService?.stop()
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
        let previous = self.rooms
        self.rooms = rooms
        // A room that stops needing attention (read here or elsewhere) drops its notifications.
        // Only on a definite answer: the room is still listed and its counts were read. A room
        // missing from the list (a search, a list rebuild) says nothing about being read.
        let current = Dictionary(rooms.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for room in previous where room.isHighlighted {
            if let now = current[room.id], now.hasCounts, !now.isHighlighted {
                clearNotificationsIfStillRead(roomID: room.id)
            }
        }
        // A search narrows `rooms`, so only count while the list is unfiltered.
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            badgeCount = rooms.reduce(0) { $0 + ($1.isHighlighted ? 1 : 0) }
            urgentCount = rooms.reduce(0) { $0 + ($1.isUrgent ? 1 : 0) }
        }
    }

    /// Unread counts can dip to zero for a moment while the SDK rebuilds a room's history after
    /// a gap in sync, so wait and look again before treating the room as read.
    private func clearNotificationsIfStillRead(roomID: String) {
        guard !pendingClears.contains(roomID) else { return }
        pendingClears.insert(roomID)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self else { return }
            self.pendingClears.remove(roomID)
            guard let room = self.roomHandles[roomID], self.syncService != nil else { return }
            let summary = await RoomSummary.make(from: room)
            if summary.hasCounts, !summary.isHighlighted {
                Notifier.shared.clear(accountID: self.id, roomID: roomID)
            }
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
        timeline.onLatestReaction = { [weak self] preview in self?.reactionPreviews[roomID] = preview }
        timelines[roomID] = timeline
        touch(roomID)
        if let roomListService {
            Task.detached { try? await roomListService.setRoomSubscriptions(roomIds: [roomID]) }
        }
        return timeline
    }

    /// A fresh timeline for one thread. The caller owns it and stops it when done.
    func threadTimeline(roomID: String, root: String) -> RoomTimeline? {
        guard let room = room(id: roomID) else { return nil }
        let thread = RoomTimeline(room: room, threadRoot: root)
        thread.onRead = { [weak self] in self?.timelines[roomID]?.markThreadSeen(root) }
        return thread
    }

    func threadList(roomID: String) -> RoomThreadList? {
        room(id: roomID).map { RoomThreadList(room: $0) }
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
            summary.hasCounts = true
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
