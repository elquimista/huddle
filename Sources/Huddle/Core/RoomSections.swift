import Foundation
import MatrixRustSDK

/// A part of the room list: invitations, favourites, people (direct chats), the account's own
/// sections, rooms, and low priority.
///
/// Sections are kept as Element keeps them, so both apps show the same ones:
/// - Favourites and Low Priority are the standard tags (m.favourite, m.lowpriority).
/// - A room in one of the account's own sections carries its tag, `element.io.section.<uuid>`.
///   A room is in one section at most: moving it replaces the tag it had.
/// - The sections' names (and the space each was made in) are Element's account setting
///   `RoomList.CustomSectionData`, and their order, with People and Chats (Rooms here) among
///   them, is `RoomList.OrderedCustomSections`. Element keeps both in the `im.vector.web.settings`
///   account data, beside its other settings, which are left as they are.
struct RoomSection: Identifiable, Equatable {
    enum Kind: Equatable {
        case invites, favourites, custom, lowPriority, people, rooms
    }

    let id: String
    let kind: Kind
    let title: String
    var rooms: [RoomSummary]

    static let invitesID = "invites"
    static let favouritesID = "favourites"
    static let lowPriorityID = "lowPriority"
    static let peopleID = "people"
    static let roomsID = "rooms"

    /// Its place in the order that can be changed, for People, Rooms and the account's own.
    var orderTag: String? {
        switch kind {
        case .custom: id
        case .people: ElementSections.peopleTag
        case .rooms: ElementSections.chatsTag
        default: nil
        }
    }

    /// The section a room belongs in: the first that claims it.
    static func id(for room: RoomSummary, ownSection: String?) -> String {
        if room.isInvite { return invitesID }
        if room.isFavourite { return favouritesID }
        if let ownSection { return ownSection }
        if room.isLowPriority { return lowPriorityID }
        return room.isDirect ? peopleID : roomsID
    }

    /// How its rooms stand, for the badge on a folded section: how many have notifications,
    /// whether any of those need attention now, whether any has anything unread, and whether
    /// any was marked unread on purpose.
    var attention: (count: Int, urgent: Bool, hasUnread: Bool, markedUnread: Bool) {
        (rooms.filter(\.isHighlighted).count, rooms.contains(where: \.isUrgent), rooms.contains(where: \.hasUnread),
         rooms.contains(where: \.isMarkedUnread))
    }
}

/// One of the account's own sections, as Element keeps it.
struct CustomSection: Identifiable, Equatable {
    /// The tag its rooms carry, `element.io.section.<uuid>`.
    var id: String
    var name: String
    /// The space it was made in; Element's "home-space" for none.
    var spaceID: String?
}

/// Where a room can be put: in favourites, one of the account's own sections, low priority,
/// or back in its usual section (people or rooms).
enum SectionPlace: Equatable {
    case favourites
    case custom(String)
    case lowPriority
    case usual
}

/// Element's names for its room list sections, and its reading of them.
enum ElementSections {
    static let settingsEventType = "im.vector.web.settings"
    static let dataKey = "RoomList.CustomSectionData"
    static let orderKey = "RoomList.OrderedCustomSections"
    static let tagPrefix = "element.io.section."
    /// Rooms in no other section: Huddle's Rooms.
    static let chatsTag = "chats"
    /// Direct chats: Huddle's People.
    static let peopleTag = "im.vector.fake.direct"
    static let homeSpace = "home-space"

    static func newTag() -> String { tagPrefix + UUID().uuidString.lowercased() }

    /// The sections in Element's setting, leaving out any that aren't well formed, as it does.
    static func sections(from value: Any?) -> [String: CustomSection] {
        guard let entries = value as? [String: Any] else { return [:] }
        var result: [String: CustomSection] = [:]
        for (tag, value) in entries {
            guard tag.hasPrefix(tagPrefix), let entry = value as? [String: Any], entry["tag"] as? String == tag,
                  let name = entry["name"] as? String else { continue }
            result[tag] = CustomSection(id: tag, name: name, spaceID: entry["spaceId"] as? String)
        }
        return result
    }

    /// The order of People, Chats and the account's own sections, as Element reads it: only
    /// sections that exist, People first and Chats last unless placed elsewhere. A section
    /// missing from the order goes just above Chats, where Element puts new ones.
    static func order(from value: Any?, sections: [String: CustomSection]) -> [String] {
        var order: [String] = []
        for tag in value as? [String] ?? [] where !order.contains(tag)
            && (tag == chatsTag || tag == peopleTag || sections[tag] != nil) {
            order.append(tag)
        }
        if !order.contains(chatsTag) { order.append(chatsTag) }
        if !order.contains(peopleTag) { order.insert(peopleTag, at: 0) }
        for tag in sections.keys.sorted() where !order.contains(tag) {
            order.insert(tag, at: order.firstIndex(of: chatsTag) ?? order.endIndex)
        }
        return order
    }

    static func data(of sections: [String: CustomSection]) -> [String: Any] {
        sections.mapValues { section in
            var entry: [String: Any] = ["tag": section.id, "name": section.name]
            if let spaceID = section.spaceID { entry["spaceId"] = spaceID }
            return entry
        }
    }
}

