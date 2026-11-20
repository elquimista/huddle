import AppKit
import Foundation
import MatrixRustSDK
import Observation

struct TimelineRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case message(MessageRow)
        case notice(String)
        case dateDivider(Date)
        case readMarker
    }

    let id: String
    var kind: Kind

    /// The server's ID for the message in this row, if it is one that has been sent.
    var eventID: String? {
        if case .message(let message) = kind { return message.eventID }
        return nil
    }

    var isMessage: Bool {
        if case .message = kind { return true }
        return false
    }

    var message: MessageRow? {
        if case .message(let message) = kind { return message }
        return nil
    }

    var messageDate: Date? {
        if case .message(let message) = kind { return message.date }
        return nil
    }
}

struct MessageRow: Equatable {
    enum Body: Equatable {
        case text(String)
        case emote(String)
        case image(ImageAttachment)
        case audio(AudioAttachment)
        /// A document, archive, video or other file, shown as a tile to open or save.
        case file(FileAttachment)
        case attachment(icon: String, name: String)
        /// Not decrypted: waiting for its keys (nil), or never to be, and why.
        case undecryptable(String?)
        case redacted
        case unsupported(String)
    }

    enum SendState: Equatable {
        /// Queued behind another attachment that is still uploading.
        case waiting
        case sending
        case failed
    }

    enum Delivery: Equatable { case sending, sent, read }

    struct RawReceipt: Equatable {
        var userID: String
        var date: Date?
    }

    struct Reader: Equatable, Identifiable {
        let id: String
        var name: String
        var avatarURL: String?
        var date: Date?
    }

    struct ReactionChip: Equatable, Identifiable {
        var key: String
        var count: Int
        var isOwn: Bool
        /// Everyone who reacted this way, earliest first.
        var senders: [String] = []
        /// Who added this reaction most recently, and when.
        var latestSender: String?
        var latestDate: Date?
        var id: String { key }
    }

    var itemID: EventOrTransactionId
    /// The server's event ID, once the message has been sent. Threads hang off this.
    var eventID: String? {
        if case .eventId(let id) = itemID { return id }
        return nil
    }
    var sender: String
    var senderName: String
    var senderAvatarURL: String?
    var isOwn: Bool
    var date: Date
    var body: Body
    var isEdited = false
    /// Whether the SDK will let this account change the message: its own text, or a caption.
    var isEditable = false
    /// Whether the message is one of the room's pinned messages.
    var isPinned = false
    var reactions: [ReactionChip] = []
    var sendState: SendState?
    /// Present on a message that has thread replies.
    var thread: ThreadInfo?
    /// Read receipts placed on this message, as the SDK reports them. Resolved into `readers`.
    var receipts: [RawReceipt] = []
    /// The sender's HTML formatting for a text message, if their client sent any.
    var html: String?
    var mentionsRoom = false
    /// The message this one answers, if it is a reply.
    var replyTo: ReplyPreview?
    /// While an attachment is being sent: how much has been uploaded, from 0 to 1, if known.
    var uploadProgress: Double?
    /// A doubt about who really sent it, in an encrypted room: from a device its owner hasn't
    /// verified, say. Nil when there's nothing to say.
    var shield: Shield?
    /// Why it couldn't be sent, when the SDK says something worth passing on.
    var sendFailure: String?
    /// For an image waiting its turn to upload: the picture to show, since there is nothing
    /// to load yet.
    var localPreview: NSImage?
    /// Group rooms: other people whose latest read message is this one, most recent first.
    var readers: [Reader] = []
    /// Your own messages: how far this one has got. Nil when no indicator should show.
    var delivery: Delivery?
    /// For a read message: when it is known to have been read. Exact if the receipt sits on
    /// this message; otherwise the time of the later receipt or reply that covers it.
    var readDate: Date?
    var readDateIsExact = false
    /// False when this message continues a run from the same sender.
    var showsHeader = true
    /// False when the next message continues this one's run: the bubble layout puts the
    /// sender's avatar, and a bubble's tail, on the last of a run.
    var endsRun = true
    /// The first message after a quarter of an hour or more without any: the bubble layout
    /// says the time above it.
    var startsAfterPause = true
}

/// Summary of the thread hanging off a message, shown under it in the room.
struct ThreadInfo: Equatable {
    var replyCount: Int
    /// Someone else has replied since you last looked at this thread or read the room.
    var hasNewReplies = false
    var latestSender: String?
    var latestSenderName: String?
    var latestSenderAvatarURL: String?
    var latestDate: Date?

    init?(_ summary: ThreadSummary?) {
        guard let summary, summary.numReplies() > 0 else { return nil }
        replyCount = Int(summary.numReplies())
        if case .ready(_, let sender, let profile, let timestamp, _) = summary.latestEvent() {
            latestSender = sender
            latestSenderName = profile.name(fallback: sender)
            latestSenderAvatarURL = profile.avatarURL
            latestDate = Date(matrixTimestamp: timestamp)
        }
    }
}

/// Equatable wrapper around the SDK's reference-typed media source.
struct MediaRef: Equatable {
    let source: MediaSource
    static func == (lhs: MediaRef, rhs: MediaRef) -> Bool { lhs.source.url() == rhs.source.url() }
}

/// Live, paginated view of one room's events, or of a single thread within it.
/// A reaction newer than a room's newest message, worded for the room list.
struct ReactionPreview: Equatable {
    var text: String
    var date: Date

    /// The newest reaction among these messages, if it came after the newest of them.
    @MainActor
    static func newest(in rows: [TimelineRow], ownUserID: String, name: @escaping (String) -> String?) -> ReactionPreview? {
        var newest: ReactionPreview?
        var lastMessageDate = Date.distantPast
        for row in rows {
            guard case .message(let message) = row.kind else { continue }
            lastMessageDate = max(lastMessageDate, message.date)
            for reaction in message.reactions {
                guard let sender = reaction.latestSender, let date = reaction.latestDate,
                      date > (newest?.date ?? .distantPast) else { continue }
                let target: String
                switch message.body {
                case .text(let text), .emote(let text):
                    let plain = MessageFormatter.plainText(
                        text: text, formatted: message.html.map { FormattedBody(format: .html, body: $0) }, name: name)
                    target = "“\(plain.prefix(60))”"
                case .image(let image): target = image.isSticker ? "a sticker" : (image.filename.isEmpty ? "an image" : image.filename)
                case .audio(let audio): target = audio.isVoice ? "a voice message" : audio.filename
                case .file(let file): target = file.filename
                case .attachment(_, let name): target = name
                default: target = "a message"
                }
                let who = sender == ownUserID ? "You" : (name(sender) ?? sender.matrixLocalpart)
                newest = ReactionPreview(text: "\(who) reacted \(reaction.key) to \(target)", date: date)
            }
        }
        if let found = newest, found.date <= lastMessageDate { return nil }
        return newest
    }
}

extension String {
    /// "alice" from "@alice:example.org".
    var matrixLocalpart: String {
        guard hasPrefix("@"), let colon = firstIndex(of: ":") else { return self }
        return String(self[index(after: startIndex)..<colon])
    }

    /// "example.org" from "@alice:example.org": the server, with any port.
    var matrixServer: String {
        guard let colon = firstIndex(of: ":") else { return self }
        return String(self[index(after: colon)...])
    }
}

@MainActor @Observable
final class RoomTimeline {
    let room: Room
    let roomID: String
    /// Set for a thread's timeline: the root message's event ID.
    let threadRoot: String?
    /// True for the timeline of the room's pinned messages, which is only read, never sent to.
    let isPinnedList: Bool
    /// Set for a timeline around one message far back in the room, opened to show it without
    /// loading everything since: that message's event ID.
    let focusedEvent: String?
    /// The room's own conversation as it is now, rather than a thread, the pinned messages, or
    /// a stretch around an older message.
    var isLive: Bool { threadRoot == nil && !isPinnedList && focusedEvent == nil }
    /// Focused timeline only: whether there are newer messages still to load before the present.
    private(set) var hasMoreNewer = true
    /// Focused timeline only: counts finished requests for newer messages.
    private(set) var newerRequests = 0
    @ObservationIgnored private var isPaginatingForwards = false
    /// Set when the user marks the room unread while it is open: it stays unread (nothing is
    /// marked read, here or on leaving) until it is opened again or they write in it.
    @ObservationIgnored var holdsUnread = false
    /// Changes whenever a name is learned, so text naming people by their ID is drawn again.
    @ObservationIgnored private(set) var nameVersion = 0
    /// The room's pinned messages, by event ID, in the order they were pinned (oldest first).
    private(set) var pinnedEventIDs: [String] = []
    /// What this account may do to messages here.
    private(set) var permissions = TimelinePermissions()
    /// Whether the room is encrypted; if not, whether it's public, where that's usual.
    private(set) var encryption: RoomEncryption = .unknown
    /// A message another view wants this one to go to and light up, such as one picked from
    /// the pinned messages in the side panel. Cleared once it has been dealt with.
    var requestedJump: String?
    private(set) var rows: [TimelineRow] = []
    private(set) var isLoading = true
    private(set) var hasMoreHistory = true
    private(set) var isPaginating = false
    /// Counts finished history requests, so the view can ask again while its spinner is visible.
    private(set) var historyRequests = 0
    /// Set whenever older messages are inserted above `prependAnchorID`.
    private(set) var prependCount = 0
    private(set) var prependAnchorID: String?
    private(set) var error: String?

