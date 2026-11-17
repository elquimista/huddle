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

    var isMessage: Bool {
        if case .message = kind { return true }
        return false
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
        case image(MediaRef, caption: String?, aspectRatio: Double)
        case attachment(icon: String, name: String)
        case undecryptable
        case redacted
        case unsupported(String)
    }

    enum SendState: Equatable { case sending, failed }

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
    var reactions: [ReactionChip] = []
    var sendState: SendState?
    /// Present on a message that has thread replies.
    var thread: ThreadInfo?
    /// Read receipts placed on this message, as the SDK reports them. Resolved into `readers`.
    var receipts: [RawReceipt] = []
    /// The sender's HTML formatting for a text message, if their client sent any.
    var html: String?
    var mentionsRoom = false
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
}

extension String {
    /// "alice" from "@alice:example.org".
    var matrixLocalpart: String {
        guard hasPrefix("@"), let colon = firstIndex(of: ":") else { return self }
        return String(self[index(after: startIndex)..<colon])
    }
}

@MainActor @Observable
final class RoomTimeline {
    let room: Room
    /// Set for a thread's timeline: the root message's event ID.
    let threadRoot: String?
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
    /// Thread timeline only. Tells the room's timeline that this thread has been read.
    /// Everyone else in the room, for mention suggestions. Empty until `loadMembers()`.
    private(set) var members: [MentionCandidate] = []
    @ObservationIgnored private var membersRequested = false
    @ObservationIgnored var onRead: (() -> Void)?
    @ObservationIgnored var onLatestReaction: ((ReactionPreview?) -> Void)?
    @ObservationIgnored private var latestReaction: ReactionPreview?
    @ObservationIgnored private var lastRoomReceipt: String?
    /// A two-person direct chat shows ticks on your messages; other rooms show who has read.
    @ObservationIgnored private var isOneToOne = false
    /// Names and avatars for read receipts, learned from messages and fetched for the rest.
    @ObservationIgnored private var profiles: [String: (name: String, avatarURL: String?)] = [:]
    @ObservationIgnored private var requestedProfiles: Set<String> = []

    init(room: Room, threadRoot: String? = nil) {
        self.room = room
        self.threadRoot = threadRoot
        ownUserID = room.ownUserId()
        updatesTask = Task { [weak self] in await self?.run() }
    }

    private var hasReadToEnd = false

    func stop() {
        updatesTask?.cancel()
        listenerHandle?.cancel()
    }

