import Foundation
import MatrixRustSDK
import Perception

struct RoomSummary: Identifiable, Equatable {
    /// A topic as a line: its first one with anything in it, its spaces evened out. Nil for one
    /// with nothing in it.
    static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty }
        return line.map { String($0.prefix(240)) }
    }

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
    /// Messages have come since the room was last read (marking it unread aside).
    var hasNewMessages = false
    /// A space rather than a room (the room list leaves spaces out).
    var isSpace = false
    /// Tagged favourite or low priority (m.favourite, m.lowpriority), here or in another app.
    var isFavourite = false
    var isLowPriority = false
    /// False when the room's details could not be read, so the counts above mean nothing.
    var hasCounts = false
    var lastMessage: String?
    /// A call is going on in the room (MatrixRTC: someone is in it).
    var hasCall = false
    /// How many are in the call going on, counting each device.
    var callParticipantCount = 0
    /// The same said as a reply in a thread ("Bob in a thread: …"), for when the newest message
    /// turns out to be one: the SDK's latest event doesn't say (see `threadReplyDates`).
    var lastMessageInThread: String?
    var timestamp: Date?
    /// The room's own notification setting; nil when it follows the account's default
    /// (RoomNotifications.swift).
    var notificationMode: RoomNotificationMode?
    /// Which default it follows otherwise: the push rules tell these apart.
    var isEncrypted = false
    var isOneToOne = false
    /// What the room is about, on one line, as its window's subtitle shows it.
    var topic: String?

    var isMuted: Bool { notificationMode == .mute }
    /// Shown as unread: anything new, except that a muted room is only when marked unread.
    var showsUnread: Bool { isMuted ? isMarkedUnread : hasUnread }
    var isHighlighted: Bool { isInvite || notifications > 0 || mentions > 0 }
    /// Addressed to you personally: an invitation, a mention, or a direct message.
    var isUrgent: Bool { isInvite || mentions > 0 || (isDirect && notifications > 0) }
    /// Only new messages, in a room set aside as Low Priority: left out where unread rooms are
    /// gathered (a space's badge in the rail, Next Unread Room), as Element leaves them out of a
    /// space's badge. A count, a mention, or marking it unread on purpose still counts.
    var isLowPriorityActivity: Bool { isLowPriority && !isHighlighted && !isMarkedUnread }
}

/// One logged-in account: its client, sliding sync and room list.
/// What a room's row in the list says of a message being written there and not yet sent.
struct DraftPreview: Equatable {
    /// Its text on one line, or what is attached ("2 images and 1 file").
    let text: String
    /// Written in a thread of the room, rather than in the room itself.
    let inThread: Bool

    /// What a draft comes to on one line: nothing, when it's only a reply begun.
    static func summary(of draft: StashedDraft) -> String? {
        let words = draft.text.prefix(500).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !words.isEmpty { return words }
        var attached: [String] = []
        if !draft.images.isEmpty { attached.append(draft.images.count == 1 ? "1 image" : "\(draft.images.count) images") }
        if !draft.files.isEmpty { attached.append(draft.files.count == 1 ? "1 file" : "\(draft.files.count) files") }
        return attached.isEmpty ? nil : attached.formatted(.list(type: .and))
    }
}

@MainActor @Perceptible
final class AccountSession: Identifiable {
    nonisolated let id: String
    let userID: String
    let client: Client
    let media: MediaLoader

