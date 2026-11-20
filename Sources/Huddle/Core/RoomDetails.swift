import Foundation
import MatrixRustSDK

/// What the Room Info panel shows and changes: a room's name, topic and picture, whether it is
/// encrypted, and who is in it. Follows the room as it changes (here or on another device), and
/// knows what this account may change.
@MainActor @Observable
final class RoomDetails {
    struct Member: Identifiable, Equatable {
        var id: String { userID }
        let userID: String
        let name: String
        let avatarURL: String?
        let isInvited: Bool
        /// "Admin", "Moderator" or "Owner"; nil for everyone else.
        let role: String?
        /// Their power level; an owner's (a creator's, in newer rooms) is above any number.
        let powerLevel: Int64
    }

    /// A role someone could be given, for the Role menu.
    struct RoleChoice: Identifiable, Equatable {
        var id: Int64 { level }
        /// "Admin", "Moderator", "Member", or "Custom (75)" for a level that is none of them.
        let title: String
        let level: Int64
        let isCurrent: Bool
        /// False for a role above what this account may give.
        let isAllowed: Bool
    }

    let roomID: String
    private(set) var name = ""
    /// What makes the name, for the user's names for people (ContactRoomName).
    private(set) var nameSource: (hasOwnName: Bool, heroes: [RoomHero]) = (false, [])
    private(set) var topic: String?
    private(set) var avatarURL: String?
    private(set) var isEncrypted = false
    private(set) var isDirect = false
    private(set) var canChangeName = false
    private(set) var canChangeTopic = false
    private(set) var canChangeAvatar = false
    private(set) var canTurnOnEncryption = false
    private(set) var canInvite = false
    private(set) var canRemoveMembers = false
    private(set) var canChangeRoles = false
    /// The power level of those given none: a plain member's.
    private(set) var usersDefault: Int64 = 0
    private(set) var members: [Member] = []
    private(set) var membersLoaded = false
    private(set) var joinedCount = 0
    private(set) var invitedCount = 0

    @ObservationIgnored private let room: Room
    @ObservationIgnored private let ownUserID: String
    @ObservationIgnored private var handle: TaskHandle?
    @ObservationIgnored private var memberTask: Task<Void, Never>?
    /// The power levels given to people, last seen: when they change, so do roles.
    @ObservationIgnored private var userLevels: [String: Int64] = [:]

    init(room: Room, ownUserID: String) {
        self.room = room
        self.ownUserID = ownUserID
        roomID = room.id()
        handle = room.subscribeToRoomInfoUpdates(listener: RoomInfoObserver { [weak self] info in
            Task { @MainActor in self?.update(from: info) }
        })
        Task {
            if let info = try? await room.roomInfo() { update(from: info) }
            loadMembers()
        }
    }

    private func update(from info: RoomInfo) {
        name = info.displayName ?? info.rawName ?? ""
        nameSource = (info.hasOwnName, info.heroes)
        topic = info.topic.flatMap { $0.isEmpty ? nil : $0 }
        avatarURL = info.avatarUrl
        isEncrypted = info.encryptionState == .encrypted
        isDirect = info.isDirect
        let counts = (Int(info.joinedMembersCount), Int(info.invitedMembersCount))
        let levels = info.powerLevels?.userPowerLevels() ?? userLevels
        if counts != (joinedCount, invitedCount) || levels != userLevels {
            (joinedCount, invitedCount) = counts
            userLevels = levels
            // Someone joined, left, was invited or had their role changed: the list is out of date.
            if membersLoaded { loadMembers() }
        }
        Task { await updatePermissions() }
    }

    /// What this account's power level in the room lets it change.
    private func updatePermissions() async {
        guard let levels = try? await room.getPowerLevels() else { return }
        canChangeName = levels.canOwnUserSendState(stateEvent: .roomName)
        canChangeTopic = levels.canOwnUserSendState(stateEvent: .roomTopic)
        canChangeAvatar = levels.canOwnUserSendState(stateEvent: .roomAvatar)
        canTurnOnEncryption = !isEncrypted && levels.canOwnUserSendState(stateEvent: .roomEncryption)
        canInvite = levels.canOwnUserInvite()
        canRemoveMembers = levels.canOwnUserKick()
        canChangeRoles = levels.canOwnUserSendState(stateEvent: .roomPowerLevels)
        usersDefault = levels.values().usersDefault
    }

    /// The name, with the user's names for people where it's made from theirs.
    func shownName(names: [String: String]) -> String {
        ContactRoomName.name(computed: name, hasOwnName: nameSource.hasOwnName, isDirect: isDirect,
                             heroes: nameSource.heroes, names: names) ?? name
    }

