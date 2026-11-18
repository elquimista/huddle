import Foundation
import MatrixRustSDK

/// Other people's encryption identities: which ones this account has verified, verifying more,
/// and answering a change to one (accepting the new identity, or withdrawing a verification
/// the change undid).
extension AccountSession {
    /// People can be verified only from a verified Mac: verifying signs them with this
    /// account's keys, which a Mac that isn't verified doesn't have.
    var canVerifyPeople: Bool { verification == .verified }

    /// Looks up which of these people this account has verified, from what this Mac knows of
    /// their identities (no server requests).
    func refreshVerifiedPeople(_ userIDs: [String]) async {
        let encryption = client.encryption()
        var verified = verifiedPeople
        for id in userIDs where id != userID {
            let identity = (try? await encryption.userIdentity(userId: id, fallbackToServer: false)) ?? nil
            if identity?.isVerified() == true { verified.insert(id) } else { verified.remove(id) }
        }
        if verified != verifiedPeople { verifiedPeople = verified }
    }

    /// Follows a room's news of identity changes: someone verified is added, someone whose
    /// identity changed since (or was never verified) is not.
    func applyIdentityChanges(_ changes: [IdentityStatusChange]) {
        var verified = verifiedPeople
        for change in changes {
            if change.changedTo == .verified { verified.insert(change.userId) } else { verified.remove(change.userId) }
        }
        if verified != verifiedPeople { verifiedPeople = verified }
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
    }

    /// Stops treating someone as verified, after their identity changed since: the warning goes,
    /// and they can be verified again.
    func withdrawVerification(of userID: String) async throws {
        guard let identity = try await client.encryption().userIdentity(userId: userID, fallbackToServer: true) else { return }
        try await identity.withdrawVerification()
        verifiedPeople.remove(userID)
    }
}