    private func run() async {
        do {
            // The room's own timeline leaves thread replies out; a thread's timeline is its root
            // message followed by its replies, and sends into that thread.
            let focus: TimelineFocus = threadRoot.map { .thread(rootEventId: $0) }
                ?? .live(hideThreadedEvents: true)
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
            if threadRoot == nil { unreadHorizon = await lastReadTime() }
            let isDirect = await room.isDirect()
            isOneToOne = isDirect && room.activeMembersCount() <= 2
            isLoading = false
            for await diffs in stream {
                for diff in diffs { items.apply(diff.diff) }
                rebuildRows()
            }
        } catch {
            self.error = error.userMessage
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

    private func rebuildRows() {
        var rows: [TimelineRow] = []
        rows.reserveCapacity(items.count)
        var previous: MessageRow?
        for item in items {
            let id = item.uniqueId().id
            if let event = item.asEvent() {
                switch TimelineRow.Kind(event: event, ownUserID: ownUserID) {
                case .message(var message):
                    if let previous, previous.sender == message.sender,
                       message.date.timeIntervalSince(previous.date) < 300 {
                        message.showsHeader = false
                    }
                    previous = message
                    rows.append(TimelineRow(id: id, kind: .message(message)))
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
        // A thread's history ends at its root message.
        if let threadRoot, let first = rows.first(where: \.isMessage),
           case .message(let message) = first.kind, message.eventID == threadRoot {
            hasMoreHistory = false
        }
        // A read marker with no message under it is noise. What followed it may be hidden here
        // (thread replies, reactions), leaving only date dividers or nothing at all.
        if let marker = rows.lastIndex(where: { if case .readMarker = $0.kind { true } else { false } }),
           !rows[(marker + 1)...].contains(where: { if case .dateDivider = $0.kind { false } else { true } }) {
            rows.remove(at: marker)
        }

        if threadRoot == nil {
            for index in rows.indices {
                guard case .message(var message) = rows[index].kind, var thread = message.thread,
                      let root = message.eventID, let latest = thread.latestDate else { continue }
                let seen = max(unreadHorizon ?? .distantPast, threadSeen[root] ?? .distantPast)
                thread.hasNewReplies = latest > seen && thread.latestSender != ownUserID
                message.thread = thread
                rows[index].kind = .message(message)
            }
        }

        resolveReceipts(in: &rows)

        // Detect history landing above what was the oldest message, so the view can hold its place.
        let oldFirst = self.rows.first(where: \.isMessage)?.id
        let newFirst = rows.first(where: \.isMessage)?.id
        self.rows = rows
        if threadRoot == nil { updateLatestReaction() }
        if let oldFirst, oldFirst != newFirst, rows.contains(where: { $0.id == oldFirst }) {
            prependAnchorID = oldFirst
            prependCount += 1
        }
    }

    /// A person's display name, if this timeline has come across it.
    func knownName(for userID: String) -> String? { profiles[userID]?.name }

    /// The newest reaction, if it came after the newest message: the room list shows it as the
    /// room's latest activity.
    private func updateLatestReaction() {
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
                        text: text, formatted: message.html.map { FormattedBody(format: .html, body: $0) },
                        name: { [profiles] in profiles[$0]?.name })
                    target = "“\(plain.prefix(60))”"
                case .image: target = "an image"
                case .attachment(_, let name): target = name
                default: target = "a message"
                }
                let who = sender == ownUserID ? "You" : (profiles[sender]?.name ?? sender.matrixLocalpart)
                newest = ReactionPreview(text: "\(who) reacted \(reaction.key) to \(target)", date: date)
            }
        }
        if let found = newest, found.date <= lastMessageDate { newest = nil }
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
            } else if message.sendState == .sending {
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
            return .init(id: userID, name: profile.name, avatarURL: profile.avatarURL, date: receipt.date)
        }
        if requestedProfiles.insert(userID).inserted {
            Task { [weak self, room] in
                let name = try? await room.memberDisplayName(userId: userID)
                let avatar = try? await room.memberAvatarUrl(userId: userID)
                guard let self else { return }
                self.profiles[userID] = (name ?? userID, avatar ?? nil)
                self.rebuildRows()
            }
        }
        return .init(id: userID, name: userID, avatarURL: nil, date: receipt.date)
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
            self.error = error.userMessage
        }
    }

    /// Loads the room's members for mention suggestions, once.
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
                }
            }
        }
        members = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func send(_ text: String, mentions: [ComposedMention] = []) async {
        guard let timeline else { return }
        do {
            _ = try await timeline.send(msg: MentionComposer.content(for: text, mentions: mentions))
            error = nil
            // Having answered, the user is caught up: nothing above is "new" any more.
            if threadRoot == nil { try? await timeline.markAsRead(receiptType: .fullyRead) }
        } catch {
            self.error = error.userMessage
        }
    }

    func toggleReaction(_ key: String, on itemID: EventOrTransactionId) async {
        _ = try? await timeline?.toggleReaction(itemId: itemID, key: key)
    }

    func retry(_ itemID: EventOrTransactionId) async {
        _ = try? await timeline?.retrySend(itemId: itemID, target: .event)
    }

    /// Called when the user moves away from the room. The "New" line marks where they had read
    /// up to on arriving, and stays put while they are here; if they reached the newest message,
    /// move it there so it is gone when they come back.
    func leave() async {
        guard threadRoot == nil, hasReadToEnd, let timeline else { return }
        hasReadToEnd = false
        try? await timeline.markAsRead(receiptType: .fullyRead)
    }

    func markAsRead() async {
        guard let timeline else { return }
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
    }
}

