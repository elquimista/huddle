import AppKit
import MatrixRustSDK
import UserNotifications

/// The user's choices in Settings. Alerts start off in the Dev build, where test traffic would
/// otherwise flood Notification Center.
enum NotificationSettings {
    static let enabledKey = "notificationsEnabled"
    static let soundKey = "notificationSound"
    static let enabledByDefault = !AppEnvironment.isDev

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? enabledByDefault
    }

    static var playsSound: Bool {
        UserDefaults.standard.object(forKey: soundKey) as? Bool ?? true
    }
}

/// Posts macOS notifications for the events the SDK says should notify (it applies the
/// account's push rules, so muted rooms and "mentions only" are already respected), and opens
/// the right account and room when one is clicked.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    weak var store: AccountStore?

    /// Events older than this were sent while the app was closed; the badges cover those.
    private let launchDate = Date()
    private var isActivated = false
    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    private var notifiedInvites = Set(UserDefaults.standard.stringArray(forKey: "notifiedInvites") ?? [])

    /// `UNUserNotificationCenter` only works inside an app bundle.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") ? .current() : nil
    }

    /// Takes answers to alerts from the start. The answer that launched Huddle (a click, or a
    /// reply typed while it was closed) goes only to a delegate set before launching ends.
    func attach() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(Self.categories)
    }

    /// Asks for permission the first time an account starts syncing.
    func activate() {
        guard !isActivated, let center else { return }
        isActivated = true
        center.delegate = self
        center.setNotificationCategories(Self.categories)
        // Alerts left over from before they were turned off.
        if !NotificationSettings.isEnabled { center.removeAllDeliveredNotifications() }
        // `.badge` matters even though the Dock badge is set directly: once an app uses
        // notifications, macOS hides its Dock badge unless badges are part of the permission.
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            guard AppEnvironment.isDev else { return }
            center.getNotificationSettings { settings in
                print("DEV_NOTIFY_PERMISSION granted=\(granted) badge=\(settings.badgeSetting == .enabled) \(error?.localizedDescription ?? "")")
                fflush(stdout)
            }
        }
    }

    // MARK: Posting

    func handle(_ item: NotificationItem, roomID: String, account: AccountSession) {
        let key: String
        let senderID: String
        let body: String
        var threadRoot: String?

        switch item.event {
        case .timeline(let event):
            senderID = event.senderId()
            guard senderID != account.userID,
                  Date(timeIntervalSince1970: TimeInterval(event.timestamp()) / 1000) >= launchDate,
                  let content = try? event.content(),
                  let text = Self.describe(content, contactName: { [account] in account.contactName(for: $0) }) else { return }
            body = text
            threadRoot = item.threadId ?? event.threadRootEventId()
            key = "\(account.id)|\(roomID)|\(event.eventId())"
            guard seen.insert(key).inserted else { return }
            // Only the latest are worth remembering: a repeat comes soon after, if at all.
            seenOrder.append(key)
            if seenOrder.count > 2000 {
                for old in seenOrder.prefix(1000) { seen.remove(old) }
                seenOrder.removeFirst(1000)
            }
            // Someone ringing: the call panel, whether or not the room is in front, and not an
            // alert as well. A ring that goes unanswered leaves a missed call (CallCenter).
            let callerName = account.contactName(for: senderID) ?? Self.senderName(item, senderID)
            // A direct chat's name is the caller's; only a room's is worth saying.
            let callRoomName = item.roomInfo.isDm || item.roomInfo.isDirect
                || Self.roomName(item) == ShownName.clean(item.senderInfo.displayName) ? nil : Self.roomName(item)
            if case .messageLike(.rtcNotification(let type, let expirationTs, let intent)) = content, type == .ring {
                let call = IncomingCall(
                    account: account, roomID: roomID, eventID: event.eventId(),
                    callerName: callerName, callerAvatarURL: item.senderInfo.avatarUrl, callerID: senderID,
                    roomName: callRoomName,
                    isVoice: intent != .video,
                    // As long as the caller says, up to two minutes (LegacyCall.longestRing).
                    expires: min(Date(matrixTimestamp: expirationTs), Date().addingTimeInterval(LegacyCall.longestRing)))
                // Rung out before it got here (this Mac was asleep, say): missed.
                if call.expires > .now { CallCenter.shared.ring(call) } else { announceMissedCall(call) }
                return
            } else if case .messageLike(.callInvite) = content, item.roomInfo.joinedMembersCount <= 2 {
                // The older kind of one-to-one call, as Element Web makes in a direct chat: only
                // ever between two people, so in a bigger room it doesn't ring.
                if CallCenter.shared.ringLegacy(
                    invite: item.rawEvent, account: account, roomID: roomID, callerName: callerName,
                    callerAvatarURL: item.senderInfo.avatarUrl, callerID: senderID, roomName: callRoomName) {
                    return
                }
            }
        case .invite(let sender):
            senderID = sender
            body = "Invited you to join"
            key = "\(account.id)|\(roomID)|invite"
            guard notifiedInvites.insert(key).inserted else { return }
            UserDefaults.standard.set(Array(notifiedInvites), forKey: "notifiedInvites")
        }

        // Nothing to announce when the conversation is already in front of the user, or a click
        // away: Settings in front of it, say, or a picture open over it. But with Huddle's window
        // out of sight (in the Dock, on another desktop), the alert is all there is to see.
        if NSApp.isActive, MainWindow.isOnScreen, store?.selected?.id == account.id, account.selectedRoomID == roomID {
            if let threadRoot {
                if account.sidePanels[roomID] == .thread(threadRoot) { return }
            } else {
                return
            }
        }

        // The user's own name for them, where they've given one (ContactNames.swift).
        let sender = account.contactName(for: senderID) ?? Self.senderName(item, senderID)
        let isDirect = item.roomInfo.isDirect && item.roomInfo.joinedMembersCount <= 2
        let recipient = arrival(on: account)

        let content = UNMutableNotificationContent()
        if isDirect {
            content.title = sender
            content.subtitle = [threadRoot != nil ? "In a thread" : nil, recipient]
                .compactMap { $0 }.joined(separator: " · ").capitalizedFirst
        } else {
            content.title = Self.roomName(item)
            content.subtitle = [threadRoot != nil ? "\(sender) in a thread" : sender, recipient]
                .compactMap { $0 }.joined(separator: " · ")
        }
        content.body = body
        content.threadIdentifier = Self.group(accountID: account.id, roomID: roomID)
        content.userInfo = ["account": account.id, "room": roomID, "thread": threadRoot ?? "",
                            "roomName": Self.roomName(item)]
        if item.isNoisy == true, NotificationSettings.playsSound { content.sound = .default }
        // A message can be answered from its alert; an invitation is answered in the app.
        if case .timeline = item.event { content.categoryIdentifier = Self.messageCategory }

        // Logged even when alerts are off, so the Dev build can be tested without showing any.
        if AppEnvironment.isDev {
            print("DEV_NOTIFY \(content.title) | \(content.subtitle) | \(content.body) | sound=\(item.isNoisy == true) shown=\(NotificationSettings.isEnabled) category=\(content.categoryIdentifier)")
            fflush(stdout)
            // Dev testing: answers the alert as if typed into its Reply field. Only on the account
            // showing, so two test accounts never answer each other back and forth.
            if let text = DevHooks.notificationReply, content.categoryIdentifier == Self.messageCategory,
               store?.selected?.id == account.id {
                let thread = threadRoot
                let roomName = Self.roomName(item)
                Task { await self.reply(text, accountID: account.id, roomID: roomID, thread: thread, roomName: roomName) }
            }
        }
        guard NotificationSettings.isEnabled else { return }
        center?.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    /// Which account it arrived on, said only when there's more than one: by the label the user
    /// gave it ("on Work", AccountLabel.swift); without one, "on acme.com", by its server, which
    /// tells a work account from a personal one where their names are usually the same
    /// person's; by its full Matrix ID when another of the accounts is on that server too.
    /// Worded as a place, so it isn't taken for whom a message was written to.
    private func arrival(on account: AccountSession) -> String? {
        guard let accounts = store?.accounts, accounts.count > 1 else { return nil }
        if let label = account.label { return "on " + label }
        let server = account.userID.matrixServer
        let shared = accounts.contains { $0.id != account.id && $0.userID.matrixServer == server }
        return "on " + (shared ? account.userID : server)
    }

    /// A call that rang and went unanswered, here and on the account's other devices. It stays in
    /// Notification Center, as a missed call does, and opens the room when clicked.
    func announceMissedCall(_ call: IncomingCall) {
        let recipient = arrival(on: call.account)
        let content = UNMutableNotificationContent()
        content.title = call.title
        content.subtitle = [call.roomName != nil ? call.callerName : nil, recipient]
            .compactMap { $0 }.joined(separator: " · ").capitalizedFirst
        content.body = call.isVoice ? "Missed voice call" : "Missed call"
        content.threadIdentifier = Self.group(accountID: call.account.id, roomID: call.roomID)
        content.userInfo = ["account": call.account.id, "room": call.roomID, "thread": ""]
        if AppEnvironment.isDev {
            print("DEV_NOTIFY \(content.title) | \(content.subtitle) | \(content.body) | shown=\(NotificationSettings.isEnabled)")
            fflush(stdout)
        }
        guard NotificationSettings.isEnabled else { return }
        center?.add(UNNotificationRequest(identifier: "\(call.account.id)|\(call.roomID)|\(call.eventID)|missed",
                                          content: content, trigger: nil))
    }

    /// A request to verify, when Huddle isn't in front, its window is out of sight, or the
    /// account isn't the one showing. Clicked, it opens the request.
    func announceVerificationRequest(for account: AccountSession) {
        if NSApp.isActive, MainWindow.isOnScreen, store?.selected?.id == account.id { return }
        NSApp.requestUserAttention(.informationalRequest)
        guard let summary = account.verificationFlow.requestSummary else { return }
        let content = UNMutableNotificationContent()
        content.title = "Verification Request"
        if let arrival = arrival(on: account) { content.subtitle = arrival.capitalizedFirst }
        content.body = summary
        content.userInfo = ["account": account.id, "verify": true]
        if NotificationSettings.playsSound { content.sound = .default }
        if AppEnvironment.isDev {
            print("DEV_NOTIFY \(content.title) | \(content.subtitle) | \(content.body) | shown=\(NotificationSettings.isEnabled)")
            fflush(stdout)
        }
        guard NotificationSettings.isEnabled else { return }
        center?.add(UNNotificationRequest(identifier: "\(account.id)|verify", content: content, trigger: nil))
    }

    /// Who it's from: their name made safe to show, with their Matrix ID after it if someone else
    /// in the room goes by the same name (ShownName), or their Matrix ID if they have none.
    private static func senderName(_ item: NotificationItem, _ senderID: String) -> String {
        ShownName.person(item.senderInfo.displayName, userID: senderID, isAmbiguous: item.senderInfo.isNameAmbiguous)
    }

    /// The room's name, made safe to show (ShownName).
    private static func roomName(_ item: NotificationItem) -> String {
        ShownName.clean(item.roomInfo.displayName) ?? "Unnamed room"
    }

    private static func describe(_ content: TimelineEventContent, contactName: (String) -> String?) -> String? {
        guard case .messageLike(let content) = content else { return nil }
        switch content {
        case .roomMessage(let type, let inReplyTo):
            // A reply's plain text may begin with the quoted message; the alert shows the answer.
            func plain(_ body: String, _ formatted: FormattedBody?) -> String {
                MessageFormatter.plainText(text: inReplyTo == nil ? body : MessageFormatter.strippingReplyFallback(body),
                                           formatted: formatted, contactName: contactName)
            }
            switch type {
            case .text(let content): return plain(content.body, content.formatted)
            case .notice(let content): return plain(content.body, content.formatted)
            case .emote(let content): return "* " + plain(content.body, content.formatted)
            // Files are named, as they are in the room list.
            case .image(let content): return AttachmentText.line(name: content.filename, caption: content.caption, kind: "Image")
            case .video(let content): return AttachmentText.line(name: content.filename, caption: content.caption, kind: "Video")
            case .audio(let content):
                return content.voice != nil ? "Voice message"
                    : AttachmentText.line(name: content.filename, caption: content.caption, kind: "Audio")
            case .file(let content): return AttachmentText.line(name: content.filename, caption: content.caption, kind: "File")
            case .gallery: return "Sent images"
            case .location: return "Shared a location"
            case .other(_, let body): return body
            }
        case .roomEncrypted: return "Sent an encrypted message"
        case .sticker: return "Sent a sticker"
        case .poll(let question): return "Poll: \(question)"
        case .callInvite, .rtcNotification: return "Started a call"
        default: return nil
        }
    }

    // MARK: Clearing

    /// Removes a room's notifications once it has been read, here or on another device.
    func clear(accountID: String, roomID: String? = nil) {
        guard let center else { return }
        let prefix = roomID.map { Self.group(accountID: accountID, roomID: $0) } ?? "\(accountID)|"
        center.getDeliveredNotifications { delivered in
            let stale = delivered
                .filter { $0.request.content.threadIdentifier.hasPrefix(prefix) }
                .map(\.request.identifier)
            if AppEnvironment.isDev {
                print("DEV_NOTIFY_CLEAR \(prefix) removed=\(stale.count) delivered=\(delivered.count)")
                fflush(stdout)
            }
            if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        }
    }

    private static func group(accountID: String, roomID: String) -> String { "\(accountID)|\(roomID)" }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Without this, nothing is shown while the app is frontmost (on another room, say).
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let accountID = info["account"] as? String
        let roomID = info["room"] as? String
        let thread = info["thread"] as? String
        let verify = info["verify"] as? Bool ?? false
        let roomName = info["roomName"] as? String ?? ""
        let replyText = response.actionIdentifier == Self.replyAction
            ? (response as? UNTextInputNotificationResponse)?.userText : nil
        let identifier = response.notification.request.identifier
        Task { @MainActor in
            if let replyText, let accountID, let roomID {
                // Answered: the alert has done its job.
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
                await self.reply(replyText, accountID: accountID, roomID: roomID, thread: thread, roomName: roomName)
            } else if let accountID, verify {
                await self.waitForAccount(accountID)
                self.openVerification(accountID: accountID)
            } else if let accountID, let roomID {
                // Clicked while Huddle was closed: it opens the room once the account is back.
                await self.waitForAccount(accountID)
                self.open(accountID: accountID, roomID: roomID, thread: thread)
            }
            completionHandler()
        }
    }

    func open(accountID: String, roomID: String, thread: String?) {
        // At the newest message, which is what the notification was about.
        guard show(accountID: accountID, roomID: roomID, thread: thread, atNewest: true) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Brings up a request to verify, if it's still waiting.
    private func openVerification(accountID: String) {
        guard let store, let account = store.accounts.first(where: { $0.id == accountID }) else { return }
        store.selectedID = accountID
        if account.verificationFlow.step == .incoming, account.sheet == nil, !account.verificationFlow.isShown {
            account.sheet = .verify
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Goes to a notification's account and room, with the room list on the room's space, and
    /// its thread if it's a reply in one. False if the account has gone.
    @discardableResult
    func show(accountID: String, roomID: String, thread: String?, atNewest: Bool = false) -> Bool {
        guard let store, let account = store.accounts.first(where: { $0.id == accountID }) else { return false }
        store.selectedID = accountID
        account.searchText = ""
        account.showRoom(roomID, atNewest: atNewest)
        if let thread, !thread.isEmpty { account.sidePanels[roomID] = .thread(thread) }
        return true
    }
}

final class NotificationListener: SyncNotificationListener, @unchecked Sendable {
    private let handler: (NotificationItem, String) -> Void
    init(_ handler: @escaping (NotificationItem, String) -> Void) { self.handler = handler }
    func onNotification(notification: NotificationItem, roomId: String) { handler(notification, roomId) }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
