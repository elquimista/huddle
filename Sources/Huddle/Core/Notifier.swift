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

    /// Asks for permission the first time an account starts syncing.
    func activate() {
        guard !isActivated, let center else { return }
        isActivated = true
        center.delegate = self
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
                  let text = Self.describe(content) else { return }
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
            let callerName = item.senderInfo.displayName ?? senderID.matrixLocalpart
            // A direct chat's name is the caller's; only a room's is worth saying.
            let callRoomName = item.roomInfo.isDm || item.roomInfo.isDirect
                || item.roomInfo.displayName == item.senderInfo.displayName ? nil : item.roomInfo.displayName
            if case .messageLike(.rtcNotification(let type, let expirationTs, let intent)) = content, type == .ring {
                let call = IncomingCall(
                    account: account, roomID: roomID, eventID: event.eventId(),
                    callerName: callerName, callerAvatarURL: item.senderInfo.avatarUrl, callerID: senderID,
                    roomName: callRoomName,
                    isVoice: intent != .video, expires: Date(matrixTimestamp: expirationTs))
                // Rung out before it got here (this Mac was asleep, say): missed.
                if call.expires > .now { CallCenter.shared.ring(call) } else { announceMissedCall(call) }
                return
            } else if case .messageLike(.callInvite) = content {
                // The older kind of one-to-one call, as Element Web makes in a direct chat.
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

        let sender = item.senderInfo.displayName ?? senderID
        let isDirect = item.roomInfo.isDirect && item.roomInfo.joinedMembersCount <= 2
        let recipient = arrival(on: account)

        let content = UNMutableNotificationContent()
        if isDirect {
            content.title = sender
            content.subtitle = [threadRoot != nil ? "In a thread" : nil, recipient]
                .compactMap { $0 }.joined(separator: " · ").capitalizedFirst
        } else {
            content.title = item.roomInfo.displayName
            content.subtitle = [threadRoot != nil ? "\(sender) in a thread" : sender, recipient]
                .compactMap { $0 }.joined(separator: " · ")
        }
        content.body = body
        content.threadIdentifier = Self.group(accountID: account.id, roomID: roomID)
        content.userInfo = ["account": account.id, "room": roomID, "thread": threadRoot ?? ""]
        if item.isNoisy == true, NotificationSettings.playsSound { content.sound = .default }

        // Logged even when alerts are off, so the Dev build can be tested without showing any.
        if AppEnvironment.isDev {
            print("DEV_NOTIFY \(content.title) | \(content.subtitle) | \(content.body) | sound=\(item.isNoisy == true) shown=\(NotificationSettings.isEnabled)")
            fflush(stdout)
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

    private static func describe(_ content: TimelineEventContent) -> String? {
        guard case .messageLike(let content) = content else { return nil }
        switch content {
        case .roomMessage(let type, let inReplyTo):
            // A reply's plain text may begin with the quoted message; the alert shows the answer.
            func plain(_ body: String, _ formatted: FormattedBody?) -> String {
                MessageFormatter.plainText(text: inReplyTo == nil ? body : MessageFormatter.strippingReplyFallback(body),
                                           formatted: formatted)
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
        Task { @MainActor in
            if let accountID, verify {
                self.openVerification(accountID: accountID)
            } else if let accountID, let roomID {
                self.open(accountID: accountID, roomID: roomID, thread: thread)
            }
            completionHandler()
        }
    }

    func open(accountID: String, roomID: String, thread: String?) {
        guard show(accountID: accountID, roomID: roomID, thread: thread) else { return }
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
    func show(accountID: String, roomID: String, thread: String?) -> Bool {
        guard let store, let account = store.accounts.first(where: { $0.id == accountID }) else { return false }
        store.selectedID = accountID
        account.searchText = ""
        account.showRoom(roomID)
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