// MARK: - Mapping SDK items to rows

extension TimelineRow.Kind {
    /// Nil for events not worth a row (power levels, join rules and other housekeeping state).
    init?(event: EventTimelineItem, ownUserID: String) {
        let senderName = event.senderProfile.name(fallback: event.sender)
        guard case .msgLike(let content) = event.content else {
            guard let text = event.content.preview(sender: senderName) else { return nil }
            self = .notice(text)
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
            body = .image(MediaRef(source: source), caption: nil, aspectRatio: info.aspectRatio)
            _ = text
        case .poll(let question, _, _, _, _, _, _):
            body = .unsupported("Poll: \(question)")
        case .redacted:
            body = .redacted
        case .unableToDecrypt:
            body = .undecryptable
        case .other, .liveLocation:
            body = .unsupported("Unsupported message")
        }

        var sendState: MessageRow.SendState?
        switch event.localSendState {
        case .notSentYet: sendState = .sending
        case .sendingFailed: sendState = .failed
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
            reactions: event.reactions.map { reaction in
                let latest = reaction.senders.max { $0.timestamp < $1.timestamp }
                return .init(key: reaction.key,
                             count: reaction.senders.count,
                             isOwn: reaction.senders.contains { $0.senderId == ownUserID },
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
            mentionsRoom: mentionsRoom))
    }
}

extension MessageRow.Body {
    init(message: MessageContent) {
        switch message.msgType {
        case .text(let content): self = .text(content.body)
        case .notice(let content): self = .text(content.body)
        case .emote(let content): self = .emote(content.body)
        case .image(let content):
            self = .image(MediaRef(source: content.source),
                          caption: content.caption,
                          aspectRatio: content.info?.aspectRatio ?? 1.5)
        case .video(let content): self = .attachment(icon: "film", name: content.filename)
        case .audio(let content): self = .attachment(icon: "waveform", name: content.filename)
        case .file(let content): self = .attachment(icon: "doc", name: content.filename)
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

extension TimelineItemContent {
    /// One-line description used for room list previews and state events.
    func preview(sender: String?) -> String? {
        let who = sender ?? "Someone"
        switch self {
        case .msgLike(let content):
            let text: String
            switch content.kind {
            case .message(let message):
                switch message.msgType {
                case .image: text = "Image"
                case .video: text = "Video"
                case .audio: text = "Audio"
                case .file(let file): text = file.filename
                case .emote(let emote):
                    return "* \(who) \(MessageFormatter.plainText(text: emote.body, formatted: emote.formatted))"
                case .text(let content): text = MessageFormatter.plainText(text: content.body, formatted: content.formatted)
                case .notice(let content): text = MessageFormatter.plainText(text: content.body, formatted: content.formatted)
                default: text = message.body
                }
            case .sticker: text = "Sticker"
            case .poll(let question, _, _, _, _, _, _): text = "Poll: \(question)"
            case .redacted: text = "Message deleted"
            case .unableToDecrypt: text = "Waiting for encryption keys"
            case .other, .liveLocation: text = "Message"
            }
            let line = text.replacingOccurrences(of: "\n", with: " ")
            return sender.map { "\($0): \(line)" } ?? line
        case .callInvite, .rtcNotification:
            return "\(who) started a call"
        case .roomMembership(let userID, let displayName, let change, _):
            let target = displayName ?? userID
            switch change {
            case .joined, .invitationAccepted, .knockAccepted: return "\(target) joined"
            case .left: return "\(target) left"
            case .invited: return "\(who) invited \(target)"
            case .banned, .kickedAndBanned: return "\(who) banned \(target)"
            case .unbanned: return "\(who) unbanned \(target)"
            case .kicked: return "\(who) removed \(target)"
            case .invitationRejected: return "\(target) declined the invitation"
            case .invitationRevoked: return "\(who) withdrew \(target)'s invitation"
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
            default: return nil
            }
        case .failedToParseMessageLike, .failedToParseState:
            return nil
        }
    }
}