    @ObservationIgnored private var timeline: Timeline?
    @ObservationIgnored private var items: [TimelineItem] = []
    @ObservationIgnored private var listenerHandle: TaskHandle?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private(set) var ownUserID: String
    /// Room timeline only. Replies newer than this are new: when you had last marked the room
    /// read, as of opening it.
    @ObservationIgnored private var unreadHorizon: Date?
    /// Room timeline only. When each thread was last read here, by root event ID.
    @ObservationIgnored private var threadSeen: [String: Date] = [:]
    /// Live room timeline only. The room's threads, most recently active first, followed so a
    /// reply to one whose root is far back, or not loaded at all, is known about.
    @ObservationIgnored private var threadActivity: RoomThreadList?
    /// Live room timeline only. Threads someone else has replied to since you last read the
    /// room or the thread, most recently active first.
    private(set) var newThreads: [ThreadListEntry] = []
    /// Live room timeline only. Told the date of the newest reply in any thread, so the room
    /// list can say when the room's newest message is one.
    @ObservationIgnored var onLatestThreadReply: ((Date?) -> Void)?
    /// Thread timeline only. Tells the room's timeline that this thread has been read.
    /// Everyone else in the room, for mention suggestions. Empty until `loadMembers()`.
    private(set) var members: [MentionCandidate] = []
    @ObservationIgnored private var membersRequested = false
    @ObservationIgnored private var requestedReplyDetails: Set<String> = []
    @ObservationIgnored private var imageQueue: [QueuedImage] = []
    @ObservationIgnored private var imageQueueTask: Task<Void, Never>?
    /// The queued image just given to the SDK, and which unsent image rows existed before it.
    @ObservationIgnored private var handover: (id: UUID, before: Set<String>)?
    @ObservationIgnored var onRead: (() -> Void)?
    @ObservationIgnored var onLatestReaction: ((ReactionPreview?) -> Void)?
    @ObservationIgnored private var latestReaction: ReactionPreview?
    @ObservationIgnored private var lastRoomReceipt: String?
    /// A two-person direct chat shows ticks on your messages; other rooms show who has read.
    @ObservationIgnored private(set) var isOneToOne = false
    /// Just two people in the room, direct chat or not: a call there is one person calling the other.
    @ObservationIgnored private var hasTwoPeople = false
    /// One-to-one calls' events met so far, by event ID: read once each from the event itself.
    @ObservationIgnored private var callEvents: [String: CallEvent] = [:]
    /// Names and avatars for read receipts, learned from messages and fetched for the rest.
    @ObservationIgnored private var profiles: [String: (name: String, avatarURL: String?)] = [:]
    @ObservationIgnored private var requestedProfiles: Set<String> = []
    @ObservationIgnored private var infoHandle: TaskHandle?
    @ObservationIgnored private var infoTask: Task<Void, Never>?
    /// Room timeline only: members whose identity changed, as the room's identity stream says.
    private(set) var identityWarnings: [IdentityWarning] = []
    @ObservationIgnored private var identityStates: [String: IdentityState] = [:]
    @ObservationIgnored private var identityHandle: TaskHandle?
    @ObservationIgnored private var identityTask: Task<Void, Never>?
    /// Told of each change to a member's identity, so what is known of who is verified follows.
    @ObservationIgnored var onIdentityChanges: (([IdentityStatusChange]) -> Void)?
    /// Room timeline only: who else is writing a message here now, as the account hears it.
    private(set) var typists: [Typist] = []
    @ObservationIgnored private var typingUserIDs: [String] = []
    /// While this account is said to be typing here: when the user last typed.
    @ObservationIgnored private var lastKeystroke: Date?
    /// Keeps saying this account is typing, until the user stops.
    @ObservationIgnored private var typingKeeper: Task<Void, Never>?
    /// Whether the account shares when it's typing. Nothing is said until the account says so.
    @ObservationIgnored var sharesTyping: () -> Bool = { false }
    /// The typing notices sent so far, each after the one before, so the room hears them in order.
    @ObservationIgnored private var typingNotice: Task<Void, Never>?

    init(room: Room, threadRoot: String? = nil, isPinnedList: Bool = false, focusedOn focusedEvent: String? = nil) {
        self.room = room
        roomID = room.id()
        self.threadRoot = threadRoot
        self.isPinnedList = isPinnedList
        self.focusedEvent = focusedEvent
        ownUserID = room.ownUserId()
        updatesTask = Task { [weak self] in await self?.run() }
        infoTask = Task { [weak self] in await self?.followRoomInfo() }
        if isLive { identityTask = Task { [weak self] in await self?.followIdentityChanges() } }
    }

    private var hasReadToEnd = false

    func stop() {
        imageQueueTask?.cancel()
        updatesTask?.cancel()
        listenerHandle?.cancel()
        infoTask?.cancel()
        infoHandle?.cancel()
        identityTask?.cancel()
        identityHandle?.cancel()
        typingKeeper?.cancel()
        threadActivity?.stop()
    }

    /// Follows the members whose identity changed since it was first seen, or since they were
    /// verified. The first update is how things stand; later ones change single members.
    private func followIdentityChanges() async {
        let (stream, continuation) = AsyncStream.makeStream(of: [IdentityStatusChange].self)
        guard let handle = try? await room.subscribeToIdentityStatusChanges(
            listener: IdentityChangeObserver { continuation.yield($0) }) else { return }
        identityHandle = handle
        for await changes in stream {
            guard !Task.isCancelled else { break }
            for change in changes { identityStates[change.userId] = change.changedTo }
            updateIdentityWarnings()
            onIdentityChanges?(changes)
        }
    }

    private func updateIdentityWarnings() {
        identityWarnings = identityStates.compactMap { userID, state -> IdentityWarning? in
            switch state {
            case .pinViolation: IdentityWarning(userID: userID, name: displayName(for: userID), wasVerified: false)
            case .verificationViolation: IdentityWarning(userID: userID, name: displayName(for: userID), wasVerified: true)
            case .pinned, .verified: nil
            }
        }
        // The ones that undo a verification first, then by name.
        .sorted { ($0.wasVerified ? 0 : 1, $0.name) < ($1.wasVerified ? 0 : 1, $1.name) }
    }

    /// Who else is typing here, from the account, which follows every room.
    func setTypingUserIDs(_ userIDs: [String]) {
        typingUserIDs = userIDs
        updateTypists()
    }

    private func updateTypists() {
        let typists = typingUserIDs.map { userID in
            Typist(userID: userID, name: displayName(for: userID), avatarURL: profiles[userID]?.avatarURL)
        }
        if typists != self.typists { self.typists = typists }
    }

    /// Tells the room whether this account is writing a message (for each keystroke, or when
    /// the message is sent or cleared), if the user shares that.
    func setTyping(_ isTyping: Bool) {
        if isTyping {
            guard sharesTyping(), !isPinnedList else { return }
            lastKeystroke = .now
            if typingKeeper == nil { typingKeeper = Task { [weak self] in await self?.keepTyping() } }
        } else if let keeper = typingKeeper {
            keeper.cancel()
            typingKeeper = nil
            lastKeystroke = nil
            sendTypingNotice(false)
        }
    }

