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

    struct ReactionChip: Equatable, Identifiable {
        var key: String
        var count: Int
        var isOwn: Bool
        var id: String { key }
    }

    var itemID: EventOrTransactionId
    var sender: String
    var senderName: String
    var senderAvatarURL: String?
    var isOwn: Bool
    var date: Date
    var body: Body
    var isEdited = false
    var reactions: [ReactionChip] = []
    var sendState: SendState?
    /// False when this message continues a run from the same sender.
    var showsHeader = true
}

/// Equatable wrapper around the SDK's reference-typed media source.
struct MediaRef: Equatable {
    let source: MediaSource
    static func == (lhs: MediaRef, rhs: MediaRef) -> Bool { lhs.source.url() == rhs.source.url() }
}

/// Live, paginated view of one room's events.
@MainActor @Observable
final class RoomTimeline {
    let room: Room
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
    @ObservationIgnored private var ownUserID: String

    init(room: Room) {
        self.room = room
        ownUserID = room.ownUserId()
        updatesTask = Task { [weak self] in await self?.run() }
    }

    func stop() {
        updatesTask?.cancel()
        listenerHandle?.cancel()
    }

    private func run() async {
        do {
            let timeline = try await room.timeline()
            self.timeline = timeline
            let (stream, continuation) = AsyncStream.makeStream(of: [TimelineDiff].self)
            listenerHandle = await timeline.addListener(listener: TimelineDiffListener { continuation.yield($0) })
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
        // A read marker under the newest message is noise.
        if case .readMarker = rows.last?.kind { rows.removeLast() }

        // Detect history landing above what was the oldest message, so the view can hold its place.
        let oldFirst = self.rows.first(where: \.isMessage)?.id
        let newFirst = rows.first(where: \.isMessage)?.id
        self.rows = rows
        if let oldFirst, oldFirst != newFirst, rows.contains(where: { $0.id == oldFirst }) {
            prependAnchorID = oldFirst
            prependCount += 1
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
            self.error = error.userMessage
        }
    }

    func send(_ text: String) async {
        guard let timeline else { return }
        do {
            _ = try await timeline.send(msg: messageEventContentFromMarkdown(md: text))
            error = nil
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

    func markAsRead() async {
        try? await timeline?.markAsRead(receiptType: .read)
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
        switch content.kind {
        case .message(let message):
            isEdited = message.isEdited
            body = .init(message: message)
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
                .init(key: reaction.key,
                      count: reaction.senders.count,
                      isOwn: reaction.senders.contains { $0.senderId == ownUserID })
            },
            sendState: sendState))
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
                case .emote(let emote): return "* \(who) \(emote.body)"
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
