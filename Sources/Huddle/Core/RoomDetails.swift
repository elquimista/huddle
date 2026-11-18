import AppKit
import Foundation
import MatrixRustSDK
import UniformTypeIdentifiers

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

    let roomID: String
    private(set) var name = ""
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
    private(set) var members: [Member] = []
    private(set) var membersLoaded = false
    private(set) var joinedCount = 0
    private(set) var invitedCount = 0

    @ObservationIgnored private let room: Room
    @ObservationIgnored private let ownUserID: String
    @ObservationIgnored private var handle: TaskHandle?
    @ObservationIgnored private var memberTask: Task<Void, Never>?

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
        topic = info.topic.flatMap { $0.isEmpty ? nil : $0 }
        avatarURL = info.avatarUrl
        isEncrypted = info.encryptionState == .encrypted
        isDirect = info.isDirect
        let counts = (Int(info.joinedMembersCount), Int(info.invitedMembersCount))
        if counts != (joinedCount, invitedCount) {
            (joinedCount, invitedCount) = counts
            // Someone joined, left or was invited: the list is out of date.
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
    }

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

    /// Makes a picture the room's: cropped to a square from its middle and scaled to 512
    /// points across, as JPEG (PNG if it has see-through parts).
    func setAvatar(from url: URL) async throws {
        let data = try Data(contentsOf: url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
              ] as CFDictionary),
              let square = Self.squared(image, side: 512) else {
            throw RoomDetailsError.unreadableImage
        }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(square.alphaInfo)
        let type: UTType = hasAlpha ? .png : .jpeg
        guard let encoded = ImagePreparer.encode(square, as: type, quality: 0.85) else {
            throw RoomDetailsError.unreadableImage
        }
        let info = ImageInfo(height: UInt64(square.height), width: UInt64(square.width),
                             mimetype: type.preferredMIMEType, size: UInt64(encoded.count),
                             thumbnailInfo: nil, thumbnailSource: nil, blurhash: nil, isAnimated: false)
        try await room.uploadAvatar(mimeType: type.preferredMIMEType ?? "image/jpeg", data: encoded, mediaInfo: info)
    }

    func removeAvatar() async throws {
        try await room.removeAvatar()
    }

    /// Takes someone out of the room, or withdraws their invitation if they haven't joined.
    func remove(_ userID: String) async throws {
        try await room.kickUser(userId: userID, reason: nil)
    }

    /// For good: a room's encryption can't be turned off again.
    func turnOnEncryption() async throws {
        try await room.enableEncryption()
    }

    /// The middle square of a picture, scaled to `side` pixels across (or less, if smaller),
    /// with see-through parts only if the picture had any.
    private static func squared(_ image: CGImage, side: Int) -> CGImage? {
        let length = min(image.width, image.height)
        let crop = CGRect(x: (image.width - length) / 2, y: (image.height - length) / 2, width: length, height: length)
        guard let cropped = image.cropping(to: crop) else { return nil }
        let target = min(side, length)
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        guard let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: alpha.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: target, height: target))
        return context.makeImage()
    }

    func stop() {
        handle?.cancel()
        handle = nil
        memberTask?.cancel()
    }
}

enum RoomDetailsError: LocalizedError {
    case unreadableImage

    var errorDescription: String? {
        switch self {
        case .unreadableImage: "That picture couldn't be read. Try a JPEG, PNG or HEIC image."
        }
    }
}
