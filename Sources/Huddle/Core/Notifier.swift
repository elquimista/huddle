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
        case .invite(let sender):
            senderID = sender
            body = "Invited you to join"
            key = "\(account.id)|\(roomID)|invite"
            guard notifiedInvites.insert(key).inserted else { return }
            UserDefaults.standard.set(Array(notifiedInvites), forKey: "notifiedInvites")
        }

        // Nothing to announce when the conversation is already in front of the user.
        if NSApp.isActive, store?.selected?.id == account.id, account.selectedRoomID == roomID {
            if let threadRoot {
                if account.sidePanels[roomID] == .thread(threadRoot) { return }
            } else {
                return
            }
        }

        let sender = item.senderInfo.displayName ?? senderID
        let isDirect = item.roomInfo.isDirect && item.roomInfo.joinedMembersCount <= 2
        let recipient = (store?.accounts.count ?? 1) > 1 ? "for \(account.displayName ?? account.userID)" : nil

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

    private static func describe(_ content: TimelineEventContent) -> String? {
        guard case .messageLike(let content) = content else { return nil }
        switch content {
        case .roomMessage(let type, _):
            switch type {
            case .text(let content): return MessageFormatter.plainText(text: content.body, formatted: content.formatted)
            case .notice(let content): return MessageFormatter.plainText(text: content.body, formatted: content.formatted)
            case .emote(let content): return "* " + MessageFormatter.plainText(text: content.body, formatted: content.formatted)
            case .image(let content): return content.caption ?? "Sent an image"
            case .video(let content): return content.caption ?? "Sent a video"
            case .audio(let content):
                return content.caption ?? (content.voice != nil ? "Sent a voice message" : "Sent an audio file: \(content.filename)")
            case .file(let content): return content.caption ?? "Sent a file: \(content.filename)"
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
        Task { @MainActor in
            if let accountID, let roomID { self.open(accountID: accountID, roomID: roomID, thread: thread) }
            completionHandler()
        }
    }

    func open(accountID: String, roomID: String, thread: String?) {
        guard let store, let account = store.accounts.first(where: { $0.id == accountID }) else { return }
        store.selectedID = accountID
        account.searchText = ""
        account.selectedRoomID = roomID
        if let thread, !thread.isEmpty { account.sidePanels[roomID] = .thread(thread) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
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
