import AppKit
import Foundation
import MatrixRustSDK

/// Someone writing a message in a room right now.
struct Typist: Identifiable, Equatable {
    let userID: String
    let name: String
    let avatarURL: String?

    var id: String { userID }
}

/// Who is typing in one room, by name, for its row in the room list. Each room has its own, so
/// a row redraws for its room's typing and no other's.
@MainActor @Observable
final class RoomTypists {
    var names: [String] = []
}

final class TypingObserver: TypingNotificationsListener, @unchecked Sendable {
    private let handler: ([String]) -> Void
    init(_ handler: @escaping ([String]) -> Void) { self.handler = handler }
    func call(typingUserIds: [String]) { handler(typingUserIds) }
}

/// Element's own settings, which it keeps in each account's data on the server.
private let elementSettingsType = "im.vector.web.settings"
/// Element's "Send typing notifications", which it keeps the other way up, under this name.
private let dontSendTypingKey = "dontSendTypingNotifications"

/// Whether people see when this account is typing (and so whether it sees when they are):
/// Element's own setting, so Element, Huddle on other Macs and this one all follow one switch.
extension AccountSession {
    /// Reads the setting now, every 15 seconds after, and whenever Huddle comes to the front
    /// (from changing it in Element, say). It's read from the account's own copy of its data,
    /// which sync keeps current, so it costs nothing: the SDK can't say when one of Element's
    /// settings changes. The account's label (AccountLabel.swift) is read along with it.
    func followTypingSetting() {
        typingSettingTask?.cancel()
        typingSettingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readTypingSetting()
                await self?.readLabel()
                try? await Task.sleep(for: .seconds(15))
            }
        }
        if typingSettingObserver == nil {
            typingSettingObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await self?.readTypingSetting()
                    await self?.readLabel()
                }
            }
        }
    }

    func stopFollowingTypingSetting() {
        typingSettingTask?.cancel()
        typingSettingTask = nil
        typingSettingObserver.map(NotificationCenter.default.removeObserver)
        typingSettingObserver = nil
    }

    private func readTypingSetting() async {
        guard let settings = try? await elementSettings() else { return }
        let shares = !((settings[dontSendTypingKey] as? Bool) ?? false)
        // Just changed here: the account's copy says so only once sync brings the change back.
        if let saved = typingSettingSaved {
            guard shares == saved.value || Date.now.timeIntervalSince(saved.date) > 60 else { return }
            typingSettingSaved = nil
        }
        if shares != sharesTyping { sharesTyping = shares }
    }

    /// Changes the setting in the account's data, leaving the rest of Element's settings as
    /// they are.
    func setSharesTyping(_ shares: Bool) async throws {
        let before = sharesTyping
        sharesTyping = shares
        typingSettingSaved = (shares, .now)
        do {
            var settings = try await elementSettings()
            settings[dontSendTypingKey] = !shares
            let json = try JSONSerialization.data(withJSONObject: settings)
            try await client.setAccountData(eventType: elementSettingsType, content: String(decoding: json, as: UTF8.self))
        } catch {
            sharesTyping = before
            typingSettingSaved = nil
            throw error
        }
    }

    private func elementSettings() async throws -> [String: Any] {
        guard let json = try await client.accountData(eventType: elementSettingsType) else { return [:] }
        return try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] ?? [:]
    }
}
