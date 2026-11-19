import Foundation
import MatrixRustSDK

/// Each room's notification setting, kept in the account's push rules as Element keeps it, so it
/// is the same in every app. A room has a setting of its own (all messages, only mentions and
/// keywords, or muted) or follows the account's default for rooms like it. The alerts follow
/// without anything more here: the SDK applies the push rules to decide what notifies.
extension AccountSession {
    /// The SDK's view of the account's push rules, made once.
    func notificationSettings() async -> MatrixRustSDK.NotificationSettings {
        if let task = notificationSettingsTask { return await task.value }
        let task = Task { @MainActor [client] in
            let settings = await client.getNotificationSettings()
            // Changed by another app, or by this one: read them again.
            settings.setDelegate(delegate: NotificationSettingsChanges { [weak self] in
                Task { @MainActor in await self?.loadNotificationModes() }
            })
            return settings
        }
        notificationSettingsTask = task
        return await task.value
    }

    /// Reads the rooms' own settings and the account's defaults from the push rules.
    func loadNotificationModes() async {
        let settings = await notificationSettings()
        var defaults: [NotificationDefaultKind: RoomNotificationMode] = [:]
        var modes: [String: RoomNotificationMode] = [:]
        // Read again if a setting was changed meanwhile: what was read may be from before it.
        var changesSeen = -1
        while changesSeen != notificationChanges {
            changesSeen = notificationChanges
            defaults = [:]
            for isEncrypted in [false, true] {
                for isOneToOne in [false, true] {
                    defaults[NotificationDefaultKind(isEncrypted: isEncrypted, isOneToOne: isOneToOne)] =
                        await settings.getDefaultRoomNotificationMode(isEncrypted: isEncrypted, isOneToOne: isOneToOne)
                }
            }
            modes = [:]
            for roomID in await settings.getRoomsWithUserDefinedRules(enabled: true) {
                if let mode = try? await settings.getUserDefinedRoomNotificationMode(roomId: roomID) { modes[roomID] = mode }
            }
        }
        // A room being changed right now keeps the setting it is being given.
        for roomID in notificationWrites.keys { modes[roomID] = notificationModes[roomID] }
        if defaults != defaultNotificationModes { defaultNotificationModes = defaults }
        if modes != notificationModes {
            notificationModes = modes
            stampNotificationModes()
        }
    }

    /// The setting a room follows when it has none of its own; nil until the defaults are read.
    func defaultNotificationMode(for room: RoomSummary) -> RoomNotificationMode? {
        defaultNotificationModes[NotificationDefaultKind(isEncrypted: room.isEncrypted, isOneToOne: room.isOneToOne)]
    }

    /// Gives a room a setting of its own, or (nil) has it follow the default again. Shown at once.
    func setNotificationMode(_ mode: RoomNotificationMode?, for roomID: String) async throws {
        let previous = notificationModes[roomID]
        guard mode != previous else { return }
        notificationWrites[roomID, default: 0] += 1
        defer {
            notificationWrites[roomID, default: 1] -= 1
            if notificationWrites[roomID] == 0 { notificationWrites[roomID] = nil }
            notificationChanges += 1
        }
        showNotificationMode(mode, for: roomID)
        do {
            let settings = await notificationSettings()
            if let mode {
                try await settings.setRoomNotificationMode(roomId: roomID, mode: mode)
            } else {
                try await settings.restoreDefaultRoomNotificationMode(roomId: roomID)
            }
        } catch {
            showNotificationMode(previous, for: roomID)
            throw error
        }
    }

    private func showNotificationMode(_ mode: RoomNotificationMode?, for roomID: String) {
        notificationModes[roomID] = mode
        stampNotificationModes()
    }

    /// Puts each room's setting on summaries about to replace the list's (see also
    /// `stampNotificationModes()`).
    func stampNotificationModes(on rooms: inout [RoomSummary]) {
        guard !notificationModes.isEmpty || rooms.contains(where: { $0.notificationMode != nil }) else { return }
        for index in rooms.indices { rooms[index].notificationMode = notificationModes[rooms[index].id] }
    }
}

/// Which of the account's defaults applies to a room: the push rules tell encrypted rooms and
/// one-to-one chats apart.
struct NotificationDefaultKind: Hashable {
    let isEncrypted: Bool
    let isOneToOne: Bool
}

extension RoomNotificationMode {
    /// The choices, in the order menus list them.
    static let choices: [RoomNotificationMode] = [.allMessages, .mentionsAndKeywordsOnly, .mute]

    /// As menus name it.
    var title: String {
        switch self {
        case .allMessages: "All Messages"
        case .mentionsAndKeywordsOnly: "Mentions and Keywords"
        case .mute: "Mute"
        }
    }

    /// What it does, in a sentence.
    var explanation: String {
        switch self {
        case .allMessages: "You’re notified of every new message."
        case .mentionsAndKeywordsOnly: "You’re notified only when you’re mentioned or a keyword of yours comes up."
        case .mute: "You’re never notified, and new messages don’t show as unread."
        }
    }

    var symbol: String {
        switch self {
        case .allMessages: "bell"
        case .mentionsAndKeywordsOnly: "at"
        case .mute: "bell.slash"
        }
    }
}

final class NotificationSettingsChanges: NotificationSettingsDelegate, @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func settingsDidChange() { handler() }
}