extension AccountSession {
    /// The account's own sections, in their order.
    var customSections: [CustomSection] {
        sectionOrder.compactMap { sectionData[$0] }
    }

    /// Where a room is now.
    func place(of room: RoomSummary) -> SectionPlace {
        if room.isFavourite { return .favourites }
        if let tag = roomSectionTags[room.id], sectionData[tag] != nil { return .custom(tag) }
        if room.isLowPriority { return .lowPriority }
        return .usual
    }

    /// "People" or "Rooms": where a room goes when it's in none of the others.
    func usualSectionTitle(of room: RoomSummary) -> String {
        room.isDirect ? "People" : "Rooms"
    }

    // MARK: Following the sections

    /// Keeps the rooms' sections and Element's section settings up to date: everything at
    /// first, then every so often what changed (here, in Element, or anywhere else).
    ///
    /// A sliding sync connection of its own, asking only for account data: unlike the older
    /// /sync, it never takes the device's to-device messages (its encryption keys), which the
    /// SDK's own sync needs.
    func followSections() async {
        var position: String?
        // Only once the rooms and their sections are known can earlier sections be moved over
        // without taking rooms out of sections Element put them in.
        while !Task.isCancelled, position == nil || allRooms.isEmpty {
            if position == nil { position = await syncSections(from: nil) }
            if position == nil || allRooms.isEmpty { try? await Task.sleep(for: .seconds(2)) }
        }
        await migrateHuddleSections()
        while !Task.isCancelled {
            if sectionWrites == 0 { position = await syncSections(from: position) }
            try? await Task.sleep(for: .seconds(position == nil ? 10 : 30))
        }
    }

    /// One round: returns where the next one starts (nil to start over).
    private func syncSections(from position: String?) async -> String? {
        let body: [String: Any] = [
            "conn_id": "huddle-sections",
            "lists": ["all": ["ranges": [[0, 99_999]], "timeline_limit": 0, "required_state": [] as [Any]]],
            "extensions": ["account_data": ["enabled": true]],
        ]
        var query = [URLQueryItem(name: "timeout", value: "0")]
        if let position { query.append(URLQueryItem(name: "pos", value: position)) }
        guard let (status, json) = try? await clientAPI("POST", "../unstable/org.matrix.simplified_msc3575/sync",
                                                        query: query, body: body) else { return position }
        guard status == 200, let next = json["pos"] as? String else {
            // The server has forgotten the connection: start over.
            return status == 400 ? nil : position
        }
        // A change made here meanwhile: this answer may not have it yet. Ask again next time.
        guard sectionWrites == 0 else { return position }
        let accountData = (json["extensions"] as? [String: Any])?["account_data"] as? [String: Any] ?? [:]
        var settings: [String: Any]?
        for event in accountData["global"] as? [[String: Any]] ?? []
            where event["type"] as? String == ElementSections.settingsEventType {
            settings = event["content"] as? [String: Any] ?? [:]
        }
        if let settings {
            showSettings(settings)
        } else if position == nil {
            showSettings([:])
        }
        var tags = position == nil ? [:] : roomSectionTags
        for (roomID, events) in accountData["rooms"] as? [String: [[String: Any]]] ?? [:] {
            for event in events where event["type"] as? String == "m.tag" {
                let names = ((event["content"] as? [String: Any])?["tags"] as? [String: Any])?.keys
                tags[roomID] = names?.sorted().first { $0.hasPrefix(ElementSections.tagPrefix) }
            }
        }
        if tags != roomSectionTags { roomSectionTags = tags }
        return next
    }

    private func showSettings(_ settings: [String: Any]) {
        let sections = ElementSections.sections(from: settings[ElementSections.dataKey])
        let order = ElementSections.order(from: settings[ElementSections.orderKey], sections: sections)
        if sections != sectionData { sectionData = sections }
        if order != sectionOrder { sectionOrder = order }
    }

    // MARK: Changing them

    /// Puts a room in one place, taking it out of the one it was in.
    func move(_ roomID: String, to place: SectionPlace) async throws {
        guard let room = room(id: roomID), let summary = allRooms.first(where: { $0.id == roomID }) else { return }
        let oldTag = roomSectionTags[roomID]
        var newTag: String?
        if case .custom(let tag) = place { newTag = tag }
        let favourite = place == .favourites
        let lowPriority = place == .lowPriority
        sectionWrites += 1
        defer { sectionWrites -= 1 }
        showTags(of: roomID, favourite: favourite, lowPriority: lowPriority)
        roomSectionTags[roomID] = newTag
        do {
            if let oldTag, oldTag != newTag { try await setTag(oldTag, on: roomID, to: false) }
            if let newTag, newTag != oldTag { try await setTag(newTag, on: roomID, to: true) }
            if summary.isFavourite != favourite { try await room.setIsFavourite(isFavourite: favourite, tagOrder: nil) }
            if summary.isLowPriority != lowPriority {
                try await room.setIsLowPriority(isLowPriority: lowPriority, tagOrder: nil)
            }
        } catch {
            showTags(of: roomID, favourite: summary.isFavourite, lowPriority: summary.isLowPriority)
            roomSectionTags[roomID] = oldTag
            throw error
        }
    }

