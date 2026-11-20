import Foundation
import MatrixRustSDK

/// Names of the user's own for the people they talk to ("Mum", "Sam from work"), as phones keep
/// contacts. Shown in place of a person's name wherever Huddle names them for this account (their
/// messages, their direct chat, mentions, typing, receipts, notifications), with their own name
/// still in Room Info. Only the user sees them: a mention still sends the person's own name,
/// which is what the room reads. Kept in the account's own data on the server, under a type of
/// Huddle's, so Huddle on the user's other Macs has them; other apps leave it alone. Matrix has
/// no standard place for them.
private let contactsEventType = "app.huddle.contacts"

extension AccountSession {
    /// The user's name for someone, if they've given one.
    func contactName(for userID: String) -> String? { contactNames[userID] }

    /// Reads the names from the account's own copy of its data, which sync keeps current (read
    /// along with the typing setting, in Typing.swift).
    func readContactNames() async {
        let json = try? await client.accountData(eventType: contactsEventType)
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let names = Self.cleaned(object?["names"] as? [String: Any] ?? [:])
        // Just changed here: the account's copy says so only once sync brings the change back.
        if let saved = contactNamesSaved {
            guard names == saved.value || Date.now.timeIntervalSince(saved.date) > 60 else { return }
            contactNamesSaved = nil
        }
        if names != contactNames { applyContactNames(names) }
    }

    /// Names someone, or takes the name away with nil or nothing but spaces.
    func setContactName(_ name: String?, for userID: String) async throws {
        var names = contactNames
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[userID] = trimmed.isEmpty ? nil : trimmed
        guard names != contactNames else { return }
        let before = contactNames
        applyContactNames(names)
        contactNamesSaved = (names, .now)
        do {
            let json = try JSONSerialization.data(withJSONObject: ["names": names])
            try await client.setAccountData(eventType: contactsEventType, content: String(decoding: json, as: UTF8.self))
        } catch {
            applyContactNames(before)
            contactNamesSaved = nil
            throw error
        }
    }

    /// Takes new names, and has everything showing names draw them again: the open
    /// conversations, and the room list's names and previews.
    private func applyContactNames(_ names: [String: String]) {
        contactNames = names
        for timeline in allTimelines { timeline.namesChanged() }
        refreshRoomSummaries()
    }

    private static func cleaned(_ raw: [String: Any]) -> [String: String] {
        raw.compactMapValues { value in
            let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
    }
}

/// What a room is called with the user's names for people in it: a direct chat goes by the name
/// given to the person, and a room with no name of its own, which the server's software calls
/// after some of its people ("Bob, Carol", "Bob, Carol and 3 others"), has the given names in
/// place of theirs. Nil when the names change nothing.
enum ContactRoomName {
    static func name(computed: String?, hasOwnName: Bool, isDirect: Bool, heroes: [RoomHero],
                     names: [String: String]) -> String? {
        guard !names.isEmpty, !hasOwnName || isDirect && heroes.count == 1 else { return nil }
        if isDirect, heroes.count == 1 { return names[heroes[0].userId] }
        guard let computed, heroes.contains(where: { names[$0.userId] != nil }) else { return nil }
        // The people are listed as the name lists them: in the order given, or sorted.
        func own(_ hero: RoomHero) -> String { hero.displayName ?? hero.userId }
        let sorted = heroes.sorted { own($0).localizedStandardCompare(own($1)) == .orderedAscending }
        for order in [heroes, sorted] {
            let theirs = order.map(own).joined(separator: ", ")
            guard computed.hasPrefix(theirs) else { continue }
            let ours = order.map { names[$0.userId] ?? own($0) }.joined(separator: ", ")
            return ours + computed.dropFirst(theirs.count)
        }
        return nil
    }
}

extension RoomInfo {
    /// Whether the room has a name, or an address, of its own, rather than one made from its people.
    var hasOwnName: Bool { !(rawName ?? "").isEmpty || canonicalAlias != nil }
}