    private(set) var displayName: String?
    private(set) var avatarURL: String?
    /// The room list as shown: the rooms of every section, in order (see `sections`).
    private(set) var rooms: [RoomSummary] = []
    /// The room list's sections, in order, each with its rooms, most recent first: those of the
    /// space showing that match the search. See RoomSections.swift.
    private(set) var sections: [RoomSection] = []
    /// Rooms' own notification settings, by room ID, and the account's defaults for each kind of
    /// room, as the push rules have them (RoomNotifications.swift).
    var notificationModes: [String: RoomNotificationMode] = [:]
    var defaultNotificationModes: [NotificationDefaultKind: RoomNotificationMode] = [:]
    @PerceptionIgnored var notificationSettingsTask: Task<MatrixRustSDK.NotificationSettings, Never>?
    /// Rooms whose setting is being changed, and how many changes have been made so far.
    @PerceptionIgnored var notificationWrites: [String: Int] = [:]
    @PerceptionIgnored var notificationChanges = 0
    /// The account's own sections, by tag, and the order of People, Rooms and them, as Element
    /// keeps them (RoomSections.swift).
    var sectionData: [String: CustomSection] = [:] {
        didSet { if sectionData != oldValue { rebuildSections() } }
    }
    var sectionOrder: [String] = ElementSections.order(from: nil, sections: [:]) {
        didSet { if sectionOrder != oldValue { rebuildSections() } }
    }
    /// The section tag each room carries, if any.
    var roomSectionTags: [String: String] = [:] {
        didSet { if roomSectionTags != oldValue { rebuildSections() } }
    }
    /// Set by File > New Section…: the room list asks for the new section's name.
    var asksForNewSection = false
    /// A space whose page is to open ready to change its name and topic (Edit Space… in its
    /// menu), taken up by the page.
    var asksToEditSpace: String?
    /// The sections folded away in the list, by ID.
    var collapsedSections: Set<String> = [] {
        didSet { UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections.\(id)") }
    }
    /// False until the server has sent the first page of the room list.
    private(set) var hasLoadedRooms = false
    private(set) var syncState: SyncServiceState = .idle
    private(set) var verification: VerificationState = .unknown
    /// Emoji verification: of this Mac, and of devices and people asking to verify with it.
    let verificationFlow: VerificationFlow
    /// Whether the account has a recovery key, and this Mac the keys it unlocks.
    private(set) var recoveryState: RecoveryState = .unknown
    /// What is known of other people's encryption identities, as far as has been looked up or
    /// heard from rooms (PeopleIdentity.swift).
    var peopleIdentities: [String: PersonIdentity] = [:]
    /// The room list's suggestion to set up a recovery key, closed.
    var recoveryNudgeDismissed: Bool {
        didSet { UserDefaults.standard.set(recoveryNudgeDismissed, forKey: "recoveryNudgeDismissed.\(id)") }
    }
    private(set) var needsReauth = false
    private(set) var startError: String?
    var selectedRoomID: String? {
        didSet {
            RoomHistory.shared.noteChange()
            // A room opened takes the main area from a space being browsed, and is where to
            // come back to in the space it was opened in.
            if let selectedRoomID {
                browsingSpaceID = nil
                lastRoomBySpace[selectedSpaceID ?? ""] = selectedRoomID
                UserDefaults.standard.set(lastRoomBySpace, forKey: "lastRooms.\(id)")
            }
            // Something else was chosen first (by hand, from a notification): that stands.
            roomToReopen = nil
            guard selectedRoomID != oldValue else { return }
            // The room left: its row says what was being written there.
            if let oldValue { refreshDraftPreview(forRoom: oldValue) }
            forgetUnshownReturns()
            // From the click in the rail, when the room came with a space.
            if railChoice == nil { PerfLog.began("room selected") } else { PerfLog.mark("room selected") }
            updatePresenceWatch()
        }
    }
    /// Who is around, for the direct chats on screen.
    let presence: PresenceTracker
    /// Where each room was left, scrolled up through its history, so that it opens there again.
    /// For as long as Huddle is open.
    @PerceptionIgnored private var readingSpots: [String: ReadingSpot] = [:]
    /// Rooms closed since they were last shown: they open at their reading spot, if they have
    /// one. (A room's conversation also closes and notes its spot when the room swaps it for a
    /// view around an older message, or back, but stays open.)
    @PerceptionIgnored private var closedRooms: Set<String> = []
    /// A view around the message a room was left at, made as the room opens again, for it to
    /// show from the first frame: its own timeline no longer had that message (see
    /// `returnView(for:)`).
    @PerceptionIgnored private var returnViews: [String: RoomTimeline] = [:]
    /// Unsent messages, by room (and thread): what was being written there, kept while away.
    /// The text is kept across launches too; a reply and attachments, for this one.
    @PerceptionIgnored private var drafts: [String: StashedDraft] = [:]
    @PerceptionIgnored private lazy var savedDraftTexts: [String: String] =
        UserDefaults.standard.dictionary(forKey: "drafts.\(id)") as? [String: String] ?? [:]
    @PerceptionIgnored private var draftSave: DispatchWorkItem?
    /// What each room's row says of an unsent message there, by room. Not for the open room,
    /// whose composer shows it: its row catches up as it's left, so that typing there doesn't
    /// redraw the list at every key.
    private(set) var draftPreviews: [String: DraftPreview] = [:]
    /// A room just chosen in Go to Room: its composer takes the keyboard, though the room came
    /// by a key (Return) rather than a click.
    @PerceptionIgnored var wantsComposerFocus = false
    @PerceptionIgnored private let ownPresence: OwnPresence
    /// For rooms opened this session: a reaction that came after the room's newest message.
    private(set) var reactionPreviews: [String: ReactionPreview] = [:]
    /// Rooms whose newest message is a reply in a thread, by the reply's date, as the room's probe
    /// or open timeline saw it. The room list says "in a thread" when it is the room's latest
    /// message, so a reply to an old thread isn't looked for at the end of the room.
    private(set) var threadReplyDates: [String: Date] = [:]
    /// What the panel beside each room's timeline shows, so it is still there on coming back.
    var sidePanels: [String: ThreadPanel.Content] = [:]
    var searchText = "" {
        didSet { if searchText != oldValue { rebuildSections() } }
    }

    /// Rooms with notifications, for the account rail and Dock badge.
    private(set) var badgeCount = 0
    /// Rooms that need attention now: mentions, direct messages and pending invitations.
    private(set) var urgentCount = 0

    @PerceptionIgnored private var syncService: SyncService?
    @PerceptionIgnored private var roomListService: RoomListService?
    @PerceptionIgnored private var roomList: RoomList?
    // MARK: Spaces

    /// The account's top-level joined spaces, as the rail shows them.
    private(set) var spaces: [SpaceRoom] = []
    /// Every room and space the account is in or invited to, with its unread state. The room
    /// list shows only some (a space, a search); the badges count them all.
    private(set) var allRooms: [RoomSummary] = []
    /// For each space and the spaces in it, the rooms it holds.
    private(set) var spaceFilters: [SpaceFilter] = []
    /// The spaces this account may add rooms to and remove them from.
    private(set) var editableSpaceIDs: Set<String> = []
    /// The space the room list is narrowed to; nil for every room.
    var selectedSpaceID: String? {
        didSet {
            guard selectedSpaceID != oldValue else { return }
            UserDefaults.standard.set(selectedSpaceID, forKey: "selectedSpace.\(id)")
            rebuildSections()
        }
    }
    /// The space whose rooms are being browsed in the main area, in place of a room.
    var browsingSpaceID: String?
    /// A window to show over the main one: creating a room or space, adding rooms, leaving.
    var sheet: AccountSheet?
    /// Searching this account's messages; made the first time it's wanted.
    var search: MessageSearch {
        if let searchModel { return searchModel }
        let search = MessageSearch(client: client)
        searchModel = search
        return search
    }
    @PerceptionIgnored private var searchModel: MessageSearch?
    /// Goes through encrypted rooms' whole history, so search finds all of it.
    let historyIndexer = HistoryIndexer()
    /// The room last open with each space selected ("" for Home), to go back to.
    @PerceptionIgnored private var lastRoomBySpace: [String: String] = [:]
    /// The room that was open when the app last quit, to open again once the room list has it.
    @PerceptionIgnored private var roomToReopen: String?
    @PerceptionIgnored private(set) var spaceService: SpaceService?
    @PerceptionIgnored private var allEntries: RoomListEntriesWithDynamicAdaptersResult?
    @PerceptionIgnored private var allController: RoomListDynamicEntriesController?
    @PerceptionIgnored private var allRoomsTask: Task<Void, Never>?

    @PerceptionIgnored private var handles: [TaskHandle] = []
    /// The SDK's search pass, while it runs (`runSearchBackfillWhenIdle`).
    @PerceptionIgnored private var searchBackfill: TaskHandle?
    @PerceptionIgnored private var searchBackfillTask: Task<Void, Never>?
    /// Follows the rooms' sections, here and in other apps.
    @PerceptionIgnored var sectionsTask: Task<Void, Never>?
    /// Section changes under way here: the server's answers may not have them yet.
    @PerceptionIgnored var sectionWrites = 0
    @PerceptionIgnored private var restartTask: Task<Void, Never>?
    @PerceptionIgnored private var restartAttempts = 0
    @PerceptionIgnored private var pendingClears: Set<String> = []
    @PerceptionIgnored private var roomHandles: [String: Room] = [:]
    @PerceptionIgnored private var timelines: [String: RoomTimeline] = [:]
    @PerceptionIgnored private var probes: [String: RoomPreviewProbe] = [:]
    /// Who else is typing in each room. Followed in every room from the start, not only open
    /// ones: the server says only when the typists change, so a room opened while someone is
    /// typing would otherwise not know until they stopped.
    @PerceptionIgnored private var typingUserIDs: [String: [String]] = [:]
    /// The same by name, for the room list's rows: made for a room once its row asks.
    @PerceptionIgnored private var roomTypists: [String: RoomTypists] = [:]
    /// Names of those who have typed, by room and user ID, and those asked of the room so far.
    @PerceptionIgnored private var typistNames: [String: String] = [:]
    @PerceptionIgnored private var typistNamesAsked: Set<String> = []
    /// Whether people see when this account is typing, and it sees when they are. Element's
    /// setting, kept in the account's data; changed with `setSharesTyping`, which saves it there.
    var sharesTyping = true
    @PerceptionIgnored var typingSettingTask: Task<Void, Never>?
    @PerceptionIgnored var typingSettingObserver: NSObjectProtocol?
    /// The setting as just changed here, until the account's copy of its data catches up.
    @PerceptionIgnored var typingSettingSaved: (value: Bool, date: Date)?
    /// A name of the user's own for this account ("Work"), to tell it from their others
    /// (AccountLabel.swift); nil without one.
    var label: String?
    /// Just changed here, until the account's copy of its data says so too.
    @PerceptionIgnored var labelSaved: (value: String?, date: Date)?
    /// The user's own names for people, by user ID (ContactNames.swift).
    var contactNames: [String: String] = [:]
    @PerceptionIgnored var contactNamesSaved: (value: [String: String], date: Date)?
    /// Every timeline this account has made that's still about, to draw names again.
    @PerceptionIgnored private var madeTimelines = NSHashTable<RoomTimeline>.weakObjects()
    @PerceptionIgnored private var typingHandles: [String: TaskHandle] = [:]
    @PerceptionIgnored private var typingUpdates: AsyncStream<(roomID: String, userIDs: [String])>.Continuation?
    @PerceptionIgnored private var typingTask: Task<Void, Never>?
    @PerceptionIgnored private var visibleRooms: Set<String> = []
    @PerceptionIgnored private var subscribedRooms: Set<String> = []
    @PerceptionIgnored private var subscriptionTask: Task<Void, Never>?
    @PerceptionIgnored private var timelineOrder: [String] = []

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
        self.verificationFlow = VerificationFlow(client: client, userID: userID)
        self.recoveryNudgeDismissed = UserDefaults.standard.bool(forKey: "recoveryNudgeDismissed.\(id)")
        // The space the room list was narrowed to last time (didSet doesn't run in init).
        selectedSpaceID = UserDefaults.standard.string(forKey: "selectedSpace.\(id)")
        collapsedSections = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections.\(id)") ?? [])
        // And the room last open in each space, the one showing then to be opened again.
        lastRoomBySpace = UserDefaults.standard.dictionary(forKey: "lastRooms.\(id)") as? [String: String] ?? [:]
        roomToReopen = lastRoomBySpace[selectedSpaceID ?? ""]
        verificationFlow.isThisMacVerified = { [weak self] in self?.verification == .verified }
        verificationFlow.onIncoming = { [weak self] in self?.showVerificationRequest() }
        verificationFlow.onVerifiedPerson = { [weak self] userID in self?.peopleIdentities[userID] = .verified }
        // The drafts kept from last time, for their rooms' rows.
        for roomID in Set(savedDraftTexts.keys.map(Self.roomID(ofDraftKey:))) {
            refreshDraftPreview(forRoom: roomID)
        }
    }

    /// A request to verify came in: shown at once unless something else is open, when the room
    /// list has a banner for it instead. Announced if Huddle isn't in front, or this account isn't.
    private func showVerificationRequest() {
        if sheet == nil, !verificationFlow.isShown { sheet = .verify }
        Notifier.shared.announceVerificationRequest(for: self)
    }