    /// Adds a section of the account's own, just above Rooms (Element's Chats), as Element does,
    /// noting the space showing. Returns its tag.
    @discardableResult
    func createSection(named name: String, inSpace spaceID: String?? = .none) async throws -> String {
        let section = CustomSection(id: ElementSections.newTag(),
                                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                    spaceID: (spaceID ?? selectedSpaceID) ?? ElementSections.homeSpace)
        try await updateSections { sections, order in
            sections[section.id] = section
            order.insert(section.id, at: order.firstIndex(of: ElementSections.chatsTag) ?? order.endIndex)
        }
        return section.id
    }

    func renameSection(_ tag: String, to name: String) async throws {
        try await updateSections { sections, _ in
            sections[tag]?.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Removes one of the account's own sections; its rooms go back to their usual sections.
    func deleteSection(_ tag: String) async throws {
        try await updateSections { sections, order in
            sections[tag] = nil
            order.removeAll { $0 == tag }
        }
        collapsedSections.remove(tag)
        // Element leaves the tag on the rooms, where it means nothing any more; take it off.
        for (roomID, roomTag) in roomSectionTags where roomTag == tag {
            roomSectionTags[roomID] = nil
            try? await setTag(tag, on: roomID, to: false)
        }
    }

    /// Moves People, Rooms or one of the account's own sections up (-1) or down (+1).
    func moveSection(_ orderTag: String, by offset: Int) async throws {
        try await updateSections { _, order in
            guard let index = order.firstIndex(of: orderTag), order.indices.contains(index + offset) else { return }
            order.swapAt(index, index + offset)
        }
    }

    func canMoveSection(_ orderTag: String, by offset: Int) -> Bool {
        guard let index = sectionOrder.firstIndex(of: orderTag) else { return false }
        return sectionOrder.indices.contains(index + offset)
    }

    /// Marks every room in a section read.
    func markAllRead(in section: RoomSection) {
        for room in section.rooms where Self.isUnread(room) { setRoom(room.id, unread: false) }
    }

    /// Changes the sections in Element's settings: read fresh from the server, so nothing
    /// changed elsewhere is lost, changed, shown at once, and written back with every other
    /// setting in it as it was.
    private func updateSections(_ change: (inout [String: CustomSection], inout [String]) -> Void) async throws {
        sectionWrites += 1
        defer { sectionWrites -= 1 }
        let path = "user/\(Self.pathComponent(userID))/account_data/\(ElementSections.settingsEventType)"
        let (status, current) = try await clientAPI("GET", path)
        guard status == 200 || status == 404 else { throw ClientAPIError.refused(status: status, message: current["error"] as? String) }
        var settings = status == 200 ? current : [:]
        var sections = ElementSections.sections(from: settings[ElementSections.dataKey])
        var order = ElementSections.order(from: settings[ElementSections.orderKey], sections: sections)
        change(&sections, &order)
        settings[ElementSections.dataKey] = ElementSections.data(of: sections)
        settings[ElementSections.orderKey] = order
        let previous = (sectionData, sectionOrder)
        showSettings(settings)
        let (written, reply) = try await clientAPI("PUT", path, body: settings)
        guard written == 200 else {
            (sectionData, sectionOrder) = previous
            throw ClientAPIError.refused(status: written, message: reply["error"] as? String)
        }
    }

    /// Adds or removes one of a room's tags.
    private func setTag(_ tag: String, on roomID: String, to present: Bool) async throws {
        let path = "user/\(Self.pathComponent(userID))/rooms/\(Self.pathComponent(roomID))/tags/\(Self.pathComponent(tag))"
        let (status, reply) = try await clientAPI(present ? "PUT" : "DELETE", path, body: present ? [String: Any]() : nil)
        guard status == 200 else { throw ClientAPIError.refused(status: status, message: reply["error"] as? String) }
    }

    // MARK: Huddle's own earlier sections

    /// Sections made before Huddle kept them as Element does (in `app.huddle.room_sections`)
    /// become Element sections, once: their rooms are put in them unless already in a section,
    /// and the old record is emptied.
    private func migrateHuddleSections() async {
        let type = "app.huddle.room_sections"
        guard let json = try? await client.accountData(eventType: type),
              let content = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any],
              let old = content["sections"] as? [[String: Any]], !old.isEmpty else { return }
        for entry in old {
            guard let name = entry["name"] as? String else { continue }
            let rooms = entry["rooms"] as? [String] ?? []
            guard let tag = try? await createSection(named: name, inSpace: .some(nil)) else { return }
            for roomID in rooms {
                guard let room = allRooms.first(where: { $0.id == roomID }),
                      place(of: room) == .usual, !room.isLowPriority else { continue }
                try? await move(roomID, to: .custom(tag))
            }
        }
        try? await client.setAccountData(eventType: type, content: #"{"sections":[]}"#)
    }
}
