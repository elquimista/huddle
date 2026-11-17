import Foundation
import MatrixRustSDK
import Observation

struct RoomSummary: Identifiable, Equatable {
    let id: String
    var name: String
    var avatarURL: String?
    var isDirect = false
    /// In a direct chat with one other person: who that is.
    var directUserID: String?
    var isInvite = false
    var notifications = 0
    var mentions = 0
    var hasUnread = false
    /// Marked unread by the user (here or in another client), as a reminder to come back.
    var isMarkedUnread = false
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
    var selectedRoomID: String? {
        didSet {
            guard selectedRoomID != oldValue else { return }
            PerfLog.began("room selected")
            updatePresenceWatch()
        }
    }
    /// Who is around, for the direct chats on screen.
    let presence: PresenceTracker
    @ObservationIgnored private let ownPresence: OwnPresence
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
    @ObservationIgnored private var probes: [String: RoomPreviewProbe] = [:]
    @ObservationIgnored private var visibleRooms: Set<String> = []
    @ObservationIgnored private var subscribedRooms: Set<String> = []
    @ObservationIgnored private var subscriptionTask: Task<Void, Never>?
    @ObservationIgnored private var timelineOrder: [String] = []

    private static let pageSize: UInt32 = 200
    private static let maxCachedTimelines = 6
    /// Rooms on screen kept subscribed at once: a full window's worth, with room to spare.
    private static let maxSubscribedRooms = 30

    init(id: String, userID: String, client: Client) {
        self.id = id
        self.userID = userID
        self.client = client
        self.media = MediaLoader(client: client)
        self.presence = PresenceTracker(client: client)
        self.ownPresence = OwnPresence(client: client)
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
            ownPresence.start()
            presence.start()
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
        bannerPinTimelines.values.forEach { $0.stop() }
        bannerPinTimelines.removeAll()
        subscriptionTask?.cancel()
        presence.stop()
        ownPresence.stop()
        probes.values.forEach { $0.stop() }
        probes.removeAll()
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
        // Marked unread from another device: a room open here stays unread too, rather than
        // being read again by the next message that arrives.
        let wasMarked = Set(previous.filter(\.isMarkedUnread).map(\.id))
        for room in rooms where room.isMarkedUnread && !wasMarked.contains(room.id) {
            timelines[room.id]?.holdsUnread = true
        }
        // A direct chat's other person may only now be known.
        if rooms.contains(where: { $0.directUserID != nil && visibleRooms.contains($0.id) }) { updatePresenceWatch() }
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
        // The open room reports its own reactions now; its probe has nothing to add.
        probes.removeValue(forKey: roomID)?.stop()
        touch(roomID)
        updateSubscriptions(now: true)
        return timeline
    }

    /// A fresh timeline for one thread. The caller owns it and stops it when done.
    func threadTimeline(roomID: String, root: String) -> RoomTimeline? {
        guard let room = room(id: roomID) else { return nil }
        let thread = RoomTimeline(room: room, threadRoot: root)
        thread.onRead = { [weak self] in self?.timelines[roomID]?.markThreadSeen(root) }
        return thread
    }

    // MARK: Read and unread

    /// Whether a room has anything unread, as the room list shows it.
    func isUnread(_ roomID: String) -> Bool {
        guard let room = rooms.first(where: { $0.id == roomID }) else { return false }
        return room.hasUnread || room.notifications > 0 || room.mentions > 0
    }

    /// Marks a room read up to its newest message, or unread, as the user asks. Shown in the
    /// list at once; the server's own record follows as it syncs.
    func setRoom(_ roomID: String, unread: Bool) {
        guard let room = room(id: roomID) else { return }
        if let index = rooms.firstIndex(where: { $0.id == roomID }) {
            rooms[index].hasUnread = unread
            rooms[index].isMarkedUnread = unread
            if !unread {
                rooms[index].notifications = 0
                rooms[index].mentions = 0
            }
        }
        // The room on screen stays unread until it is opened again, rather than being read
        // again the moment a message arrives or the room is left.
        timelines[roomID]?.holdsUnread = unread
        Task {
            if unread {
                try? await room.setUnreadFlag(newValue: true)
            } else {
                try? await room.markAsRead(receiptType: .read)
                // Moves the "New" line too, so the room isn't half read on opening.
                try? await room.markAsRead(receiptType: .fullyRead)
                try? await room.setUnreadFlag(newValue: false)
            }
        }
    }

    /// Whether any room in the list has anything unread.
    var hasUnreadRooms: Bool {
        rooms.contains { !$0.isInvite && ($0.hasUnread || $0.notifications > 0 || $0.mentions > 0) }
    }

    /// Marks every room in the list read.
    func markAllRead() {
        for room in rooms where !room.isInvite && (room.hasUnread || room.notifications > 0 || room.mentions > 0) {
            setRoom(room.id, unread: false)
        }
    }

    /// A fresh timeline around one message, for showing it without loading the whole room's
    /// history up to it. The caller owns it and stops it when done.
    func focusedTimeline(roomID: String, eventID: String) -> RoomTimeline? {
        room(id: roomID).map { RoomTimeline(room: $0, focusedOn: eventID) }
    }

    /// A fresh timeline of a room's pinned messages. The caller owns it and stops it when done.
    func pinnedTimeline(roomID: String) -> RoomTimeline? {
        room(id: roomID).map { RoomTimeline(room: $0, isPinnedList: true) }
    }

    /// The pinned messages for a room's banner, kept as long as the room's own timeline is
    /// kept warm: coming back to the room, the banner is there from the first frame instead of
    /// arriving a moment later and pushing the conversation down.
    func bannerPins(for roomID: String) -> RoomTimeline? {
        if let pins = bannerPinTimelines[roomID] { return pins }
        guard let pins = pinnedTimeline(roomID: roomID) else { return nil }
        bannerPinTimelines[roomID] = pins
        return pins
    }