    /// The room forgets that someone is typing after four seconds, and the SDK says it again
    /// only once three have passed: so it's said every 3.4 seconds, without gaps, until the user
    /// has stopped for a few seconds; then that they stopped.
    private func keepTyping() async {
        while !Task.isCancelled, sharesTyping(),
              let last = lastKeystroke, Date.now.timeIntervalSince(last) < 4 {
            sendTypingNotice(true)
            try? await Task.sleep(for: .seconds(3.4))
        }
        guard !Task.isCancelled else { return }
        typingKeeper = nil
        lastKeystroke = nil
        sendTypingNotice(false)
    }

    private func sendTypingNotice(_ isTyping: Bool) {
        let previous = typingNotice
        typingNotice = Task { [room] in
            await previous?.value
            try? await room.typingNotice(isTyping: isTyping)
        }
    }

    /// Keeps the pinned messages and this account's permissions up to date.
    private func followRoomInfo() async {
        if let info = try? await room.roomInfo() { apply(info) }
        let (stream, continuation) = AsyncStream.makeStream(of: RoomInfo.self)
        infoHandle = room.subscribeToRoomInfoUpdates(listener: RoomInfoObserver { continuation.yield($0) })
        for await info in stream {
            guard !Task.isCancelled else { break }
            apply(info)
        }
    }

    private func apply(_ info: RoomInfo) {
        let encryption: RoomEncryption = switch info.encryptionState {
        case .encrypted: .encrypted
        case .notEncrypted: .notEncrypted(isPublic: info.isPublic == true)
        case .unknown: .unknown
        }
        if encryption != self.encryption { self.encryption = encryption }
        let permissions = info.powerLevels.map(TimelinePermissions.init) ?? self.permissions
        guard info.pinnedEventIds != pinnedEventIDs || permissions != self.permissions else { return }
        pinnedEventIDs = info.pinnedEventIds
        self.permissions = permissions
        rebuildRows()
    }

