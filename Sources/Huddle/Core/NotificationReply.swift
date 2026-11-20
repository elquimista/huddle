import AppKit
import MatrixRustSDK
import UserNotifications

/// Answering a message from its notification, as in Messages: a Reply field on the alert. The
/// answer goes into the room as a message of its own (into the thread, for a message in one),
/// written as in the composer, and the room counts as read: it has been answered.
extension Notifier {
    nonisolated static let messageCategory = "message"
    nonisolated static let replyAction = "reply"

    /// The kinds of alert with actions of their own: a message's, with Reply.
    static var categories: Set<UNNotificationCategory> {
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        return [UNNotificationCategory(identifier: messageCategory, actions: [reply], intentIdentifiers: [], options: [])]
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
        content.body = account == nil
            ? "“\(text)” couldn’t be sent."
            : "“\(text)” couldn’t be sent. It’s waiting in the conversation, to send from there."
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
        guard let room = room(id: roomID) else { throw RoomError.unavailable }
        // The room's send queue takes it from here, as for anything typed in the room itself.
        room.enableSendQueue(enable: true)
        let timeline: Timeline
        if let threadRoot {
            // A thread's own timeline puts what's sent into the thread.
            timeline = try await room.timelineWithConfiguration(configuration: TimelineConfiguration(
                focus: .thread(rootEventId: threadRoot), filter: .all, internalIdPrefix: nil,
                dateDividerMode: .daily, trackReadReceipts: .messageLikeEvents, reportUtds: false))
        } else {
            timeline = try await room.timeline()
        }
        _ = try await timeline.send(msg: MentionComposer.content(for: text, mentions: []))
        if threadRoot == nil {
            setRoom(roomID, unread: false)
        } else {
            // Other messages in the room may still be unread; the thread has been answered.
            try? await timeline.markAsRead(receiptType: .read)
        }
    }
}