    /// The room has no pinned messages any more.
    func dropBannerPins(for roomID: String) {
        bannerPinTimelines.removeValue(forKey: roomID)?.stop()
    }

    @ObservationIgnored private var bannerPinTimelines: [String: RoomTimeline] = [:]

    /// Sends a message's content, as it is, to another room.
    func forward(_ content: RoomMessageEventContentWithoutRelation, to roomID: String) async throws {
        guard let room = room(id: roomID) else { throw ForwardError.roomUnavailable }
        // The room's send queue takes it from here, as for anything typed in the room itself.
        room.enableSendQueue(enable: true)
        let timeline = try await room.timeline()
        _ = try await timeline.send(msg: content)
    }

    enum ForwardError: LocalizedError {
        case roomUnavailable
        var errorDescription: String? { "That room isn't available." }
    }

    func threadList(roomID: String) -> RoomThreadList? {
        room(id: roomID).map { RoomThreadList(room: $0) }
    }

    // MARK: Rooms on screen

    /// A room row scrolled into view in the list.
    func roomBecameVisible(_ roomID: String) {
        guard visibleRooms.insert(roomID).inserted else { return }
        updateSubscriptions()
    }

    func roomBecameHidden(_ roomID: String) {
        guard visibleRooms.remove(roomID) != nil else { return }
        updateSubscriptions()
    }

    /// Keeps the rooms on screen, and the rooms whose timelines are open, subscribed. A
    /// subscribed room's newest events (about 20) come in with every sync, so its preview is up
    /// to date and opening it shows the latest messages at once. Rooms further down the list
    /// aren't subscribed: they get the one newest event the room list asks for.
    ///
    /// Changes are gathered for a moment, since each one interrupts the sync in progress.
    private func updateSubscriptions(now: Bool = false) {
        subscriptionTask?.cancel()
        subscriptionTask = Task { [weak self] in
            if !now { try? await Task.sleep(for: .milliseconds(350)) }
            guard let self, !Task.isCancelled, let roomListService = self.roomListService else { return }
            // Most recent first, up to the limit; open rooms always.
            let order = Dictionary(uniqueKeysWithValues: self.rooms.enumerated().map { ($1.id, $0) })
            let onScreen = self.visibleRooms.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
                .prefix(Self.maxSubscribedRooms)
            let wanted = Array(Set(onScreen).union(self.timelineOrder))
            self.updateProbes(for: Set(onScreen))
            self.updatePresenceWatch()
            guard Set(wanted) != self.subscribedRooms else { return }
            self.subscribedRooms = Set(wanted)
            if AppEnvironment.isDev {
                print("DEV_SUBSCRIPTIONS \(self.userID) rooms=\(wanted.count) probes=\(self.probes.count)")
                fflush(stdout)
            }
            Task.detached { try? await roomListService.setRoomSubscriptions(roomIds: wanted) }
        }
    }

    /// Presence for the other person in each direct chat on screen, and in the open one.
    private func updatePresenceWatch() {
        let partners = rooms.lazy.filter { self.visibleRooms.contains($0.id) }.compactMap(\.directUserID)
        let open = selectedRoomID.flatMap { id in rooms.first { $0.id == id }?.directUserID }
        presence.watch(Set(partners), focus: open)
    }

    /// A probe for every room on screen that isn't open, to catch reactions the room list misses.
    private func updateProbes(for onScreen: Set<String>) {
        for (roomID, probe) in probes where !onScreen.contains(roomID) {
            probe.stop()
            probes[roomID] = nil
        }
        for roomID in onScreen where probes[roomID] == nil && timelines[roomID] == nil {
            guard let room = room(id: roomID) else { continue }
            probes[roomID] = RoomPreviewProbe(room: room) { [weak self] preview in
                guard let self, self.timelines[roomID] == nil else { return }
                self.reactionPreviews[roomID] = preview
            }
        }
    }

    /// Called when a room is left for another. A room whose loaded history has grown long (from
    /// scrolling back through it) is let go rather than kept warm: every message loaded is laid
    /// out each time the room is shown, so coming back to it would be slow. Opening it again
    /// starts from the local cache, which is quick, and earlier messages load as before.
    func roomWasLeft(_ roomID: String) {
        guard let timeline = timelines[roomID], timeline.rows.count > Self.longestWarmTimeline else { return }
        timelines.removeValue(forKey: roomID)
        dropBannerPins(for: roomID)
        timelineOrder.removeAll { $0 == roomID }
        timeline.stop()
        updateSubscriptions()
    }

    private static let longestWarmTimeline = 150

    private func touch(_ roomID: String) {
        timelineOrder.removeAll { $0 == roomID }
        timelineOrder.append(roomID)
        while timelineOrder.count > Self.maxCachedTimelines {
            let evicted = timelineOrder.removeFirst()
            timelines.removeValue(forKey: evicted)?.stop()
            dropBannerPins(for: evicted)
            // Still on screen, it needs a probe again; and its subscription may lapse.
            updateSubscriptions()
        }
    }

    func acceptInvite(roomID: String) async throws {
        try await room(id: roomID)?.join()
    }

    func leave(roomID: String) async throws {
        try await room(id: roomID)?.leave()
        timelines.removeValue(forKey: roomID)?.stop()
        dropBannerPins(for: roomID)
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
            summary.isMarkedUnread = info.isMarkedUnread
            if info.isDirect, info.heroes.count == 1 {
                summary.directUserID = info.heroes[0].userId
                if summary.avatarURL == nil { summary.avatarURL = info.heroes[0].avatarUrl }
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
