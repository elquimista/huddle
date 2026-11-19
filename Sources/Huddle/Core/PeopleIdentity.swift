import Foundation
import MatrixRustSDK

/// What this account knows of someone's encryption identity.
enum PersonIdentity: Equatable {
    case verified
    /// They have one, and it hasn't been verified: the usual case.
    case unverified
    /// It changed since this account first saw it, and the change hasn't been accepted.
    case changed
    /// It changed after they were verified.
    case changedSinceVerified
    /// They have none: their app hasn't set up cross-signing, so there's nothing to verify.
    case noIdentity

    /// Something to warn about, rather than a status.
    var isChange: Bool { self == .changed || self == .changedSinceVerified }
}

/// Other people's encryption identities: what is known of each, verifying them, and answering a
/// change to one (accepting the new identity, or withdrawing a verification the change undid).
extension AccountSession {
    /// People can be verified only from a verified Mac: verifying signs them with this
    /// account's keys, which a Mac that isn't verified doesn't have.
    var canVerifyPeople: Bool { verification == .verified }

    /// Whether someone could be verified from here now.
    func canVerify(_ userID: String) -> Bool {
        guard canVerifyPeople, userID != self.userID else { return false }
        switch peopleIdentities[userID] {
        case .verified, .changedSinceVerified, .noIdentity: return false
        case .unverified, .changed, nil: return true
        }
    }

    /// Looks up these people's identities, a few at a time. From the server, for people this Mac
    /// doesn't keep track of (it does only for people it shares an encrypted room with): their
    /// status would otherwise be missing in an unencrypted room.
    func refreshIdentities(of userIDs: [String], fromServer: Bool) async {
        let encryption = client.encryption()
        let ids = userIDs.filter { $0 != userID }
        var found: [String: PersonIdentity] = [:]
        for start in stride(from: 0, to: ids.count, by: 6) {
            let batch = ids[start..<min(start + 6, ids.count)]
            await withTaskGroup(of: (String, PersonIdentity?).self) { group in
                for id in batch {
                    group.addTask {
                        do {
                            // None found: from the server, they have none; from this Mac, it isn't known.
                            guard let identity = try await encryption.userIdentity(userId: id, fallbackToServer: fromServer)
                            else { return (id, fromServer ? .noIdentity : nil) }
                            if identity.isVerified() { return (id, .verified) }
                            if identity.hasVerificationViolation() { return (id, .changedSinceVerified) }
                            return (id, .unverified)
                        } catch {
                            return (id, nil)
                        }
                    }
                }
                for await (id, identity) in group {
                    if let identity { found[id] = identity }
                }
            }
        }
        var identities = peopleIdentities
        for (id, identity) in found {
            // A change not yet accepted is known only from a room's identity stream: an
            // identity that merely isn't verified doesn't undo it.
            if identity == .unverified, identities[id] == .changed { continue }
            identities[id] = identity
        }
        if identities != peopleIdentities { peopleIdentities = identities }
    }

    /// Follows a room's news of identity changes.
    func applyIdentityChanges(_ changes: [IdentityStatusChange]) {
        var identities = peopleIdentities
        for change in changes {
            identities[change.userId] = switch change.changedTo {
            case .verified: .verified
            case .pinned: .unverified
            case .pinViolation: .changed
            case .verificationViolation: .changedSinceVerified
            }
        }
        if identities != peopleIdentities { peopleIdentities = identities }
    }

    /// Asks someone to verify with this account, showing the verification sheet.
    func verify(person userID: String, name: String?) {
        verificationFlow.verifyPerson(userID, name: name)
        if !verificationFlow.isShown { sheet = .verify }
    }

    /// Accepts someone's new identity: it is remembered in place of the old, and the warning
    /// about the change goes.
    func acceptIdentity(of userID: String) async throws {
        guard let identity = try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) else { return }
        try await identity.pin()
        if peopleIdentities[userID] == .changed { peopleIdentities[userID] = .unverified }
    }

    /// Stops treating someone as verified, after their identity changed since: the warning goes,
    /// and they can be verified again.
    func withdrawVerification(of userID: String) async throws {
        guard let identity = try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) else { return }
        try await identity.withdrawVerification()
        peopleIdentities[userID] = .unverified
    }
}