    /// This account's power level here, once the members are known.
    var ownPowerLevel: Int64? { members.first { $0.userID == ownUserID }?.powerLevel }

    /// The roles someone could be given, or nil if this account can't change theirs. Only those
    /// below this account can be changed (or the account itself, but only downwards), and to
    /// no higher than this account's own level. An owner's role can't be changed at all.
    func roleChoices(for member: Member) -> [RoleChoice]? {
        guard canChangeRoles, let own = ownPowerLevel, member.powerLevel != .max else { return nil }
        let isSelf = member.userID == ownUserID
        guard isSelf || member.powerLevel < own else { return nil }
        var choices: [RoleChoice] = []
        for (title, level) in [("Admin", Int64(100)), ("Moderator", 50), ("Member", usersDefault)]
        where !choices.contains(where: { $0.level == level }) {
            let isCurrent = member.powerLevel == level
            choices.append(RoleChoice(title: title, level: level, isCurrent: isCurrent,
                                      isAllowed: isCurrent || (isSelf ? level < own : level <= own)))
        }
        if !choices.contains(where: \.isCurrent) {
            choices.insert(RoleChoice(title: "Custom (\(member.powerLevel))", level: member.powerLevel,
                                      isCurrent: true, isAllowed: true), at: 0)
        }
        return choices.contains { $0.isAllowed && !$0.isCurrent } ? choices : nil
    }

    func isOwnAccount(_ member: Member) -> Bool { member.userID == ownUserID }

    /// Whether this account may take someone out of the room (or withdraw their invitation):
    /// only those below its own power level, and never itself.
    func canRemove(_ member: Member) -> Bool {
        guard canRemoveMembers, member.userID != ownUserID,
              let own = members.first(where: { $0.userID == ownUserID }) else { return false }
        return own.powerLevel > member.powerLevel
    }

    /// Everyone in the room or invited to it.
    var memberIDs: Set<String> { Set(members.map(\.userID)) }

    /// Everyone joined or invited: owners and admins first, then by name.
    func loadMembers() {
        memberTask?.cancel()
        memberTask = Task {
            guard let iterator = try? await room.members() else { return }
            var result: [Member] = []
            while let chunk = iterator.nextChunk(chunkSize: 200) {
                for member in chunk {
                    let isInvited: Bool
                    switch member.membership {
                    case .join: isInvited = false
                    case .invite: isInvited = true
                    default: continue
                    }
                    let role: String? = switch member.suggestedRoleForPowerLevel {
                    case .creator: "Owner"
                    case .administrator: "Admin"
                    case .moderator: "Moderator"
                    case .user: nil
                    }
                    let level: Int64 = switch member.powerLevel {
                    case .infinite: .max
                    case .value(let value): value
                    }
                    result.append(Member(userID: member.userId, name: member.displayName ?? member.userId,
                                         avatarURL: member.avatarUrl, isInvited: isInvited, role: role,
                                         powerLevel: level))
                }
            }
            guard !Task.isCancelled else { return }
            let rank: (Member) -> Int = { member in
                switch member.role {
                case "Owner": 0
                case "Admin": 1
                case "Moderator": 2
                default: member.isInvited ? 4 : 3
                }
            }
            members = result.sorted {
                rank($0) != rank($1) ? rank($0) < rank($1)
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            membersLoaded = true
        }
    }

    // MARK: Changes

    func setName(_ name: String) async throws {
        try await room.setName(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func setTopic(_ topic: String) async throws {
        try await room.setTopic(topic: topic.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Makes a picture the room's, prepared as `AvatarImage` describes.
    func setAvatar(from url: URL) async throws {
        let image = try AvatarImage(contentsOf: url)
        try await room.uploadAvatar(mimeType: image.mimeType, data: image.data, mediaInfo: image.info)
    }

    func removeAvatar() async throws {
        try await room.removeAvatar()
    }

    /// Gives someone a role, as its power level.
    func setPowerLevel(_ level: Int64, for userID: String) async throws {
        try await room.updatePowerLevelsForUsers(updates: [UserPowerLevelUpdate(userId: userID, powerLevel: level)])
    }

    /// Takes someone out of the room, or withdraws their invitation if they haven't joined.
    func remove(_ userID: String) async throws {
        try await room.kickUser(userId: userID, reason: nil)
    }

    /// For good: a room's encryption can't be turned off again.
    func turnOnEncryption() async throws {
        try await room.enableEncryption()
    }

    func stop() {
        handle?.cancel()
        handle = nil
        memberTask?.cancel()
    }
}