    private func run() async {
        do {
            // The room's own timeline leaves thread replies out; a thread's timeline is its root
            // message followed by its replies, and sends into that thread.
            let focus: TimelineFocus
            if isPinnedList {
                focus = .pinnedEvents
            } else if let focusedEvent {
                focus = .event(eventId: focusedEvent, numContextEvents: 40,
                               threadMode: .automatic(hideThreadedEvents: true))
            } else {
                focus = threadRoot.map { .thread(rootEventId: $0) } ?? .live(hideThreadedEvents: true)
            }
            let timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
                focus: focus,
                filter: .all,
                internalIdPrefix: nil,
                dateDividerMode: .daily,
                trackReadReceipts: .messageLikeEvents,
                reportUtds: false))
            self.timeline = timeline
            let (stream, continuation) = AsyncStream.makeStream(of: [TimelineDiff].self)
            listenerHandle = await timeline.addListener(listener: TimelineDiffListener { continuation.yield($0) })
            if isLive {
                unreadHorizon = await lastReadTime()
                followThreads()
            }
            let isDirect = await room.isDirect()
            isOneToOne = isDirect && room.activeMembersCount() <= 2
            hasTwoPeople = room.activeMembersCount() <= 2
            refreshNameColors()
            isLoading = false
            for await diffs in stream {
                for diff in diffs { items.apply(diff.diff) }
                rebuildRows()
                refreshNameColors()
            }
        } catch {
            self.error = error.actionMessage
            isLoading = false
        }
    }

    /// When this user last marked the room read, from their read receipts. Thread replies sent
    /// after this are new. Falls back to now, so a room never read doesn't flag every thread.
    private func lastReadTime() async -> Date {
        var latest: Timestamp = 0
        for thread in [ReceiptThread.unthreaded, .main] {
            let receipt = try? await room.loadUserReceipt(receiptType: .read, thread: thread, userId: ownUserID)
            latest = max(latest, receipt?.receipt.timestamp ?? 0)
        }
        return latest > 0 ? Date(matrixTimestamp: latest) : .now
    }

    /// A call event, read from the event the first time it's met.
    private func callEvent(_ kind: CallEvent.Kind, _ event: EventTimelineItem) -> CallEvent {
        guard case .eventId(let eventID) = event.eventOrTransactionId else { return CallEvent(kind: kind, event: event) }
        if let known = callEvents[eventID] { return known }
        let callEvent = CallEvent(kind: kind, event: event)
        callEvents[eventID] = callEvent
        return callEvent
    }

    private func rebuildRows() {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(items.count)
        var previous: MessageRow?
        var lastMessageDate: Date?
        let pinned = Set(pinnedEventIDs)
        // How each one-to-one call went, for its line: from its answer, decline and end, which
        // aren't shown themselves.
        // Rows of this account's own doing, which a read marker isn't about.
        var ownRows: Set<String> = []
        let callOutcomes = CallHistory.outcomes(of: items.compactMap { item in
            guard let event = item.asEvent(), let kind = CallEvent.kind(of: event.content), kind != .invite else { return nil }
            return callEvent(kind, event)
        })
        for item in items {
            let id = item.uniqueId().id
            if let event = item.asEvent() {
                if event.isOwn { ownRows.insert(id) }
                if let kind = CallEvent.kind(of: event.content) {
                    guard kind == .invite else { continue }
                    let invite = callEvent(.invite, event)
                    previous = nil
                    rows.append(TimelineRow(id: id, kind: .notice(CallHistory.line(
                        for: invite, outcome: invite.callID.flatMap { callOutcomes[$0] },
                        callerName: contactName(event.sender) ?? event.senderProfile.name(fallback: event.sender), isOwn: event.isOwn,
                        ownUserID: ownUserID))))
                    continue
                }
                if case .rtcNotification(_, let declinedBy, let activeMembers, _, _) = event.content {
                    previous = nil
                    rows.append(TimelineRow(id: id, kind: .notice(CallHistory.line(
                        callerName: contactName(event.sender) ?? event.senderProfile.name(fallback: event.sender), isOwn: event.isOwn,
                        isOneToOne: hasTwoPeople, declinedBy: declinedBy, activeMembers: activeMembers,
                        ownUserID: ownUserID))))
                    continue
                }
                switch TimelineRow.Kind(event: event, ownUserID: ownUserID, name: displayName(for:), contactName: contactName) {
                case .message(var message):
                    // The user's own names for whoever a reply quotes, and the newest in a thread.
                    if let sender = message.replyTo?.sender, let name = contactName(sender) { message.replyTo?.senderName = name }
                    if let sender = message.thread?.latestSender, let name = contactName(sender) { message.thread?.latestSenderName = name }
                    message.isPinned = message.eventID.map(pinned.contains) ?? false
                    if let previous, previous.sender == message.sender,
                       message.date.timeIntervalSince(previous.date) < 300 {
                        message.showsHeader = false
                        Self.continueRun(in: &rows)
                    }
                    message.startsAfterPause = lastMessageDate.map { message.date.timeIntervalSince($0) >= 900 } ?? true
                    lastMessageDate = message.date
                    previous = message
                    rows.append(TimelineRow(id: id, kind: .message(message)))
                case .notice(let text)?:
                    previous = nil
                    // Pinning several messages in a row reads as one line: "pinned 3 messages".
                    if let pin = PinNotice(text), let last = rows.last, case .notice(let lastText) = last.kind,
                       let earlier = PinNotice(lastText), earlier.who == pin.who, earlier.verb == pin.verb {
                        rows[rows.count - 1].kind = .notice(PinNotice(who: pin.who, verb: pin.verb,
                                                                      count: earlier.count + pin.count).text)
                    } else {
                        rows.append(TimelineRow(id: id, kind: .notice(text)))
                    }
                case let other?:
                    previous = nil
                    rows.append(TimelineRow(id: id, kind: other))
                case nil:
                    break
                }
            } else if let virtual = item.asVirtual() {
                previous = nil
                switch virtual {
                case .dateDivider(let ts):
                    rows.append(TimelineRow(id: id, kind: .dateDivider(Date(matrixTimestamp: ts))))
                case .readMarker:
                    rows.append(TimelineRow(id: id, kind: .readMarker))
                case .timelineStart:
                    hasMoreHistory = false
                }
            }
        }
        appendQueuedImages(to: &rows, after: previous)

        // A thread's history ends at its root message.
        if let threadRoot, let first = rows.first(where: \.isMessage),
           case .message(let message) = first.kind, message.eventID == threadRoot {
            hasMoreHistory = false
        }
        // A read marker with nothing new under it is noise. What followed it may be hidden here
        // (thread replies, reactions, a call's end), leaving only date dividers, nothing at all,
        // or only what this account did itself.
        if let marker = rows.lastIndex(where: { if case .readMarker = $0.kind { true } else { false } }),
           !rows[(marker + 1)...].contains(where: { row in
               if case .dateDivider = row.kind { return false }
               return !ownRows.contains(row.id)
           }) {
            rows.remove(at: marker)
        }
        // A date with nothing under it, every event of that day being one not shown (a call's
        // end just after midnight, say).
        rows = rows.indices.compactMap { index in
            guard case .dateDivider = rows[index].kind else { return rows[index] }
            let next = rows[(index + 1)...].first { if case .readMarker = $0.kind { false } else { true } }
            guard let next else { return nil }
            if case .dateDivider = next.kind { return nil }
            return rows[index]
        }

        if threadRoot == nil, !isPinnedList {
            for index in rows.indices {
                guard case .message(var message) = rows[index].kind, var thread = message.thread,
                      let root = message.eventID, let latest = thread.latestDate else { continue }
                thread.hasNewReplies = isNew(thread: root, latestReply: latest,
                                             fromOthers: thread.latestSender != ownUserID)
                message.thread = thread
                rows[index].kind = .message(message)
            }
        }

        resolveReceipts(in: &rows)

        // Detect history landing above what was the oldest message, so the view can hold its place.
        let oldFirst = self.rows.first(where: \.isMessage)?.id
        let newFirst = rows.first(where: \.isMessage)?.id
        self.rows = rows
        if isLive { updateLatestReaction() }
        if let oldFirst, oldFirst != newFirst, rows.contains(where: { $0.id == oldFirst }) {
            prependAnchorID = oldFirst
            prependCount += 1
        }
        fetchMissingReplyDetails()
    }

    /// A reply names the message it answers; if that message isn't among the loaded ones, the
    /// SDK has to be asked for it. Once per reply: the answer arrives as a timeline update.
    private func fetchMissingReplyDetails() {
        guard let timeline else { return }
        for row in rows {
            guard case .message(let message) = row.kind, message.replyTo?.needsFetch == true,
                  let eventID = message.eventID, requestedReplyDetails.insert(eventID).inserted else { continue }
            Task { try? await timeline.fetchDetailsForEvent(eventId: eventID) }
        }
    }

    /// The row showing a message, loading older history until it turns up. Nil if it isn't
    /// within a few hundred messages of what is loaded.
    func rowID(forEvent eventID: String) async -> String? {
        let limit = rows.count + 600
        for _ in 0..<60 {
            if let row = rows.first(where: { $0.eventID == eventID }) { return row.id }
            guard hasMoreHistory, rows.count < limit, !Task.isCancelled else { return nil }
            await loadOlder()
            // The loaded messages reach `rows` through the update stream, a moment later.
            try? await Task.sleep(for: .milliseconds(120))
        }
        return rows.first(where: { $0.eventID == eventID })?.id
    }

    /// A person's display name, if this timeline has come across it.
    func knownName(for userID: String) -> String? { contactName(userID) ?? profiles[userID]?.name }

    /// The user's own name for someone (ContactNames.swift), set by the account.
    @ObservationIgnored var contactName: (String) -> String? = { _ in nil }

    /// The user's names for people changed: everything naming them, drawn again.
    func namesChanged() {
        nameVersion += 1
        rebuildRows()
    }

    /// The newest reaction, if it came after the newest message: the room list shows it as the
    /// room's latest activity.
    private func updateLatestReaction() {
        let newest = ReactionPreview.newest(in: rows, ownUserID: ownUserID, name: { [profiles, contactName] in contactName($0) ?? profiles[$0]?.name })
        if newest != latestReaction {
            latestReaction = newest
            onLatestReaction?(newest)
        }
    }

    /// Turns raw receipts into what each message shows: reader avatars in group rooms, and a
    /// sending / sent / read state on your own messages.
    private func resolveReceipts(in rows: inout [TimelineRow]) {
        for row in rows {
            if case .message(let message) = row.kind, profiles[message.sender] == nil {
                profiles[message.sender] = (message.senderName, message.senderAvatarURL)
                nameVersion += 1
            }
        }

        var readByOthers = false      // someone else has read this message or a later one
        var passedLatestOwn = false
        var evidenceDate: Date?       // when the nearest later receipt or reply happened
        for index in rows.indices.reversed() {
            guard case .message(var message) = rows[index].kind else { continue }
            let others = message.receipts
                .filter { $0.userID != ownUserID }
                .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            // Replying is reading: a later message from someone else covers everything before it.
            if !others.isEmpty || !message.isOwn { readByOthers = true }
            if let receiptDate = others.first?.date {
                evidenceDate = receiptDate
            } else if !message.isOwn {
                evidenceDate = message.date
            }
            message.readDate = message.isOwn && readByOthers ? evidenceDate : nil
            message.readDateIsExact = !others.isEmpty

            message.readers = isOneToOne ? [] : others.map(reader(for:))

            if !message.isOwn || message.sendState == .failed {
                message.delivery = nil
            } else if message.sendState == .sending || message.sendState == .waiting {
                message.delivery = .sending
            } else if isOneToOne {
                message.delivery = readByOthers ? .read : .sent
            } else {
                // In a group the avatars say who has read; only the newest message of yours
                // needs a "sent" tick, and only until someone reads it.
                message.delivery = !passedLatestOwn && message.readers.isEmpty ? .sent : nil
            }
            if message.isOwn { passedLatestOwn = true }
            rows[index].kind = .message(message)
        }
    }

    private func reader(for receipt: MessageRow.RawReceipt) -> MessageRow.Reader {
        let userID = receipt.userID
        if let profile = profiles[userID] {
            return .init(id: userID, name: contactName(userID) ?? profile.name, avatarURL: profile.avatarURL, date: receipt.date)
        }
        requestProfile(userID)
        return .init(id: userID, name: userID, avatarURL: nil, date: receipt.date)
    }

    /// A person's name for a line in the timeline (a role change): known already, or fetched,
    /// with the rows rebuilt when it arrives and their Matrix ID's local part meanwhile.
    private func displayName(for userID: String) -> String {
        if let name = contactName(userID) { return name }
        if let profile = profiles[userID] { return profile.name }
        requestProfile(userID)
        return userID.matrixLocalpart
    }

    /// Asks the room for someone's name and picture, once, rebuilding the rows when they come.
    private func requestProfile(_ userID: String) {
        guard requestedProfiles.insert(userID).inserted else { return }
        Task { [weak self, room] in
            let name = try? await room.memberDisplayName(userId: userID)
            let avatar = try? await room.memberAvatarUrl(userId: userID)
            guard let self else { return }
            self.profiles[userID] = (name ?? userID, avatar ?? nil)
            self.nameVersion += 1
            self.rebuildRows()
            if self.identityStates[userID] != nil { self.updateIdentityWarnings() }
            if self.typingUserIDs.contains(userID) { self.updateTypists() }
        }
    }

    // MARK: Actions

    func loadOlder() async {
        guard let timeline, hasMoreHistory, !isPaginating else { return }
        isPaginating = true
        defer {
            isPaginating = false
            historyRequests += 1
        }
        do {
            if try await timeline.paginateBackwards(numEvents: 40) {
                hasMoreHistory = false
            }
        } catch {
            self.error = error.actionMessage
        }
    }

    /// Focused timeline: loads the next newer messages. Returns true once the present is reached.
    @discardableResult
    func loadNewer() async -> Bool {
        guard let timeline, focusedEvent != nil, hasMoreNewer, !isPaginatingForwards else { return !hasMoreNewer }
        isPaginatingForwards = true
        defer {
            isPaginatingForwards = false
            newerRequests += 1
        }
        do {
            if try await timeline.paginateForwards(numEvents: 40) { hasMoreNewer = false }
        } catch {
            self.error = error.actionMessage
        }
        return !hasMoreNewer
    }

    /// Loads the room's members for mention suggestions, once.
    /// How many people were in the room when names' colours were last worked out.
    @ObservationIgnored private var nameColorMembers: Int?

    /// Works out names' colours for a room of up to six again (NameColors), when the number of
    /// people in it has changed: someone joined or left.
    private func refreshNameColors() {
        let count = Int(room.activeMembersCount())
        guard count != nameColorMembers else { return }
        nameColorMembers = count
        let room = room
        let roomID = roomID
        Task {
            var joined: [String] = []
            if count <= NameColors.largestRoom, let iterator = try? await room.members() {
                while let chunk = iterator.nextChunk(chunkSize: 50) {
                    joined += chunk.filter { $0.membership == .join }.map(\.userId)
                }
            }
            // A bigger room, with none: Element's colours as they are.
            NameColors.shared.setMembers(joined, ofRoom: roomID)
        }
    }

    func loadMembers() async {
        guard !membersRequested else { return }
        membersRequested = true
        guard let iterator = try? await room.members() else {
            membersRequested = false
            return
        }
        var found: [MentionCandidate] = []
        while let chunk = iterator.nextChunk(chunkSize: 500) {
            for member in chunk where member.membership == .join && member.userId != ownUserID {
                found.append(MentionCandidate(id: member.userId,
                                              name: member.displayName ?? member.userId.matrixLocalpart,
                                              avatarURL: member.avatarUrl))
                if profiles[member.userId] == nil, let name = member.displayName {
                    profiles[member.userId] = (name, member.avatarUrl)
                    nameVersion += 1
                }
            }
        }
        members = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// - Parameter replyTo: the event this message answers, to send it as a reply.
    func send(_ text: String, mentions: [ComposedMention] = [], replyTo: String? = nil) async {
        guard let timeline else { return }
        do {
            let content = MentionComposer.content(for: text, mentions: mentions)
            if let replyTo {
                // The SDK adds the relation, mentions the person replied to, and keeps a reply
                // made inside a thread in that thread.
                _ = try await timeline.sendReply(msg: content, eventId: replyTo)
            } else {
                _ = try await timeline.send(msg: content)
            }
            error = nil
            // Having answered, the user is caught up: nothing above is "new" any more, and a
            // room they had marked unread has been dealt with.
            if isLive {
                holdsUnread = false
                try? await timeline.markAsRead(receiptType: .fullyRead)
            }
        } catch {
            self.error = error.actionMessage
        }
    }

    // MARK: Images

    /// An image waiting its turn to be uploaded.
    private struct QueuedImage {
        let id = UUID()
        let queuedAt = Date()
        let item: StagedAttachment
        let caption: (plain: String, html: String?, mentions: Mentions?)?
        let replyTo: String?

        /// What its row shows until the SDK's own row for it takes over.
        var body: MessageRow.Body {
            switch item {
            case .image(let image): .image(ImageAttachment(staged: image, caption: caption?.plain, id: id))
            case .file(let file): .file(FileAttachment(staged: file, caption: caption?.plain))
            }
        }

        var preview: NSImage? {
            if case .image(let image) = item { image.preview } else { nil }
        }
    }

    /// Something waiting in the composer to be sent: a picture, or any other file.
    enum StagedAttachment {
        case image(StagedImage)
        case file(StagedFile)
    }

    private static let queuedPrefix = "queued-"

    /// Sends pictures and files, each as a message of its own, in the order given. The caption,
    /// and the reply if this is one, go with the first.
    ///
    /// They are uploaded one at a time. Handed to the SDK together they upload side by side and
    /// arrive in whatever order they finish, which is rarely the order they were chosen in.
    func send(_ items: [StagedAttachment], caption: String, mentions: [ComposedMention] = [], replyTo: String? = nil) {
        let captionParts = caption.isEmpty ? nil : MentionComposer.parts(for: caption, mentions: mentions)
        for (index, item) in items.enumerated() {
            imageQueue.append(QueuedImage(item: item, caption: index == 0 ? captionParts : nil,
                                          replyTo: index == 0 ? replyTo : nil))
        }
        rebuildRows()
        runImageQueue()
        if threadRoot == nil, let timeline { Task { try? await timeline.markAsRead(receiptType: .fullyRead) } }
    }

    private func runImageQueue() {
        guard imageQueueTask == nil else { return }
        imageQueueTask = Task { [weak self] in
            while let self, let next = self.imageQueue.first, let timeline = self.timeline, !Task.isCancelled {
                // Its own row, from the SDK, takes over from the placeholder once it shows up.
                self.handover = (next.id, self.unsentImageRows(in: self.rows))
                do {
                    let handle = try timeline.sendAttachment(params: Self.parameters(for: next),
                                                             attachment: Self.attachment(for: next.item))
                    try? await handle.join()
                    self.error = nil
                } catch {
                    self.error = error.actionMessage
                    self.dequeue(next.id)
                    continue
                }
                var row: String?
                for _ in 0..<40 where row == nil {
                    row = self.unsentImageRows(in: self.rows).subtracting(self.handover?.before ?? []).first
                    if row == nil { try? await Task.sleep(for: .milliseconds(75)) }
                }
                self.dequeue(next.id)
                // Wait for it to be sent, or given up on, before starting the next.
                while let row, !Task.isCancelled, self.unsentImageRows(in: self.rows).contains(row) {
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
            self?.imageQueueTask = nil
        }
    }

    private func dequeue(_ id: UUID) {
        imageQueue.removeAll { $0.id == id }
        if handover?.id == id { handover = nil }
        rebuildRows()
    }

    /// Rows for pictures and files of ours that the SDK is uploading, or has failed to.
    private func unsentImageRows(in rows: [TimelineRow]) -> Set<String> {
        Set(rows.compactMap { row in
            guard case .message(let message) = row.kind,
                  message.sendState == .sending || message.sendState == .failed else { return nil }
            switch message.body {
            case .image, .file, .audio: return row.id
            default: return nil
            }
        })
    }

    /// Images still waiting are drawn after everything else, as messages of ours.
    private func appendQueuedImages(to rows: inout [TimelineRow], after last: MessageRow?) {
        guard !imageQueue.isEmpty else { return }
        var previous = last
        for queued in imageQueue {
            // The one just handed over has its real row by now: don't show it twice.
            if let handover, handover.id == queued.id, !unsentImageRows(in: rows).subtracting(handover.before).isEmpty { continue }
            let id = Self.queuedPrefix + queued.id.uuidString
            var message = MessageRow(
                itemID: .transactionId(transactionId: id),
                sender: ownUserID,
                senderName: profiles[ownUserID]?.name ?? ownUserID.matrixLocalpart,
                senderAvatarURL: profiles[ownUserID]?.avatarURL,
                isOwn: true,
                date: queued.queuedAt,
                body: queued.body,
                sendState: .waiting,
                localPreview: queued.preview)
            if let previous, previous.sender == ownUserID, message.date.timeIntervalSince(previous.date) < 300 {
                message.showsHeader = false
                Self.continueRun(in: &rows)
            }
            message.startsAfterPause = previous.map { message.date.timeIntervalSince($0.date) >= 900 } ?? true
            previous = message
            rows.append(TimelineRow(id: id, kind: .message(message)))
        }
    }

    /// The message last in the rows has another of its sender's after it, in the same run.
    private static func continueRun(in rows: inout [TimelineRow]) {
        guard let last = rows.indices.last, case .message(var message) = rows[last].kind else { return }
        message.endsRun = false
        rows[last].kind = .message(message)
    }

    private static func parameters(for queued: QueuedImage) -> UploadParameters {
        let source: UploadSource
        switch queued.item {
        case .image(let image): source = .data(bytes: image.data, filename: image.filename)
        // Read from disk as it uploads: a large file is never all in memory.
        case .file(let file): source = .file(filename: file.url.path)
        }
        return UploadParameters(
            source: source,
            caption: queued.caption?.plain,
            formattedCaption: queued.caption?.html.map { FormattedBody(format: .html, body: $0) },
            mentions: queued.caption?.mentions,
            inReplyTo: queued.replyTo,
            extraContentJson: nil)
    }

    private static func attachment(for item: StagedAttachment) -> AttachmentKind {
        switch item {
        case .image(let image): return attachment(for: image)
        case .file(let file):
            switch file.kind {
            case .file:
                return .file(fileInfo: FileInfo(mimetype: file.mimetype, size: file.size,
                                                thumbnailInfo: nil, thumbnailSource: nil))
            case .video(let duration, let size, let poster):
                let thumbnail = poster.map {
                    ThumbnailInfo(height: UInt64($0.pixelSize.height), width: UInt64($0.pixelSize.width),
                                  mimetype: "image/jpeg", size: UInt64($0.data.count))
                }
                return .video(videoInfo: VideoInfo(duration: duration, height: size.map { UInt64($0.height) },
                                                   width: size.map { UInt64($0.width) }, mimetype: file.mimetype,
                                                   size: file.size, thumbnailInfo: thumbnail, thumbnailSource: nil,
                                                   blurhash: poster?.blurhash),
                              thumbnailSource: poster.map { .data(bytes: $0.data, filename: "thumbnail.jpg") })
            case .audio(let duration):
                return .audio(audioInfo: AudioInfo(duration: duration, size: file.size, mimetype: file.mimetype))
            }
        }
    }

    private static func attachment(for image: StagedImage) -> AttachmentKind {
        let info = ImageInfo(
            height: UInt64(image.pixelSize.height),
            width: UInt64(image.pixelSize.width),
            mimetype: image.mimetype,
            size: UInt64(image.data.count),
            thumbnailInfo: image.thumbnail.map {
                ThumbnailInfo(height: UInt64($0.size.height), width: UInt64($0.size.width),
                              mimetype: $0.mimetype, size: UInt64($0.data.count))
            },
            thumbnailSource: nil,
            blurhash: image.blurhash,
            isAnimated: image.isAnimated)
        return .image(imageInfo: info, thumbnailSource: image.thumbnail.map { .data(bytes: $0.data, filename: "thumbnail") })
    }

    /// Gives up on a message that hasn't been sent: stops its upload and removes it.
    func discard(_ itemID: EventOrTransactionId) async {
        if case .transactionId(let id) = itemID, id.hasPrefix(Self.queuedPrefix) {
            if let queued = imageQueue.first(where: { Self.queuedPrefix + $0.id.uuidString == id }) { dequeue(queued.id) }
            return
        }
        try? await timeline?.redactEvent(eventOrTransactionId: itemID, reason: nil)
    }

    /// Replaces a message's text, or a picture's or recording's caption, with `text`.
    func edit(_ itemID: EventOrTransactionId, kind: MessageRow.EditKind, to text: String,
              mentions: [ComposedMention]) async {
        guard let timeline else { return }
        let content: EditedContent
        switch kind {
        case .text:
            content = .roomMessage(content: MentionComposer.content(for: text, mentions: mentions))
        case .emote:
            content = .roomMessage(content: messageEventContentFromMarkdownAsEmote(md: text))
        case .caption:
            let parts = MentionComposer.parts(for: text, mentions: mentions)
            content = .mediaCaption(caption: parts.plain.isEmpty ? nil : parts.plain,
                                    formattedCaption: parts.html.map { FormattedBody(format: .html, body: $0) },
                                    mentions: parts.mentions)
        }
        do {
            try await timeline.edit(eventOrTransactionId: itemID, newContent: content)
            error = nil
        } catch {
            self.error = error.actionMessage
        }
    }

    /// Deletes a message for everyone. One that hasn't been sent yet is simply dropped.
    func delete(_ itemID: EventOrTransactionId) async {
        do {
            try await timeline?.redactEvent(eventOrTransactionId: itemID, reason: nil)
            error = nil
        } catch {
            self.error = error.actionMessage
        }
    }

    /// Pins or unpins a message. Shown at once; the room's own record catches up as it syncs.
    func setPinned(_ pinned: Bool, eventID: String) async {
        guard let timeline else { return }
        let before = pinnedEventIDs
        pinnedEventIDs.removeAll { $0 == eventID }
        if pinned { pinnedEventIDs.append(eventID) }
        rebuildRows()
        do {
            _ = pinned ? try await timeline.pinEvent(eventId: eventID) : try await timeline.unpinEvent(eventId: eventID)
            error = nil
        } catch {
            pinnedEventIDs = before
            rebuildRows()
            self.error = error.actionMessage
        }
    }

    /// A message's content as it can be sent again elsewhere: without what it answered or
    /// belonged to, and without its mentions, so the people it named aren't notified twice.
    func forwardableContent(for itemID: EventOrTransactionId) -> RoomMessageEventContentWithoutRelation? {
        for item in items {
            guard let event = item.asEvent(), event.eventOrTransactionId == itemID,
                  case .msgLike(let content) = event.content,
                  case .message(let message) = content.kind else { continue }
            return (try? contentWithoutRelationFromMessage(message: message))?
                .withMentions(mentions: Mentions(userIds: [], room: false))
        }
        return nil
    }

    /// The user has read what went wrong.
    func dismissError() { error = nil }

    func toggleReaction(_ key: String, on itemID: EventOrTransactionId) async {
        do {
            _ = try await timeline?.toggleReaction(itemId: itemID, key: key)
        } catch {
            // Said under the composer, as other failures here are, rather than not at all.
            self.error = error.actionMessage
        }
    }

    func retry(_ itemID: EventOrTransactionId) async {
        // After a failure the room's queue may be switched off; nothing is sent until it is on.
        room.enableSendQueue(enable: true)
        _ = try? await timeline?.retrySend(itemId: itemID, target: .event)
    }

    /// Called when the user moves away from the room. The "New" line marks where they had read
    /// up to on arriving, and stays put while they are here; if they reached the newest message,
    /// move it there so it is gone when they come back.
    func leave() async {
        guard isLive, hasReadToEnd, !holdsUnread, let timeline else { return }
        hasReadToEnd = false
        try? await timeline.markAsRead(receiptType: .fullyRead)
    }

    func markAsRead() async {
        // A stretch of older messages isn't where the room has been read up to; nor is a room
        // the user has just marked unread.
        guard let timeline, focusedEvent == nil, !isPinnedList, !holdsUnread else { return }
        try? await timeline.markAsRead(receiptType: .read)
        hasReadToEnd = true
        guard threadRoot != nil else { return }
        // A thread's own receipt doesn't lower the room's unread count, which is measured from
        // the room-wide receipt. Move that one up to the newest reply read here.
        if let latest = await timeline.latestEventId(), latest != lastRoomReceipt {
            lastRoomReceipt = latest
            try? await room.sendSingleReceipt(receiptType: .read, thread: .unthreaded, eventId: latest)
        }
        onRead?()
    }

    /// Room timeline: the thread with this root has just been read in its panel.
    func markThreadSeen(_ root: String) {
        threadSeen[root] = .now
        rebuildRows()
        refreshNewThreads()
    }

    /// Whether a thread has a reply from someone else since you last read the room or it.
    private func isNew(thread root: String, latestReply: Date, fromOthers: Bool) -> Bool {
        fromOthers && latestReply > max(unreadHorizon ?? .distantPast, threadSeen[root] ?? .distantPast)
    }

    private func followThreads() {
        let list = RoomThreadList(room: room, datesBack: unreadHorizon)
        list.contactName = { [weak self] in self?.contactName($0) }
        list.onChange = { [weak self] in self?.refreshNewThreads() }
        threadActivity = list
        refreshNewThreads()
    }

    private func refreshNewThreads() {
        let threads = (threadActivity?.entries ?? []).filter { $0.replyCount > 0 && $0.latestDateIsKnown }
        let new = threads.filter { isNew(thread: $0.id, latestReply: $0.latestDate, fromOthers: $0.latestIsOthers) }
        if new != newThreads { newThreads = new }
        onLatestThreadReply?(threads.map(\.latestDate).max())
    }
}

// MARK: - Mapping SDK items to rows

extension TimelineRow.Kind {
    /// Nil for events not worth a row (join rules and other housekeeping state; of power
    /// levels, only changes to people's roles get one). `name` gives a person's name by ID.
    /// `contactName` gives the user's own name for someone, where they've given one.
    init?(event: EventTimelineItem, ownUserID: String, name: (String) -> String = { $0.matrixLocalpart },
          contactName: (String) -> String? = { _ in nil }) {
        // A call's answer, decline and end are told on its invite's line (`CallHistory`).
        if let kind = CallEvent.kind(of: event.content), kind != .invite { return nil }
        let senderName = contactName(event.sender) ?? event.senderProfile.name(fallback: event.sender)
        guard case .msgLike(let content) = event.content else {
            if case .state(_, .roomPowerLevels(_, _, let users, let previousUsers, let thresholds, _)) = event.content {
                guard let text = RoleChangeNotice.text(senderID: event.sender, senderName: senderName, users: users,
                                                       previousUsers: previousUsers,
                                                       usersDefault: thresholds.usersDefault, name: name)
                else { return nil }
                self = .notice(text)
                return
            }
            guard let text = event.content.preview(sender: senderName, contactName: contactName) else { return nil }
            self = .notice(text)
            return
        }
        // A request to verify, sent in the chat: a line saying so, not its fallback text for
        // apps that can't verify ("…is requesting to verify your key, but your client…").
        if case .message(let message) = content.kind, message.isVerificationRequest {
            self = .notice(event.isOwn ? "You asked to verify" : "\(senderName) asked to verify with you")
            return
        }

        let body: MessageRow.Body
        var isEdited = false
        var formatted: FormattedBody?
        var mentionsRoom = false
        switch content.kind {
        case .message(let message):
            isEdited = message.isEdited
            body = .init(message: message)
            mentionsRoom = message.mentions?.room ?? false
            switch message.msgType {
            case .text(let content): formatted = content.formatted
            case .notice(let content): formatted = content.formatted
            case .emote(let content): formatted = content.formatted
            default: break
            }
        case .sticker(let text, let info, let source):
            body = .image(ImageAttachment(sticker: source, info: info, name: text))
        case .poll(let question, _, _, _, _, _, _):
            body = .unsupported("Poll: \(question)")
        case .redacted:
            body = .redacted
        case .unableToDecrypt(let message):
            body = .undecryptable(MessageRow.Body.reason(undecryptable: message))
        case .other, .liveLocation:
            body = .unsupported("Unsupported message")
        }

        var sendState: MessageRow.SendState?
        var uploadProgress: Double?
        var sendFailure: String?
        switch event.localSendState {
        case .notSentYet(let progress):
            sendState = .sending
            if let upload = progress?.progress, upload.total > 0 {
                uploadProgress = min(Double(upload.current) / Double(upload.total), 1)
            }
        case .sendingFailed(let error, _):
            sendState = .failed
            sendFailure = MessageRow.sendFailure(error, name: name)
        default: break
        }

        self = .message(MessageRow(
            itemID: event.eventOrTransactionId,
            sender: event.sender,
            senderName: senderName,
            senderAvatarURL: event.senderProfile.avatarURL,
            isOwn: event.isOwn,
            date: Date(matrixTimestamp: event.timestamp),
            body: body,
            isEdited: isEdited,
            isEditable: event.isEditable,
            reactions: event.reactions.map { reaction in
                let latest = reaction.senders.max { $0.timestamp < $1.timestamp }
                return .init(key: reaction.key,
                             count: reaction.senders.count,
                             isOwn: reaction.senders.contains { $0.senderId == ownUserID },
                             senders: reaction.senders.sorted { $0.timestamp < $1.timestamp }.map(\.senderId),
                             latestSender: latest?.senderId,
                             latestDate: latest.map { Date(matrixTimestamp: $0.timestamp) })
            },
            sendState: sendState,
            thread: ThreadInfo(content.threadSummary),
            // Sorted so the same receipts always compare equal (dictionary order varies).
            receipts: event.readReceipts
                .map { userID, receipt in
                    MessageRow.RawReceipt(userID: userID, date: receipt.timestamp.map(Date.init(matrixTimestamp:)))
                }
                .sorted { $0.userID < $1.userID },
            html: formatted.flatMap { $0.format == .html ? $0.body : nil },
            mentionsRoom: mentionsRoom,
            replyTo: content.inReplyTo.map(ReplyPreview.init),
            uploadProgress: uploadProgress,
            // Not strict: people who haven't been verified are the usual case, not a warning.
            shield: event.isOwn ? nil : MessageRow.Shield(event.lazyProvider.getShields(strict: false)),
            sendFailure: sendFailure))
    }
}

extension MessageRow {
    /// Why a message wasn't sent, in a few words after "Not sent: ". Nil for a plain failure
    /// (the network, say), which Try Again is the answer to.
    static func sendFailure(_ error: QueueWedgeError, name: (String) -> String) -> String? {
        switch error {
        // Excluding unverified devices (Settings ▸ Privacy) sends only from a verified Mac.
        case .crossVerificationRequired: return "this Mac isn’t verified"
        case .identityViolations(let users):
            let names = users.map(name).sorted()
            guard let first = names.first else { return nil }
            return names.count == 1 ? "\(first)’s verified identity changed"
                : "\(first) and \(names.count - 1) more changed their verified identity"
        case .insecureDevices: return "someone here has devices they haven’t verified"
        case .expiredAccessToken: return "sign in again"
        case .missingMediaContent: return "the file is no longer on this Mac"
        case .invalidMimeType: return "the file’s type isn’t recognized"
        case .genericApiError: return nil
        }
    }

    /// What the SDK says about a message's authenticity, in words: a short label to show under
    /// it, and what that means, for its tooltip.
    struct Shield: Equatable {
        /// Red rather than grey: something is wrong, not merely unknown.
        let isSerious: Bool
        let label: String
        let detail: String

        init?(_ state: ShieldState) {
            switch state {
            case .none: return nil
            case .red(let code): self.init(code, isSerious: true)
            case .grey(let code): self.init(code, isSerious: false)
            }
        }

        private init(_ code: TimelineEventShieldStateCode, isSerious: Bool) {
            self.isSerious = isSerious
            switch code {
            case .authenticityNotGuaranteed:
                label = "Authenticity not guaranteed"
                detail = "Whether this encrypted message is genuine can’t be confirmed on this Mac."
            case .unknownDevice:
                label = "Unknown device"
                detail = "Sent from a device that is unknown or has been deleted."
            case .unsignedDevice:
                label = "Unverified device"
                detail = "Sent from a device its owner hasn’t verified."
            case .unverifiedIdentity:
                label = "Unverified sender"
                detail = "You haven’t verified who sent this."
            case .verificationViolation:
                label = "Identity changed"
                detail = "The sender’s identity changed after you verified them."
            case .mismatchedSender:
                label = "Sender doesn’t match"
                detail = "Sent from a device that belongs to someone else, so it may not be from who it says."
            case .sentInClear:
                label = "Not encrypted"
                detail = "Sent unencrypted in an encrypted room."
            }
        }
    }
}

/// Whether a room's messages are end-to-end encrypted.
enum RoomEncryption: Equatable {
    case unknown
    case encrypted
    /// Public rooms are usually unencrypted on purpose; elsewhere it's worth noticing.
    case notEncrypted(isPublic: Bool)
}

/// Someone in the room whose encryption identity changed, which needs a word from the person
/// using Huddle before it is trusted again.
struct IdentityWarning: Equatable, Identifiable {
    let userID: String
    var name: String
    /// They had been verified: the change undoes that.
    let wasVerified: Bool
    var id: String { userID }
}

extension MessageRow.Body {
    /// Why a message can't be read, when it won't be: nil while its keys may still come.
    static func reason(undecryptable message: EncryptedMessage) -> String? {
        guard case .megolmV1AesSha2(_, let cause) = message else { return nil }
        switch cause {
        // Turned away by Settings ▸ Privacy ▸ Exclude unverified devices.
        case .unsignedDevice: return "Hidden: sent from a device its owner hasn’t verified"
        case .unknownDevice: return "Hidden: sent from an unknown or deleted device"
        case .verificationViolation: return "Hidden: the sender’s verified identity changed"
        // The sender's app wouldn't share it with this Mac.
        case .withheldForUnverifiedOrInsecureDevice: return "Not shared with this Mac, which isn’t verified"
        case .withheldBySender: return "The sender didn’t share the keys for this message"
        case .sentBeforeWeJoined: return "Sent before you joined"
        case .historicalMessageAndDeviceIsUnverified: return "Verify this Mac to read older messages"
        case .historicalMessageAndBackupIsDisabled: return "Older message, not in your key backup"
        case .unknown, .malformed: return nil
        }
    }

    init(message: MessageContent) {
        switch message.msgType {
        case .text(let content): self = .text(content.body)
        case .notice(let content): self = .text(content.body)
        case .emote(let content): self = .emote(content.body)
        case .image(let content): self = .image(ImageAttachment(content))
        case .video(let content): self = .file(FileAttachment(content))
        case .audio(let content): self = .audio(AudioAttachment(content))
        case .file(let content): self = .file(FileAttachment(content))
        case .gallery: self = .attachment(icon: "photo.on.rectangle", name: message.body)
        case .location: self = .attachment(icon: "mappin.and.ellipse", name: "Location")
        case .other(_, let body): self = .text(body)
        }
    }
}

extension ImageInfo {
    var aspectRatio: Double {
        guard let width, let height, width > 0, height > 0 else { return 1.5 }
        return Double(width) / Double(height)
    }
}

extension MessageContent {
    /// A request to verify, sent in a chat (as requests to other people are).
    var isVerificationRequest: Bool {
        if case .other(let type, _) = msgType { return type == "m.key.verification.request" }
        return false
    }
}

extension TimelineItemContent {
    /// One-line description used for room list previews and state events.
    /// `contactName` gives the user's own name for someone, for whoever joined, left or was
    /// invited.
    func preview(sender: String?, contactName: (String) -> String? = { _ in nil }) -> String? {
        let who = sender ?? "Someone"
        switch self {
        case .msgLike(let content):
            let text: String
            switch content.kind {
            case .message(let message):
                switch message.msgType {
                // A file is known by its name, not by what kind of file it is.
                case .image(let image): text = AttachmentText.line(name: image.filename, caption: image.caption, kind: "Image")
                case .video(let video): text = AttachmentText.line(name: video.filename, caption: video.caption, kind: "Video")
                case .audio(let audio):
                    text = audio.voice != nil ? "Voice message"
                        : AttachmentText.line(name: audio.filename, caption: audio.caption, kind: "Audio")
                case .file(let file): text = AttachmentText.line(name: file.filename, caption: file.caption, kind: "File")
                case .emote(let emote):
                    return "* \(who) \(MessageFormatter.plainText(text: emote.body, formatted: emote.formatted))"
                case .text(let content): text = MessageFormatter.plainText(text: content.body, formatted: content.formatted)
                case .notice(let content): text = MessageFormatter.plainText(text: content.body, formatted: content.formatted)
                default: text = message.isVerificationRequest ? "Verification request" : message.body
                }
            case .sticker: text = "Sticker"
            case .poll(let question, _, _, _, _, _, _): text = "Poll: \(question)"
            case .redacted: text = "Message deleted"
            case .unableToDecrypt(let message):
                text = MessageRow.Body.reason(undecryptable: message) ?? "Waiting for encryption keys"
            case .other, .liveLocation: text = "Message"
            }
            let line = text.replacingOccurrences(of: "\n", with: " ")
            return sender.map { "\($0): \(line)" } ?? line
        case .callInvite:
            // A one-to-one call, over by the time anyone reads this. In a direct chat, as its
            // messages are, without the name the chat already has.
            return sender.map { "\($0) called" } ?? "Called you"
        case .rtcNotification:
            return sender.map { "\($0) started a call" } ?? "Started a call"
        case .roomMembership(let userID, let displayName, let change, _):
            let target = contactName(userID) ?? displayName ?? userID
            switch change {
            case .joined, .invitationAccepted, .knockAccepted: return "\(target) joined"
            case .left: return "\(target) left"
            case .invited: return "\(who) invited \(target)"
            case .banned, .kickedAndBanned: return "\(who) banned \(target)"
            case .unbanned: return "\(who) unbanned \(target)"
            case .kicked: return "\(who) removed \(target)"
            case .invitationRejected: return "\(target) declined the invitation"
            case .invitationRevoked: return "\(who) withdrew \(target)’s invitation"
            case .knocked: return "\(target) asked to join"
            default: return nil
            }
        case .profileChange(let displayName, let previous, _, _):
            if let displayName, let previous, displayName != previous {
                return "\(previous) changed their name to \(displayName)"
            }
            return "\(who) updated their profile"
        case .state(_, let content):
            switch content {
            case .roomName(let name): return "\(who) renamed the room to \(name ?? "nothing")"
            case .roomTopic: return "\(who) changed the topic"
            case .roomAvatar: return "\(who) changed the room picture"
            case .roomCreate: return "\(who) created the room"
            case .roomEncryption: return "Encryption enabled"
            case .roomPinnedEvents(let change):
                switch change {
                case .added: return "\(who) pinned a message"
                case .removed: return "\(who) unpinned a message"
                case .changed: return "\(who) changed the pinned messages"
                }
            default: return nil
            }
        case .failedToParseMessageLike, .failedToParseState:
            return nil
        }
    }
}

/// The line a change to people's roles reads as: "Alice made Bob a moderator", "Bob stepped
/// down as admin". Roles go by power level as everywhere else: 100 and up admin, 50 and up
/// moderator.
enum RoleChangeNotice {
    static func text(senderID: String, senderName: String, users: [String: Int64], previousUsers: [String: Int64]?,
                     usersDefault: Int64, name: (String) -> String) -> String? {
        // A room's first power levels come with its creation, which has a line of its own.
        guard let previousUsers else { return nil }
        let changed = Set(users.keys).union(previousUsers.keys)
            .filter { (users[$0] ?? usersDefault) != (previousUsers[$0] ?? usersDefault) }
        // Only what may be done in the room changed, not anyone's role.
        guard let userID = changed.first else { return nil }
        if changed.count > 1 {
            let names = changed.map(name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return "\(senderName) changed the roles of \(ListFormatter.localizedString(byJoining: names))"
        }
        let old = previousUsers[userID] ?? usersDefault
        let new = users[userID] ?? usersDefault
        if userID == senderID {
            guard new < old else { return "\(senderName) changed their role" }
            return new >= 50 ? "\(senderName) stepped down to \(role(new))" : "\(senderName) stepped down as \(role(old))"
        }
        let target = name(userID)
        if new >= 50, role(new) != role(old) {
            return "\(senderName) made \(target) \(role(new) == "admin" ? "an" : "a") \(role(new))"
        }
        if new < 50, old >= 50 { return "\(senderName) removed \(target) as \(role(old))" }
        return "\(senderName) changed \(target)’s role"
    }

    private static func role(_ level: Int64) -> String {
        level >= 100 ? "admin" : level >= 50 ? "moderator" : "member"
    }
}

/// What this account may do to the messages in a room, from its power levels.
struct TimelinePermissions: Equatable {
    var canDeleteOwn = true
    var canDeleteOthers = false
    var canPin = false
    /// Whether it may take part in calls: post its call membership, which Element Call needs.
    var canJoinCalls = true

    init() {}

    init(_ levels: RoomPowerLevels) {
        canDeleteOwn = levels.canOwnUserRedactOwn()
        canDeleteOthers = levels.canOwnUserRedactOther()
        canPin = levels.canOwnUserPinUnpin()
        canJoinCalls = levels.canOwnUserSendState(stateEvent: .callMember)
    }
}

extension MessageRow {
    /// What editing a message changes: its text, or the caption under a picture or recording.
    enum EditKind: Equatable {
        case text
        case emote
        case caption
    }

    /// How this message can be edited, if at all.
    var editKind: EditKind? {
        guard isEditable, eventID != nil else { return nil }
        switch body {
        case .text: return .text
        case .emote: return .emote
        case .image(let image): return image.isSticker ? nil : .caption
        case .audio, .file: return .caption
        default: return nil
        }
    }

    /// The text an edit starts from.
    var editableText: String {
        switch body {
        case .text(let text), .emote(let text): return text
        case .image(let image): return image.caption ?? ""
        case .audio(let audio): return audio.caption ?? ""
        case .file(let file): return file.caption ?? ""
        default: return ""
        }
    }

    /// Whether this is something that can be sent on to another room.
    var canForward: Bool {
        guard eventID != nil else { return false }
        switch body {
        case .text, .emote, .audio, .file, .attachment: return true
        case .image(let image): return !image.isSticker
        case .undecryptable, .redacted, .unsupported: return false
        }
    }
}

/// "Alice pinned a message", or several of them: "Alice pinned 3 messages".
struct PinNotice {
    let who: String
    /// "pinned" or "unpinned".
    let verb: String
    var count = 1

    init(who: String, verb: String, count: Int) {
        self.who = who
        self.verb = verb
        self.count = count
    }

    /// Reads a notice written by this struct (or by `TimelineItemContent.preview`).
    init?(_ text: String) {
        for verb in ["unpinned", "pinned"] {
            guard let range = text.range(of: " \(verb) ") else { continue }
            let rest = text[range.upperBound...]
            if rest == "a message" {
                count = 1
            } else if rest.hasSuffix(" messages"), let number = Int(rest.dropLast(" messages".count)) {
                count = number
            } else {
                return nil
            }
            who = String(text[..<range.lowerBound])
            self.verb = verb
            return
        }
        return nil
    }

    var text: String {
        "\(who) \(verb) " + (count == 1 ? "a message" : "\(count) messages")
    }
}