    /// Opens the room that was open at the last quit, once the room list has it: opened before
    /// then, it would show as unavailable. Not if anything has been opened since.
    private func reopenLastRoom() {
        guard let roomID = roomToReopen, selectedRoomID == nil, browsingSpaceID == nil,
              allRooms.contains(where: { $0.id == roomID && !$0.isInvite }) else { return }
        selectedRoomID = roomID
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
            observeAllRooms(in: roomList)
            await startSpaces()
            sectionsTask = Task { [weak self] in await self?.followSections() }
            Task { [weak self] in await self?.loadNotificationModes() }
            let loading = try roomList.loadingState(listener: RoomListLoadingListener { [weak self] state in
                Task { @MainActor in self?.hasLoadedRooms = state != .notLoaded }
            })
            hasLoadedRooms = loading.state != .notLoaded
            handles.append(loading.stateStream)

            handles.append(client.encryption().verificationStateListener(listener: VerificationListener { [weak self] state in
                Task { @MainActor in self?.verification = state }
            }))
            verification = client.encryption().verificationState()
            handles.append(client.encryption().recoveryStateListener(listener: RecoveryListener { [weak self] state in
                Task { @MainActor in self?.recoveryState = state }
            }))
            recoveryState = client.encryption().recoveryState()

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
            verificationFlow.connect()
            runSearchBackfillWhenIdle()
            historyIndexer.start(for: self)
            startError = nil
            ownPresence.start()
            presence.start()
            followTypingSetting()
        } catch {
            startError = error.actionMessage
        }
        await loadProfile()
    }

    /// The SDK's search pass, which fills the search index with about three months of every
    /// room's history, newest weeks first: only while Huddle is idle (`IndexingSchedule`).
    /// Stopped the moment it's in use, started over once it isn't (what it has already fetched
    /// comes from this Mac's store, quickly); once all the way through, not again this launch.
    private func runSearchBackfillWhenIdle() {
        searchBackfillTask?.cancel()
        let client = client
        searchBackfillTask = Task { [weak self] in
            while !Task.isCancelled {
                await IndexingSchedule.shared.waitUntilIdle()
                guard !Task.isCancelled else { return }
                let handle = client.runSearchBackfill(strategy: .foreground)
                self?.searchBackfill = handle
                while !Task.isCancelled, !handle.isFinished(), IndexingSchedule.shared.isIdle {
                    try? await Task.sleep(for: .seconds(2))
                }
                self?.searchBackfill = nil
                if handle.isFinished() { return }
                handle.cancel()
            }
        }
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
        sectionsTask?.cancel()
        allRoomsTask?.cancel()
        handles.forEach { $0.cancel() }
        handles.removeAll()
        searchBackfillTask?.cancel()
        searchBackfillTask = nil
        searchBackfill?.cancel()
        searchBackfill = nil
        timelines.values.forEach { $0.stop() }
        timelines.removeAll()
        returnViews.values.forEach { $0.stop() }
        returnViews.removeAll()
        bannerPinTimelines.values.forEach { $0.stop() }
        bannerPinTimelines.removeAll()
        searchModel?.stop()
        verificationFlow.disconnect()
        historyIndexer.stop()
        subscriptionTask?.cancel()
        typingHandles.values.forEach { $0.cancel() }
        typingHandles.removeAll()
        typingUpdates?.finish()
        typingTask?.cancel()
        roomTypists.values.forEach { $0.names = [] }
        stopFollowingTypingSetting()
        presence.stop()
        ownPresence.stop()
        probes.values.forEach { $0.stop() }
        probes.removeAll()
        let syncService = syncService
        self.syncService = nil
        await syncService?.stop()
    }

    func loadProfile() async {
        let client = client
        async let name = try? client.displayName()
        async let avatar = try? client.avatarUrl()
        displayName = await name
        avatarURL = await avatar ?? nil
    }

    // MARK: Room list

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

    /// Sorts the rooms into the list's sections, in Element's order: invitations and favourites
    /// first, then People, Rooms and the account's own sections in the order set (here or in
    /// Element), then low priority. Only rooms of the list showing (a space's, or Home's) that
    /// match the search; spaces left out. While searching, rooms found anywhere else follow,
    /// under Elsewhere, so none is out of reach. A room is in one section: a favourite or a room
    /// in an own section is there even if tagged otherwise too. Empty sections are left out,
    /// except the account's own made where the list is showing (Home, or that space), so rooms
    /// can be put in them.
    func rebuildSections() {
        let listed = roomIDs(listedIn: selectedSpaceID)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        var buckets: [String: [RoomSummary]] = [:]
        var elsewhere: [RoomSummary] = []
        for room in allRooms where !room.isSpace {
            if !query.isEmpty, room.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                continue
            }
            guard listed.contains(room.id) else {
                if !query.isEmpty { elsewhere.append(room) }
                continue
            }
            let ownSection = roomSectionTags[room.id].flatMap { sectionData[$0] != nil ? $0 : nil }
            buckets[RoomSection.id(for: room, ownSection: ownSection), default: []].append(room)
        }
        var result: [RoomSection] = []
        func add(_ id: String, _ title: String, _ kind: RoomSection.Kind, keepEmpty: Bool = false) {
            let rooms = buckets[id] ?? []
            if !rooms.isEmpty || keepEmpty { result.append(RoomSection(id: id, kind: kind, title: title, rooms: rooms)) }
        }
        add(RoomSection.invitesID, "Invitations", .invites)
        add(RoomSection.favouritesID, "Favourites", .favourites)
        for tag in sectionOrder {
            switch tag {
            case ElementSections.peopleTag: add(RoomSection.peopleID, "People", .people)
            case ElementSections.chatsTag: add(RoomSection.roomsID, "Rooms", .rooms)
            default:
                guard let section = sectionData[tag] else { continue }
                add(tag, section.name, .custom, keepEmpty: query.isEmpty && isShowingSpace(of: section))
            }
        }
        add(RoomSection.lowPriorityID, "Low Priority", .lowPriority)
        if !elsewhere.isEmpty {
            result.append(RoomSection(id: RoomSection.elsewhereID, kind: .elsewhere, title: "Elsewhere", rooms: elsewhere))
        }
        if result != sections { sections = result }
        let flattened = result.flatMap(\.rooms)
        if flattened != rooms { rooms = flattened }
    }

    /// Whether the list shows where a section was made: its space, or the whole list for one
    /// made there (or in a space since left).
    private func isShowingSpace(of section: CustomSection) -> Bool {
        let madeIn = section.spaceID.flatMap { $0 == ElementSections.homeSpace ? nil : $0 }
        if let selectedSpaceID { return madeIn == selectedSpaceID }
        return madeIn == nil || !spaces.contains { $0.roomId == madeIn }
    }

    /// Shows a tag change at once, before the server's own record of it syncs back.
    func showTags(of roomID: String, favourite: Bool, lowPriority: Bool) {
        guard let index = allRooms.firstIndex(where: { $0.id == roomID }) else { return }
        allRooms[index].isFavourite = favourite
        allRooms[index].isLowPriority = lowPriority
        rebuildSections()
    }

    /// Puts each room's notification setting on its summary, where the list reads it.
    func stampNotificationModes() {
        var changed = false
        for index in allRooms.indices where allRooms[index].notificationMode != notificationModes[allRooms[index].id] {
            allRooms[index].notificationMode = notificationModes[allRooms[index].id]
            changed = true
        }
        if changed { rebuildSections() }
    }

    /// Keeps `allRooms` up to date: every room and space, whatever the room list is narrowed to.
    private func observeAllRooms(in roomList: RoomList) {
        let (stream, continuation) = AsyncStream.makeStream(of: [RoomListEntriesUpdate].self)
        let entries = roomList.entriesWithDynamicAdapters(pageSize: 10_000,
                                                          listener: RoomEntriesListener { continuation.yield($0) })
        allEntries = entries
        allController = entries.controller()
        _ = allController?.setFilter(kind: .all(filters: [.nonLeft, .deduplicateVersions]))
        handles.append(entries.entriesStream())
        // Diffs are processed strictly in order; summaries are built off the main actor.
        allRoomsTask = Task.detached { [weak self] in
            for await updates in stream {
                var diffs: [VectorDiff<(Room, RoomSummary)>] = []
                // The user's names for people as they are now: a direct chat's name, and who
                // wrote the newest message.
                let names = await self?.contactNames ?? [:]
                for update in updates {
                    diffs.append(await update.diff.map { room in (room, await RoomSummary.make(from: room, names: names)) })
                }
                await self?.applyAll(diffs)
            }
        }
    }

    private func applyAll(_ diffs: [VectorDiff<(Room, RoomSummary)>]) {
        var all = allRooms
        for diff in diffs {
            all.apply(diff.mapValues { room, summary in
                roomHandles[summary.id] = room
                return summary
            })
        }
        stampNotificationModes(on: &all)
        let previous = allRooms
        allRooms = all
        followTyping(in: all)
        updateBadges()
        rebuildSections()
        reopenLastRoom()
        // Marked unread from another device: a room open here stays unread too, rather than
        // being read again by the next message that arrives.
        let wasMarked = Set(previous.filter(\.isMarkedUnread).map(\.id))
        for room in all where room.isMarkedUnread && !wasMarked.contains(room.id) {
            timelines[room.id]?.holdsUnread = true
        }
        // A direct chat's other person may only now be known.
        if all.contains(where: { $0.directUserID != nil && visibleRooms.contains($0.id) }) { updatePresenceWatch() }
        // A room that stops needing attention (read here or elsewhere) drops its notifications.
        // Only on a definite answer: the room is still listed and its counts were read.
        let current = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for room in previous where room.isHighlighted {
            if let now = current[room.id], now.hasCounts, !now.isHighlighted {
                clearNotificationsIfStillRead(roomID: room.id)
            }
        }
    }

    /// The account's badges count rooms needing attention, and invitations to spaces.
    private func updateBadges() {
        let counted = allRooms.filter { !$0.isSpace || $0.isInvite }
        badgeCount = counted.reduce(0) { $0 + ($1.isHighlighted ? 1 : 0) }
        urgentCount = counted.reduce(0) { $0 + ($1.isUrgent ? 1 : 0) }
    }

    private func startSpaces() async {
        let service = await client.spaceService()
        spaceService = service
        spaces = await service.topLevelJoinedSpaces()
        spaceFilters = await service.spaceFilters()
        handles.append(await service.subscribeToTopLevelJoinedSpaces(listener: SpaceListListener { [weak self] updates in
            Task { @MainActor in self?.applySpaceUpdates(updates) }
        }))
        handles.append(await service.subscribeToSpaceFilters(listener: SpaceFiltersListener { [weak self] updates in
            Task { @MainActor in self?.applyFilterUpdates(updates) }
        }))
        await refreshEditableSpaces()
        // The space selected last time may have been left since, here or elsewhere.
        if let selected = selectedSpaceID, !spaces.contains(where: { $0.roomId == selected }) {
            selectedSpaceID = nil
        }
        rebuildSections()
    }

    private func applySpaceUpdates(_ updates: [SpaceListUpdate]) {
        var spaces = spaces
        let before = Set(spaces.map(\.roomId))
        for update in updates { spaces.apply(update.diff) }
        self.spaces = spaces
        // A space left (here or elsewhere) can't stay selected. One just joined may be selected
        // before it arrives here, so only a space that was here and went counts.
        if let selected = selectedSpaceID, before.contains(selected),
           !spaces.contains(where: { $0.roomId == selected }) {
            selectedSpaceID = nil
            if browsingSpaceID == selected { browsingSpaceID = nil }
        }
        Task { await refreshEditableSpaces() }
    }

    private func applyFilterUpdates(_ updates: [SpaceFilterUpdate]) {
        var filters = spaceFilters
        for update in updates { filters.apply(update.diff) }
        spaceFilters = filters
        // Every list depends on them: a space's for its rooms, Home's for the rooms it leaves out.
        rebuildSections()
    }

    private func refreshEditableSpaces() async {
        guard let spaceService else { return }
        editableSpaceIDs = Set(await spaceService.editableSpaces().map(\.roomId))
    }

    /// Narrows the room list to a space (nil for Home) and shows the room last open there, if
    /// it is still in it, or else the space itself.
    func show(space spaceID: String?) {
        selectedSpaceID = spaceID
        openRoom(forSpace: spaceID)
    }

    /// What was just chosen in the spaces rail. The rail shows it at once, rather than waiting
    /// on the room list and the conversation, which take a moment to draw.
    var railChoice: RailChoice?

    enum RailChoice: Equatable {
        case home
        case space(String)
        case invite(String)
    }

    /// A choice in the spaces rail: shown there in this frame, then the room list narrowed and
    /// the room or space opened together in the next. Apart, the new list showed for a moment
    /// beside the last space's conversation, which read as a flicker. A newer choice before then
    /// wins.
    func choose(inRail choice: RailChoice) {
        PerfLog.began("space chosen")
        railChoice = choice
        afterThisFrame { [weak self] in
            guard let self, self.railChoice == choice else { return }
            switch choice {
            case .home:
                self.selectedSpaceID = nil
                self.openRoom(forSpace: nil)
            case .space(let spaceID):
                self.selectedSpaceID = spaceID
                self.openRoom(forSpace: spaceID)
            case .invite(let inviteID):
                self.selectedRoomID = nil
                self.browsingSpaceID = inviteID
            }
            self.railChoice = nil
            PerfLog.markDrawn("room list and room shown")
        }
    }

    /// Runs once what has changed so far is on screen: a timer, unlike a block for the main
    /// queue, waits for the run loop to draw first.
    private func afterThisFrame(_ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { MainActor.assumeIsolated(work) }
    }

    /// The room last open in a space (or Home), if it is still there; else the space itself, or
    /// for Home, which has no page of its own, no room: the room open stays only if the list
    /// shown holds it, so the two always agree.
    private func openRoom(forSpace spaceID: String?) {
        let listed = roomIDs(listedIn: spaceID)
        if let last = lastRoomBySpace[spaceID ?? ""], listed.contains(last) {
            selectedRoomID = last
        } else if let current = selectedRoomID, listed.contains(current) {
            browsingSpaceID = nil
        } else if let spaceID {
            selectedRoomID = nil
            browsingSpaceID = spaceID
        } else {
            selectedRoomID = nil
            browsingSpaceID = nil
        }
    }

    /// Opens a search result: goes to its room, the search still beside it, and to the
    /// message there.
    func open(_ hit: SearchHit) {
        search.selectedEventID = hit.eventID
        // To the message found, not to where the room was left.
        readingSpots[hit.roomID] = nil
        if hit.roomID != selectedRoomID {
            sidePanels[hit.roomID] = .search
            // Into the list too: a room outside the space shown would be open but not in it.
            showInList(hit.roomID)
        }
        let timeline = timeline(for: hit.roomID)
        selectedRoomID = hit.roomID
        // Straight there if the room shows the message itself; otherwise first find out
        // which message it belongs to (an edit's, a thread's).
        if hit.jumpEventID == nil, timeline?.rows.contains(where: { $0.eventID == hit.eventID }) == true {
            timeline?.requestedJump = hit.eventID
            return
        }
        Task {
            let target = await search.jumpTarget(for: hit)
            guard search.selectedEventID == hit.eventID else { return }
            timeline?.requestedJump = target
        }
    }

    /// Opens the search beside the open room: Find (this room) or Find in All Rooms.
    func showSearch(scope: MessageSearch.Scope) {
        guard let roomID = selectedRoomID, browsingSpaceID == nil else { return }
        sidePanels[roomID] = .search
        search.focus(scope: scope)
    }

    /// Find Next and Find Previous: the next result along, opened.
    func showSearchResult(after offset: Int) {
        guard let hit = searchModel?.step(by: offset) else { return }
        open(hit)
    }

    /// Shows a space's rooms in the main area, joined or not, with the list narrowed to the
    /// account's space that holds it.
    func browse(space spaceID: String) {
        if let top = topLevelSpace(containing: spaceID) { selectedSpaceID = top }
        selectedRoomID = nil
        browsingSpaceID = spaceID
    }

    /// Edit Space…: the space's page, open on changing its name and topic (its picture is changed
    /// there too, by clicking it).
    func editDetails(ofSpace spaceID: String) {
        asksToEditSpace = spaceID
        browse(space: spaceID)
    }

    /// Joins a space the account was invited to, and goes on showing it, now as one of the
    /// account's own.
    func acceptSpaceInvite(_ spaceID: String) async throws {
        try await acceptInvite(roomID: spaceID)
        selectedSpaceID = spaceID
        if selectedRoomID == nil { browsingSpaceID = spaceID }
    }

    func declineSpaceInvite(_ spaceID: String) async throws {
        try await leave(roomID: spaceID)
        if browsingSpaceID == spaceID { browsingSpaceID = nil }
    }

    /// Every room in a space, including those in the spaces within it.
    func roomIDs(inSpace spaceID: String) -> Set<String> {
        let filters = Dictionary(spaceFilters.map { ($0.spaceRoom.roomId, $0) }, uniquingKeysWith: { first, _ in first })
        var result: Set<String> = []
        var seen: Set<String> = []
        var queue = [spaceID]
        while let id = queue.popLast() {
            guard seen.insert(id).inserted, let filter = filters[id] else { continue }
            for child in filter.descendants {
                result.insert(child)
                if filters[child] != nil { queue.append(child) }
            }
        }
        return result
    }

    /// Every room in one of the account's spaces, at any depth: the rooms Home leaves out.
    var roomIDsInSpaces: Set<String> {
        Set(spaceFilters.flatMap(\.descendants))
    }

    /// The rooms a space's list holds, or with none, Home's: direct chats and rooms in no space,
    /// so a chat filed in a space is in one place and lights up one badge.
    func roomIDs(listedIn spaceID: String?) -> Set<String> {
        if let spaceID { return roomIDs(inSpace: spaceID) }
        let inSpaces = roomIDsInSpaces
        return Set(allRooms.lazy.filter { !$0.isSpace && !inSpaces.contains($0.id) }.map(\.id))
    }

    /// How a space's rooms (Home's, with none) stand, counted as the account's badge counts
    /// them: how many have notifications, how many of those need attention now, and whether any
    /// has anything unread.
    func attention(inSpace spaceID: String?) -> (count: Int, urgent: Int, hasUnread: Bool) {
        let ids = roomIDs(listedIn: spaceID)
        var count = 0
        var urgent = 0
        var hasUnread = false
        for room in allRooms where !room.isSpace && ids.contains(room.id) {
            if room.isHighlighted { count += 1 }
            if room.isUrgent { urgent += 1 }
            if room.showsUnread, !room.isLowPriorityActivity { hasUnread = true }
        }
        return (count, urgent, hasUnread)
    }

    /// Marks every room in a space (Home, with none) read.
    func markAllRead(inSpace spaceID: String?) {
        let ids = roomIDs(listedIn: spaceID)
        for room in allRooms where ids.contains(room.id) && Self.isUnread(room) {
            setRoom(room.id, unread: false)
        }
    }

    func hasUnreadRooms(inSpace spaceID: String?) -> Bool {
        let ids = roomIDs(listedIn: spaceID)
        return allRooms.contains { ids.contains($0.id) && Self.isUnread($0) }
    }

    /// Whether a room sits in a space itself, rather than in a space within it: only then can
    /// it be taken out of that space.
    func isDirectChild(_ roomID: String, of spaceID: String) -> Bool {
        spaceFilters.first { $0.spaceRoom.roomId == spaceID && $0.level == 0 }?.descendants.contains(roomID) ?? false
    }

    /// The account's own space that holds a space or room, itself included.
    func topLevelSpace(containing id: String) -> String? {
        if spaces.contains(where: { $0.roomId == id }) { return id }
        return spaces.first { roomIDs(inSpace: $0.roomId).contains(id) }?.roomId
    }

    /// Spaces the account has been invited to.
    var invitedSpaces: [RoomSummary] {
        allRooms.filter { $0.isSpace && $0.isInvite }
    }

    /// What is known of a space: one of the account's own, or one it has been invited to.
    func spaceName(_ spaceID: String) -> String {
        spaces.first { $0.roomId == spaceID }?.displayName
            ?? allRooms.first { $0.id == spaceID }?.name
            ?? "Space"
    }

    // MARK: Space actions

    /// Joins a room found in a space. `via` are servers that can introduce this one to it.
    func join(roomID: String, via: [String]) async throws {
        _ = try await client.joinRoomByIdOrAlias(roomIdOrAlias: roomID, serverNames: via)
    }

    /// Who can join a room being created.
    enum RoomAccess: Hashable {
        /// Only people invited to it.
        case invited
        /// Anyone in the given space.
        case spaceMembers(String)
        /// Anyone at all.
        case anyone
    }

    /// Power levels for a new room or chat in which anyone may take part in calls, as Element
    /// makes them: Synapse's own levels for its events (the override replaces them whole), with
    /// call membership open to every member, which Element Call needs to join.
    static let callFriendlyPowerLevels = PowerLevels(
        usersDefault: nil, eventsDefault: nil, stateDefault: nil, ban: nil, kick: nil, redact: nil,
        invite: nil, notifications: nil, users: [:],
        events: [
            "m.room.name": 50, "m.room.power_levels": 100, "m.room.history_visibility": 100,
            "m.room.canonical_alias": 50, "m.room.avatar": 50, "m.room.tombstone": 100,
            "m.room.server_acl": 100, "m.room.encryption": 100,
            "org.matrix.msc3401.call.member": 0,
        ])

    /// Creates a room and, given a space, puts it there. Returns the new room's ID.
    func createRoom(name: String, topic: String?, access: RoomAccess, encrypted: Bool,
                    inSpace spaceID: String?) async throws -> String {
        var joinRule: JoinRule?
        if case .spaceMembers(let space) = access {
            joinRule = .restricted(rules: [.roomMembership(roomId: space)])
        }
        let parameters = CreateRoomParameters(
            name: name, topic: topic?.isEmpty == true ? nil : topic, isEncrypted: encrypted,
            visibility: access == .anyone ? .public : .private,
            preset: access == .anyone ? .publicChat : .privateChat,
            powerLevelContentOverride: Self.callFriendlyPowerLevels,
            joinRuleOverride: joinRule)
        let roomID = try await client.createRoom(request: parameters)
        if let spaceID {
            do {
                try await addNewRoom(roomID, toSpace: spaceID)
            } catch {
                throw RoomNotAddedToSpace(roomID: roomID, underlying: error)
            }
        }
        return roomID
    }

    /// Puts a room just made into a space. The SDK links the two only once the new room's
    /// power levels and members have come back from the server in a sync, which can be a
    /// moment after the room exists.
    func addNewRoom(_ roomID: String, toSpace spaceID: String) async throws {
        let room = try await client.awaitRoomRemoteEcho(roomId: roomID)
        for _ in 0..<40 {
            if (try? await room.getPowerLevels()) != nil { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await spaceService?.addChildToSpace(childId: roomID, spaceId: spaceID)
    }

    // MARK: Direct chats

    /// People whose names or Matrix IDs match, from the server's directory: usually those
    /// who share a room with this account or are in a public one.
    func searchPeople(_ term: String) async throws -> [UserProfile] {
        try await client.searchUsers(searchTerm: term, limit: 30).results
            .filter { $0.userId != userID }
    }

    /// Someone's name and picture, or an error if there's nobody by that ID.
    func profile(of userID: String) async throws -> UserProfile {
        try await client.getProfile(userId: userID)
    }

    /// False when the server says nobody has a Matrix ID; nil when it won't say.
    func userExists(_ userID: String) async -> Bool? {
        await ServerSearch(client: client).userExists(userID)
    }

    /// The direct chat already had with someone, if any.
    func existingDirectChat(with userID: String) -> String? {
        (try? client.getDmRoom(userId: userID))?.id()
    }

    /// The direct chat with someone, made (with them invited, and encrypted unless asked
    /// not to be) if there isn't one yet. Returns its ID.
    func directChat(with userID: String, encrypted: Bool = true) async throws -> String {
        if let roomID = existingDirectChat(with: userID) { return roomID }
        let parameters = CreateRoomParameters(
            name: nil, topic: nil, isEncrypted: encrypted, isDirect: true,
            visibility: .private, preset: .trustedPrivateChat, invite: [userID],
            powerLevelContentOverride: Self.callFriendlyPowerLevels)
        return try await client.createRoom(request: parameters)
    }

    /// A group chat already had with exactly these people: its other members, joined or
    /// invited, are them and nobody else. Only chats with the right number of members have
    /// their members looked at.
    func existingGroupChat(with userIDs: Set<String>) async -> String? {
        for summary in allRooms where summary.isDirect && !summary.isInvite && !summary.isSpace {
            guard let room = room(id: summary.id), let info = try? await room.roomInfo(),
                  info.activeMembersCount == UInt64(userIDs.count + 1),
                  let members = try? await room.members() else { continue }
            var others = Set<String>()
            while let chunk = members.nextChunk(chunkSize: 100) {
                for member in chunk {
                    switch member.membership {
                    case .join, .invite: others.insert(member.userId)
                    default: break
                    }
                }
            }
            others.remove(userID)
            if others == userIDs { return summary.id }
        }
        return nil
    }

    /// Starts a group chat with several people (all of them invited, and encrypted unless
    /// asked not to be), named if a name is given; otherwise clients name it after who's in
    /// it. Returns its ID.
    func groupChat(with userIDs: [String], name: String?, encrypted: Bool = true) async throws -> String {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let parameters = CreateRoomParameters(
            name: name?.isEmpty == false ? name : nil, topic: nil, isEncrypted: encrypted, isDirect: true,
            visibility: .private, preset: .trustedPrivateChat, invite: userIDs,
            powerLevelContentOverride: Self.callFriendlyPowerLevels)
        return try await client.createRoom(request: parameters)
    }

    /// Who is in a room or invited to it, and which.
    func memberships(in roomID: String) async -> [String: MembershipState] {
        guard let room = room(id: roomID), let members = try? await room.members() else { return [:] }
        var result: [String: MembershipState] = [:]
        while let chunk = members.nextChunk(chunkSize: 200) {
            for member in chunk where member.membership == .join || member.membership == .invite {
                result[member.userId] = member.membership
            }
        }
        return result
    }

    /// Invites people to a room, one at a time. Returns those who couldn't be invited, and why.
    func invite(_ userIDs: [String], to roomID: String) async -> [(userID: String, error: Error)] {
        guard let room = room(id: roomID) else {
            return userIDs.map { ($0, RoomError.unavailable) }
        }
        var failures: [(userID: String, error: Error)] = []
        for userID in userIDs {
            do { try await room.inviteUserById(userId: userID) } catch { failures.append((userID, error)) }
        }
        return failures
    }

    /// Shows a room, with the room list where it can be seen (see `showInList`). At its newest
    /// message, for something new there (a notification, a message about to be written), rather
    /// than where it was left.
    func showRoom(_ roomID: String, atNewest: Bool = false) {
        if atNewest { readingSpots[roomID] = nil }
        showInList(roomID)
        selectedRoomID = roomID
    }

    /// Makes the room list show a room, if it doesn't already: on the first space in the rail
    /// that holds it, or on Home if none does. A list showing that holds it is left as it is.
    func showInList(_ roomID: String) {
        guard !roomIDs(listedIn: selectedSpaceID).contains(roomID) else { return }
        selectedSpaceID = topLevelSpace(containing: roomID)
    }

    /// Creates a space. Returns its ID.
    func createSpace(name: String, topic: String?, isPublic: Bool) async throws -> String {
        let parameters = CreateRoomParameters(
            name: name, topic: topic?.isEmpty == true ? nil : topic, isEncrypted: false,
            visibility: isPublic ? .public : .private,
            preset: isPublic ? .publicChat : .privateChat,
            isSpace: true)
        return try await client.createRoom(request: parameters)
    }

    func addRooms(_ roomIDs: [String], toSpace spaceID: String) async throws {
        guard let spaceService else { return }
        for roomID in roomIDs {
            if let chat = allRooms.first(where: { $0.id == roomID }), chat.isDirect {
                try await addDirectChat(chat, toSpace: spaceID)
            } else {
                try await spaceService.addChildToSpace(childId: roomID, spaceId: spaceID)
            }
        }
    }

    /// Files a direct chat in a space: the space says it holds the chat, and the chat itself is
    /// left alone. The SDK would also mark the chat as in the space, a change the others in it
    /// would get, naming a space of yours they may not be in.
    private func addDirectChat(_ chat: RoomSummary, toSpace spaceID: String) async throws {
        guard let space = room(id: spaceID) else { throw SpaceNotFound() }
        // Servers that can lead someone to the chat: this account's, and the other person's.
        var servers = [Self.server(of: userID)]
        if let other = chat.directUserID.map(Self.server(of:)), !servers.contains(other) { servers.append(other) }
        let content = try JSONSerialization.data(withJSONObject: ["via": servers])
        _ = try await space.sendStateEventRaw(eventType: "m.space.child", stateKey: chat.id,
                                              content: String(decoding: content, as: UTF8.self))
    }

    private static func server(of userID: String) -> String {
        userID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? userID
    }

    struct SpaceNotFound: LocalizedError {
        var errorDescription: String? { "The space isn’t available on this Mac yet. Try again in a moment." }
    }

    func removeRoom(_ roomID: String, fromSpace spaceID: String) async throws {
        try await spaceService?.removeChildFromSpace(childId: roomID, spaceId: spaceID)
    }

    /// The spaces a room is directly in, among the account's.
    func parentSpaceIDs(of roomID: String) async -> [String] {
        (try? await spaceService?.joinedParentIdsOfChild(childId: roomID)) ?? []
    }

    /// Starts leaving a space: the handle lists the space's rooms the account is in, any of
    /// which can be left with it.
    func leaveSpaceHandle(_ spaceID: String) async throws -> LeaveSpaceHandle? {
        try await spaceService?.leaveSpace(spaceId: spaceID)
    }

    /// Leaves a space and whichever of its rooms were chosen.
    func leave(space spaceID: String, with handle: LeaveSpaceHandle, alsoLeaving roomIDs: Set<String>) async throws {
        let leaving = roomIDs.union([spaceID])
        // The handle lists the rooms innermost first, so each space goes after what it holds.
        let ordered = handle.rooms().map(\.spaceRoom.roomId).filter(leaving.contains)
        try await handle.leave(roomIds: ordered.isEmpty ? [spaceID] : ordered)
        for roomID in leaving {
            timelines.removeValue(forKey: roomID)?.stop()
            readingSpots[roomID] = nil
            dropBannerPins(for: roomID)
        }
        if let selected = selectedRoomID, leaving.contains(selected) { selectedRoomID = nil }
        // Back to every room, and the one last open there.
        if selectedSpaceID == spaceID || browsingSpaceID == spaceID { show(space: nil) }
    }

    // MARK: Rooms

    func room(id: String) -> Room? {
        roomHandles[id] ?? (try? client.getRoom(roomId: id))
    }

    /// Whether a room is open, or was open recently: Huddle has timelines on it, which paging
    /// through its history elsewhere would load all of it into.
    func hasOpenTimelines(for roomID: String) -> Bool {
        selectedRoomID == roomID || timelines[roomID] != nil || bannerPinTimelines[roomID] != nil
    }

    /// The room the history indexer is paging through. A room in view in the list has a probe
    /// (for its reactions) that would take in all of that history: it stops meanwhile, and the
    /// rooms in view get theirs back after.
    var roomBeingIndexed: String? {
        didSet {
            guard roomBeingIndexed != oldValue else { return }
            if let roomBeingIndexed, let probe = probes.removeValue(forKey: roomBeingIndexed) {
                probe.stop()
            }
            if roomBeingIndexed == nil { updateSubscriptions(now: true) }
        }
    }

    /// A room's live timeline if it's open already, without opening it or counting a visit.
    func openTimeline(for roomID: String) -> RoomTimeline? { timelines[roomID] }

    /// The live timeline for a room, kept warm for the most recently opened rooms.
    func timeline(for roomID: String) -> RoomTimeline? {
        if let existing = timelines[roomID] {
            touch(roomID)
            return existing
        }
        guard let room = room(id: roomID) else { return nil }
        let timeline = prepared(RoomTimeline(room: room))
        timeline.onLatestReaction = { [weak self] preview in self?.reactionPreviews[roomID] = preview }
        timeline.onLatestThreadReply = { [weak self] date in self?.setThreadReplyDate(date, for: roomID) }
        timeline.onIdentityChanges = { [weak self] changes in self?.applyIdentityChanges(changes) }
        timeline.setTypingUserIDs(typingUserIDs[roomID] ?? [])
        timelines[roomID] = timeline
        // The open room reports its own reactions now; its probe has nothing to add.
        probes.removeValue(forKey: roomID)?.stop()
        touch(roomID)
        updateSubscriptions(now: true)
        return timeline
    }

    /// Follows who is typing in each of these rooms, and stops for rooms no longer listed. Every
    /// room's news comes down one stream, so it's taken in the order it came.
    private func followTyping(in rooms: [RoomSummary]) {
        if typingUpdates == nil {
            let (stream, continuation) = AsyncStream.makeStream(of: (roomID: String, userIDs: [String]).self)
            typingUpdates = continuation
            typingTask = Task { [weak self] in
                for await update in stream { self?.setTyping(update.userIDs, in: update.roomID) }
            }
        }
        let listed = Set(rooms.map(\.id))
        for (roomID, handle) in typingHandles where !listed.contains(roomID) {
            handle.cancel()
            typingHandles[roomID] = nil
            if typingUserIDs.removeValue(forKey: roomID) != nil {
                timelines[roomID]?.setTypingUserIDs([])
                roomTypists[roomID]?.names = []
            }
        }
        guard let updates = typingUpdates else { return }
        for roomID in listed where typingHandles[roomID] == nil {
            guard let room = roomHandles[roomID] else { continue }
            typingHandles[roomID] = room.subscribeToTypingNotifications(listener: TypingObserver { userIDs in
                updates.yield((roomID, userIDs))
            })
        }
    }

    private func setTyping(_ userIDs: [String], in roomID: String) {
        if AppEnvironment.isDev {
            print("DEV_TYPING \(userID) \(roomID) \(userIDs)")
            fflush(stdout)
        }
        let others = userIDs.filter { $0 != userID }
        guard others != typingUserIDs[roomID] ?? [] else { return }
        typingUserIDs[roomID] = others.isEmpty ? nil : others
        timelines[roomID]?.setTypingUserIDs(others)
        showTypists(others, in: roomID)
    }

    /// What was being written in a room (or a thread, keyed "room|root"), if anything.
    func draft(for key: String) -> StashedDraft? {
        drafts[key] ?? savedDraftTexts[key].map { StashedDraft(text: $0) }
    }

    /// Keeps what is being written in a room for coming back to; nothing to keep forgets it.
    func keepDraft(_ draft: StashedDraft, for key: String) {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isEmpty = text.isEmpty && draft.reply == nil && draft.images.isEmpty && draft.files.isEmpty
        drafts[key] = isEmpty ? nil : draft
        let saved = text.isEmpty ? nil : draft.text
        let textChanged = savedDraftTexts[key] != saved
        savedDraftTexts[key] = saved
        let roomID = Self.roomID(ofDraftKey: key)
        if roomID != selectedRoomID { refreshDraftPreview(forRoom: roomID) }
        guard textChanged else { return }
        // Written out a moment later, once typing pauses.
        draftSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            UserDefaults.standard.set(self.savedDraftTexts, forKey: "drafts.\(self.id)")
        }
        draftSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// A voice message was recorded, sent or deleted in a composer: the room list says so.
    func voiceRecordingChanged(forDraftKey key: String) {
        refreshDraftPreview(forRoom: Self.roomID(ofDraftKey: key))
    }

    /// The room a draft's key is for: "room", or "room|thread root".
    private static func roomID(ofDraftKey key: String) -> String {
        key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? key
    }

    /// Works out again what a room's row says of its drafts: the room's own, or else one in a
    /// thread of it.
    private func refreshDraftPreview(forRoom roomID: String) {
        let voice = VoiceRecorder.shared.recordings
        let threadKeys = Set(savedDraftTexts.keys).union(drafts.keys).union(voice.keys)
            .filter { $0.hasPrefix(roomID + "|") }
            .sorted()
        // What was typed, or else a voice message recorded and not sent.
        func summary(_ key: String) -> String? {
            draft(for: key).flatMap(DraftPreview.summary) ?? (voice[key] != nil ? "Voice message" : nil)
        }
        var preview = summary(roomID).map { DraftPreview(text: $0, inThread: false) }
        if preview == nil {
            preview = threadKeys.lazy
                .compactMap(summary)
                .first
                .map { DraftPreview(text: $0, inThread: true) }
        }
        if draftPreviews[roomID] != preview { draftPreviews[roomID] = preview }
    }

    /// Who is typing in a room, by name, for its row in the room list.
    func typists(in roomID: String) -> RoomTypists {
        if let typists = roomTypists[roomID] { return typists }
        let typists = RoomTypists()
        roomTypists[roomID] = typists
        showTypists(typingUserIDs[roomID] ?? [], in: roomID)
        return typists
    }

    /// Names the room's typists for its row, if it has asked: by their names in the room where
    /// known, otherwise by user ID until the room has said.
    private func showTypists(_ userIDs: [String], in roomID: String) {
        guard let typists = roomTypists[roomID] else { return }
        let names = userIDs.map { contactNames[$0] ?? typistNames["\(roomID)|\($0)"] ?? $0.matrixLocalpart }
        if typists.names != names { typists.names = names }
        let unknown = userIDs.filter { typistNamesAsked.insert("\(roomID)|\($0)").inserted }
        guard !unknown.isEmpty, let room = roomHandles[roomID] else { return }
        Task { [weak self] in
            for userID in unknown {
                let name = (try? await room.memberDisplayName(userId: userID)) ?? nil
                self?.typistNames["\(roomID)|\(userID)"] = name ?? userID.matrixLocalpart
            }
            guard let self else { return }
            self.showTypists(self.typingUserIDs[roomID] ?? [], in: roomID)
        }
    }

    /// What every timeline of this account's needs to know of the account.
    private func prepared(_ timeline: RoomTimeline) -> RoomTimeline {
        timeline.sharesTyping = { [weak self] in self?.sharesTyping ?? false }
        timeline.contactName = { [weak self] in self?.contactNames[$0] }
        madeTimelines.add(timeline)
        return timeline
    }

    var allTimelines: [RoomTimeline] { madeTimelines.allObjects }

    /// Every room's summary made again, the user's names for people having changed.
    func refreshRoomSummaries() {
        for probe in probes.values { probe.namesChanged() }
        let handles = roomHandles
        let names = contactNames
        Task { [weak self] in
            var fresh: [String: RoomSummary] = [:]
            for (id, room) in handles { fresh[id] = await RoomSummary.make(from: room, names: names) }
            guard let self, names == self.contactNames else { return }
            var all = self.allRooms
            for index in all.indices {
                guard let summary = fresh[all[index].id] else { continue }
                // Only what names change: the rest stays as the list last had it.
                all[index].name = summary.name
                all[index].lastMessage = summary.lastMessage
                all[index].lastMessageInThread = summary.lastMessageInThread
            }
            self.allRooms = all
            self.rebuildSections()
        }
    }

    /// A fresh timeline for one thread. The caller owns it and stops it when done.
    func threadTimeline(roomID: String, root: String) -> RoomTimeline? {
        guard let room = room(id: roomID) else { return nil }
        let thread = prepared(RoomTimeline(room: room, threadRoot: root))
        thread.onRead = { [weak self] in self?.timelines[roomID]?.markThreadSeen(root) }
        return thread
    }

    // MARK: Read and unread

    /// Whether a room has anything unread, as the room list shows it.
    func isUnread(_ roomID: String) -> Bool {
        guard let room = rooms.first(where: { $0.id == roomID }) ?? allRooms.first(where: { $0.id == roomID })
        else { return false }
        return Self.isUnread(room)
    }

    /// Next Room and Previous Room: the room `step` along the list as it shows, round from one
    /// end to the other. Next Unread Room (`unreadOnly`) looks in folded sections too, so
    /// nothing unread is passed over, except a Low Priority room with only new messages, which
    /// the space's badge doesn't count either.
    func showRoom(step: Int, unreadOnly: Bool = false) {
        let showing = searchText.isEmpty ? sections.filter { !collapsedSections.contains($0.id) } : sections
        let list = unreadOnly ? rooms : showing.flatMap(\.rooms)
        guard !list.isEmpty, step != 0 else { return }
        let start = selectedRoomID.flatMap { id in list.firstIndex { $0.id == id } } ?? (step > 0 ? -1 : list.count)
        for distance in 1...list.count {
            let index = ((start + step * distance) % list.count + list.count) % list.count
            if !unreadOnly || (Self.isUnread(list[index]) && !list[index].isLowPriorityActivity) {
                if list[index].id != selectedRoomID { selectedRoomID = list[index].id }
                return
            }
        }
    }

    static func isUnread(_ room: RoomSummary) -> Bool {
        !room.isInvite && !room.isSpace && (room.hasUnread || room.notifications > 0 || room.mentions > 0)
    }

    /// Marks a room read up to its newest message, or unread, as the user asks. Shown in the
    /// list at once; the server's own record follows as it syncs.
    func setRoom(_ roomID: String, unread: Bool) {
        guard let room = room(id: roomID) else { return }
        if let index = allRooms.firstIndex(where: { $0.id == roomID }) {
            allRooms[index].hasUnread = unread
            allRooms[index].isMarkedUnread = unread
            if !unread {
                allRooms[index].notifications = 0
                allRooms[index].mentions = 0
                allRooms[index].hasNewMessages = false
            }
        }
        updateBadges()
        rebuildSections()
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

    /// Whether any of the account's rooms has anything unread, in any space or none.
    var hasUnreadRooms: Bool {
        allRooms.contains(where: Self.isUnread)
    }

    /// Marks every one of the account's rooms read.
    func markAllRead() {
        for room in allRooms where Self.isUnread(room) {
            setRoom(room.id, unread: false)
        }
    }

    /// A fresh timeline around one message, for showing it without loading the whole room's
    /// history up to it. The caller owns it and stops it when done.
    func focusedTimeline(roomID: String, eventID: String) -> RoomTimeline? {
        room(id: roomID).map { prepared(RoomTimeline(room: $0, focusedOn: eventID)) }
    }

    /// A fresh timeline of a room's pinned messages. The caller owns it and stops it when done.
    func pinnedTimeline(roomID: String) -> RoomTimeline? {
        room(id: roomID).map { prepared(RoomTimeline(room: $0, isPinnedList: true)) }
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

    @PerceptionIgnored private var bannerPinTimelines: [String: RoomTimeline] = [:]

    /// Sends a message's content, as it is, to another room.
    func forward(_ content: RoomMessageEventContentWithoutRelation, to roomID: String) async throws {
        guard let room = room(id: roomID) else { throw RoomError.unavailable }
        // The room's send queue takes it from here, as for anything typed in the room itself.
        room.enableSendQueue(enable: true)
        let timeline = try await room.timeline()
        _ = try await timeline.send(msg: content)
    }

    enum RoomError: LocalizedError {
        case unavailable
        var errorDescription: String? { "That room isn’t available." }
    }

    func threadList(roomID: String) -> RoomThreadList? {
        room(id: roomID).map { room in
            let list = RoomThreadList(room: room)
            list.contactName = { [weak self] in self?.contactNames[$0] }
            return list
        }
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
        for roomID in onScreen where probes[roomID] == nil && timelines[roomID] == nil && roomID != roomBeingIndexed {
            guard let room = room(id: roomID) else { continue }
            let probe = RoomPreviewProbe(room: room) { [weak self] preview in
                guard let self, self.timelines[roomID] == nil else { return }
                self.reactionPreviews[roomID] = preview
            } reportThreadReply: { [weak self] date in
                guard let self, self.timelines[roomID] == nil else { return }
                self.setThreadReplyDate(date, for: roomID)
            }
            probe.contactName = { [weak self] in self?.contactNames[$0] }
            probes[roomID] = probe
        }
    }

    private func setThreadReplyDate(_ date: Date?, for roomID: String) {
        if threadReplyDates[roomID] != date { threadReplyDates[roomID] = date }
    }

    /// Called when a room is left for another. A room whose loaded history has grown long (from
    /// scrolling back through it) is let go rather than kept warm: every message loaded is laid
    /// out each time the room is shown, so coming back to it would be slow. Opening it again
    /// starts from the local cache, which is quick, and earlier messages load as before.
    func roomWasLeft(_ roomID: String) {
        closedRooms.insert(roomID)
        guard let timeline = timelines[roomID], timeline.rows.count > Self.longestWarmTimeline else { return }
        timelines.removeValue(forKey: roomID)
        dropBannerPins(for: roomID)
        timelineOrder.removeAll { $0 == roomID }
        timeline.stop()
        updateSubscriptions()
    }

    private static let longestWarmTimeline = 150

    /// Notes where a room's conversation was as it closed: nil at its newest message.
    func keepReadingSpot(_ spot: ReadingSpot?, for roomID: String) {
        readingSpots[roomID] = spot
    }

    /// Readies a room to open where it was left, up its history, and gives the view to show it
    /// in, if it needs one. Called as the room's view is made (again and again while it is on
    /// screen: only the first time after the room was closed does anything). Its own timeline,
    /// kept warm, is told where, if it has that message among the newest it would draw to show
    /// it; otherwise (let go meanwhile, as one with a long history loaded is, or the message too
    /// far back) a view around the message is made, as for a search result.
    func returnView(for roomID: String) -> RoomTimeline? {
        if closedRooms.remove(roomID) != nil, returnViews[roomID] == nil,
           let spot = readingSpots.removeValue(forKey: roomID) {
            if let live = timelines[roomID], let index = live.rows.lastIndex(where: { $0.eventID == spot.eventID }),
               live.rows.endIndex - index <= Self.longestWarmTimeline {
                live.returnSpot = spot
            } else if let view = focusedTimeline(roomID: roomID, eventID: spot.eventID) {
                view.returnSpot = spot
                returnViews[roomID] = view
            }
        }
        return returnViews[roomID]
    }

    /// Another room was chosen before one readied to open where it was left had shown (the
    /// arrow keys going by it): its place is kept for next time, and a view made for it let go.
    private func forgetUnshownReturns() {
        for (roomID, timeline) in timelines where roomID != selectedRoomID {
            guard let spot = timeline.returnSpot else { continue }
            timeline.returnSpot = nil
            readingSpots[roomID] = spot
            closedRooms.insert(roomID)
        }
        for (roomID, view) in returnViews where roomID != selectedRoomID {
            returnViews[roomID] = nil
            if let spot = view.returnSpot { readingSpots[roomID] = spot }
            closedRooms.insert(roomID)
            view.stop()
        }
    }

    /// The room has taken its view to show; it stops it when done.
    @discardableResult
    func takeReturnView(for roomID: String) -> RoomTimeline? { returnViews.removeValue(forKey: roomID) }

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
        readingSpots[roomID] = nil
        dropBannerPins(for: roomID)
        if selectedRoomID == roomID { selectedRoomID = nil }
    }

    // MARK: Encryption

    func recover(with recoveryKey: String) async throws {
        try await client.encryption().recover(recoveryKey: recoveryKey)
    }
}

extension RoomSummary {
    /// - Parameter names: the user's own names for people (ContactNames.swift), for a direct
    ///   chat's name and whoever wrote the newest message.
    static func make(from room: Room, names: [String: String] = [:]) async -> RoomSummary {
        var summary = RoomSummary(id: room.id(), name: room.displayName() ?? room.id())
        // A direct chat with one other person: who wrote its newest message goes without saying.
        // One with more names them, as a room does (and as its notifications do).
        var isOneToOneChat = false
        if let info = try? await room.roomInfo() {
            isOneToOneChat = info.isDirect && info.joinedMembersCount <= 2
            summary.name = info.displayName ?? info.canonicalAlias ?? "Empty room"
            summary.avatarURL = info.avatarUrl
            summary.isDirect = info.isDirect
            summary.isInvite = info.membership == .invited
            summary.hasCounts = true
            summary.notifications = Int(info.numUnreadNotifications)
            summary.mentions = Int(info.numUnreadMentions)
            summary.hasUnread = info.numUnreadMessages > 0 || info.isMarkedUnread
            summary.isMarkedUnread = info.isMarkedUnread
            summary.hasNewMessages = info.numUnreadMessages > 0
            summary.isSpace = info.isSpace
            summary.isFavourite = info.isFavourite
            summary.isLowPriority = info.isLowPriority
            summary.isEncrypted = info.encryptionState == .encrypted
            summary.topic = info.topic.flatMap(RoomSummary.oneLine)
            summary.isOneToOne = info.activeMembersCount == 2
            summary.hasCall = info.hasRoomCall
            summary.callParticipantCount = info.activeRoomCallParticipants.count
            if info.isDirect, info.heroes.count == 1 {
                summary.directUserID = info.heroes[0].userId
                if summary.avatarURL == nil { summary.avatarURL = info.heroes[0].avatarUrl }
            }
            if let name = ContactRoomName.name(computed: info.displayName, hasOwnName: info.hasOwnName,
                                               isDirect: info.isDirect, heroes: info.heroes, names: names) {
                summary.name = name
            }
        }
        switch await room.latestEvent() {
        case .none:
            break
        case .remote(let timestamp, let sender, let isOwn, let profile, let content):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            let prefix = isOwn ? "You" : (isOneToOneChat ? nil : names[sender] ?? profile.name(fallback: sender))
            summary.lastMessage = content.preview(sender: prefix, contactName: { names[$0] })
            summary.lastMessageInThread = Self.inThread(prefix, content).flatMap { content.preview(sender: $0, contactName: { names[$0] }) }
        case .local(let timestamp, _, _, let content, _):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            summary.lastMessage = content.preview(sender: "You")
            summary.lastMessageInThread = Self.inThread("You", content).flatMap { content.preview(sender: $0) }
        case .remoteInvite(let timestamp, let inviter, let profile):
            summary.timestamp = Date(matrixTimestamp: timestamp)
            summary.lastMessage = inviter.map { "Invited by \(names[$0] ?? profile.name(fallback: $0))" } ?? "Invitation"
        }
        return summary
    }

    /// Who a message is from, said as a reply in a thread, as notifications say it: "Bob in a
    /// thread", or "In a thread" in a direct chat with one other person. Nil for an emote,
    /// worded around its sender, and for anything but a message.
    private static func inThread(_ sender: String?, _ content: TimelineItemContent) -> String? {
        guard case .msgLike(let message) = content else { return nil }
        if case .message(let body) = message.kind, case .emote = body.msgType { return nil }
        return sender.map { "\($0) in a thread" } ?? "In a thread"
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

/// A window shown over the main one for something to do with rooms and spaces.
enum AccountSheet: Identifiable, Equatable {
    case newMessage
    case newRoom(inSpace: String?)
    case newSpace
    case addRooms(toSpace: String)
    case leaveSpace(String)
    /// Inviting people to a room.
    case invite(roomID: String)
    /// The account's own name and picture.
    case profile
    case changePassword
    /// The devices signed in to the account.
    case devices
    /// Verifying this Mac, or answering a request to verify from elsewhere.
    case verify
    /// Setting up the recovery key, or changing it.
    case recoveryKey

    var id: String {
        switch self {
        case .newMessage: "newMessage"
        case .newRoom(let space): "newRoom-\(space ?? "")"
        case .newSpace: "newSpace"
        case .addRooms(let space): "addRooms-\(space)"
        case .leaveSpace(let space): "leaveSpace-\(space)"
        case .invite(let roomID): "invite-\(roomID)"
        case .profile: "profile"
        case .changePassword: "changePassword"
        case .devices: "devices"
        case .verify: "verify"
        case .recoveryKey: "recoveryKey"
        }
    }
}
