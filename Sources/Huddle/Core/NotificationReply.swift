import AppKit
import MatrixRustSDK
import UserNotifications

/// Answering a message from its notification, as in Messages: a Reply field on the alert, a few
/// reactions beside it, and Mark as Read. The answer goes into the room as a message of its own
/// (into the thread, for a message in one), written as in the composer; a reaction goes on the
/// message, as one chosen in the room would. Either way the room counts as read: it has been
/// answered. Mark as Read does only that, which clearing the alert doesn't.
extension Notifier {
    nonisolated static let messageCategory = "message"
    nonisolated static let replyAction = "reply"
    /// A reaction's action is this followed by the emoji.
    nonisolated static let reactionAction = "react:"
    /// The reactions a message's alert offers. Fixed: macOS has an alert's actions from when
    /// Huddle starts, and shows no picker in an alert.
    nonisolated static let alertReactions = ["👍", "👌", "❤️"]
    nonisolated static let markReadAction = "markRead"

    /// The kinds of alert with actions of their own: a message's, with Reply, the reactions and
    /// Mark as Read.
    static var categories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        let reactions = alertReactions.map { UNNotificationAction(identifier: reactionAction + $0, title: $0, options: []) }
        let markRead = UNNotificationAction(identifier: markReadAction, title: "Mark as Read", options: [])
        return [UNNotificationCategory(identifier: messageCategory, actions: [reply] + reactions + [markRead],
                                       intentIdentifiers: [], options: [])]
    }

    /// Sends a reply typed into a notification. Huddle may only just have been started to send
    /// it (by replying to an alert left from before it quit): then it waits, a while, for the
    /// account and its rooms to be ready. If it can't be sent, an alert says so and the words
    /// wait in the room's composer.
    func reply(_ text: String, accountID: String, roomID: String, thread: String?, roomName: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let thread = thread.flatMap { $0.isEmpty ? nil : $0 }
        guard let account = await waitForRoom(accountID: accountID, roomID: roomID) else {
            replyFailed(text, accountID: accountID, roomID: roomID, thread: thread, roomName: roomName, account: nil)
            return
        }
        do {
            try await account.sendReply(text, roomID: roomID, threadRoot: thread)
            if AppEnvironment.isDev {
                print("DEV_NOTIFY_REPLY sent room=\(roomID) thread=\(thread ?? "-") text=\(text)")
                fflush(stdout)
            }
        } catch {
            replyFailed(text, accountID: accountID, roomID: roomID, thread: thread, roomName: roomName, account: account)
        }
    }

    /// Puts a reaction chosen in a notification on its message. As with a reply, Huddle may only
    /// just have been started to send it, and waits a while for the account and the room. If it
    /// can't be sent, an alert says so.
    func react(_ key: String, accountID: String, roomID: String, eventID: String, thread: String?,
               roomName: String) async {
        let thread = thread.flatMap { $0.isEmpty ? nil : $0 }
        do {
            guard let account = await waitForRoom(accountID: accountID, roomID: roomID) else {
                throw AccountSession.RoomError.unavailable
            }
            try await account.sendReaction(key, to: eventID, roomID: roomID, threadRoot: thread)
            if AppEnvironment.isDev {
                print("DEV_NOTIFY_REACTION sent room=\(roomID) event=\(eventID) key=\(key)")
                fflush(stdout)
            }
        } catch {
            if AppEnvironment.isDev {
                print("DEV_NOTIFY_REACTION failed room=\(roomID) event=\(eventID) key=\(key) \(error)")
                fflush(stdout)
            }
            let content = UNMutableNotificationContent()
            content.title = "Reaction Not Sent"
            content.subtitle = roomName
            content.body = "Your \(key) couldn’t be put on the message. You can react to it in the conversation."
            content.threadIdentifier = "\(accountID)|\(roomID)"
            content.userInfo = ["account": accountID, "room": roomID, "thread": thread ?? ""]
            guard NotificationSettings.isEnabled else { return }
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "\(accountID)|\(roomID)|reaction-failed", content: content, trigger: nil),
                withCompletionHandler: nil)
        }
    }

    /// Marks a message's room read from its alert (for a message in a thread, the thread), as
    /// reading it in Huddle would. Waits, as a reply does, for the account and the room.
    func markRead(accountID: String, roomID: String, thread: String?) async {
        let thread = thread.flatMap { $0.isEmpty ? nil : $0 }
        guard let account = await waitForRoom(accountID: accountID, roomID: roomID) else { return }
        try? await account.markRead(roomID: roomID, threadRoot: thread)
        if AppEnvironment.isDev {
            print("DEV_NOTIFY_MARK_READ room=\(roomID) thread=\(thread ?? "-")")
            fflush(stdout)
        }
    }

    /// Waits, up to half a minute, for Huddle to have the account back after starting up.
    func waitForAccount(_ accountID: String) async {
        for _ in 0..<60 {
            if let store, !store.isRestoring, store.accounts.contains(where: { $0.id == accountID }) { return }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The account, once it has the room: at once while Huddle is running, or after it has
    /// finished starting up. Nil if that doesn't happen within a minute.
    private func waitForRoom(accountID: String, roomID: String) async -> AccountSession? {
        for _ in 0..<120 {
            if let store, !store.isRestoring, let account = store.accounts.first(where: { $0.id == accountID }),
               account.room(id: roomID) != nil {
                return account
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func replyFailed(_ text: String, accountID: String, roomID: String, thread: String?, roomName: String,
                             account: AccountSession?) {
        if AppEnvironment.isDev {
            print("DEV_NOTIFY_REPLY failed room=\(roomID) text=\(text)")
            fflush(stdout)
        }
        // Waiting where it was meant to go, to send from there.
        let key = thread.map { "\(roomID)|\($0)" } ?? roomID
        if let account, account.draft(for: key) == nil {
            account.keepDraft(StashedDraft(text: text), for: key)
        }
        let content = UNMutableNotificationContent()
        content.title = "Reply Not Sent"
        content.subtitle = roomName
        // The reply quoted only where alerts say what messages say.
        let what = NotificationSettings.showsText ? "“\(text)”" : "Your reply"
        content.body = account == nil
            ? "\(what) couldn’t be sent."
            : "\(what) couldn’t be sent. It’s waiting in the conversation, to send from there."
        content.threadIdentifier = "\(accountID)|\(roomID)"
        content.userInfo = ["account": accountID, "room": roomID, "thread": thread ?? ""]
        guard NotificationSettings.isEnabled else { return }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "\(accountID)|\(roomID)|reply-failed",
                                                                     content: content, trigger: nil))
    }
}

extension AccountSession {
    /// Sends a message typed outside the room's composer (in a notification), as the composer
    /// would: Markdown, to the room or into a thread. Then marks what it answers as read.
    func sendReply(_ text: String, roomID: String, threadRoot: String?) async throws {
        let timeline = try await answeringTimeline(roomID: roomID, threadRoot: threadRoot)
        _ = try await timeline.send(msg: MentionComposer.content(for: text, mentions: []))
        await markAnswered(roomID: roomID, threadRoot: threadRoot, timeline: timeline)
    }

    /// Puts a reaction on a message from outside the room (its notification), as choosing it in
    /// the room would, unless it's there already (put there from another device, say): adding it
    /// again would take it off. Then marks what it answers as read.
    func sendReaction(_ key: String, to eventID: String, roomID: String, threadRoot: String?) async throws {
        let timeline = try await answeringTimeline(roomID: roomID, threadRoot: threadRoot)
        // A timeline just made may take a moment to have the message.
        var message: EventTimelineItem?
        for _ in 0..<20 {
            if let found = try? await timeline.getEventTimelineItemByEventId(eventId: eventID) {
                message = found
                break
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let message else { throw RoomError.unavailable }
        let isThere = message.reactions.contains { $0.key == key && $0.senders.contains { $0.senderId == userID } }
        if !isThere {
            _ = try await timeline.toggleReaction(itemId: .eventId(eventId: eventID), key: key)
        }
        await markAnswered(roomID: roomID, threadRoot: threadRoot, timeline: timeline)
    }

    /// Marks a room read from outside it (its notification), or for a message in a thread, the
    /// thread: other messages in the room may still be unread.
    func markRead(roomID: String, threadRoot: String?) async throws {
        guard let threadRoot else { return setRoom(roomID, unread: false) }
        let timeline = try await answeringTimeline(roomID: roomID, threadRoot: threadRoot)
        await markAnswered(roomID: roomID, threadRoot: threadRoot, timeline: timeline)
    }

    /// The timeline to answer in from a notification: the room's, or a thread's own, which puts
    /// what's sent into the thread. The room's send queue takes what's sent from there, as for
    /// anything done in the room itself.
    private func answeringTimeline(roomID: String, threadRoot: String?) async throws -> Timeline {
        guard let room = room(id: roomID) else { throw RoomError.unavailable }
        room.enableSendQueue(enable: true)
        if let threadRoot {
            return try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
                focus: .thread(rootEventId: threadRoot), filter: .all, internalIdPrefix: nil,
                dateDividerMode: .daily, trackReadReceipts: .messageLikeEvents, reportUtds: false))
        }
        return try await room.timeline()
    }

    /// The room read, once a message in it has been answered; for a thread, only the thread:
    /// other messages in the room may still be unread.
    private func markAnswered(roomID: String, threadRoot: String?, timeline: Timeline) async {
        if let threadRoot {
            try? await timeline.markAsRead(receiptType: .read)
            noteRead(roomID: roomID, thread: threadRoot)
        } else {
            setRoom(roomID, unread: false)
        }
    }
}
