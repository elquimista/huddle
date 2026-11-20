import AppKit
import Foundation
import MatrixRustSDK
import Perception

/// All logged-in accounts. Every account syncs concurrently.
@MainActor @Perceptible
final class AccountStore {
    private(set) var accounts: [AccountSession] = []
    private(set) var isRestoring = true
    private(set) var restoreErrors: [String] = []
    var selectedID: String? {
        didSet {
            UserDefaults.standard.set(selectedID, forKey: "selectedAccount")
            RoomHistory.shared.noteChange()
        }
    }
    var isAddingAccount = false
    /// Go ▸ Go to Room… (⌘K) is open.
    var isGoingToRoom = false

    /// Whether the keys that move around (Go menu) wait: while something is over the
    /// conversation, which has its own keys (a sheet, the picture viewer, Go to Room itself).
    var navigationPaused: Bool {
        selected?.sheet != nil || isAddingAccount || isGoingToRoom || ImageViewerState.shared.item != nil
    }

    /// The next account along (or the one before), round to the first again.
    func selectAccount(step: Int) {
        guard accounts.count > 1 else { return }
        let index = accounts.firstIndex { $0.id == selected?.id } ?? 0
        selectedID = accounts[((index + step) % accounts.count + accounts.count) % accounts.count].id
    }

    var selected: AccountSession? {
        accounts.first { $0.id == selectedID } ?? accounts.first
    }

    var totalBadgeCount: Int { accounts.reduce(0) { $0 + $1.badgeCount } }

    func restore() async {
        DevHooks.applyAppearance()
        IndexingSchedule.shared.start()
        RoomHistory.shared.store = self
        NavigationKeys.shared.start(store: self)
        Notifier.shared.store = self
        // An earlier build wrote images being viewed to a temporary folder. Nothing does now;
        // this clears anything that build left behind.
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "app.huddle.Huddle") + ".preview", isDirectory: true))
        MediaLoader.clearOpenedFiles()
        if !DevHooks.startsFresh { await restoreStoredAccounts() }
        isRestoring = false
        await DevHooks.run(store: self)
    }

    private func restoreStoredAccounts() async {
        let stored = SessionVault.shared.all
        let restored = await withTaskGroup(of: (Int, Result<Client, Error>).self) { group in
            for (index, account) in stored.enumerated() {
                group.addTask {
                    do {
                        var client = try await ClientFactory.makeClient(
                            storeID: account.id,
                            passphrase: account.passphrase,
                            server: .known(url: account.homeserverUrl, nativeSlidingSync: account.nativeSlidingSync))
                        try await client.restoreSession(session: account.session)
                        if DevHooks.clearsCaches(for: account.userId) {
                            // Its caches emptied, and with them where sync had got to (kept with
                            // the keys, and reset only through a sync service), the SDK asks for
                            // a client made afresh.
                            let syncService = try await client.syncService().finish()
                            try await client.clearCaches(syncService: syncService)
                            client = try await ClientFactory.makeClient(
                                storeID: account.id,
                                passphrase: account.passphrase,
                                server: .known(url: account.homeserverUrl, nativeSlidingSync: account.nativeSlidingSync))
                            try await client.restoreSession(session: account.session)
                        }
                        return (index, .success(client))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Int: Result<Client, Error>]()
            for await (index, result) in group { results[index] = result }
            return results
        }

        for (index, account) in stored.enumerated() {
            switch restored[index] {
            case .success(let client):
                let session = AccountSession(id: account.id, userID: account.userId, client: client)
                accounts.append(session)
                Task { await session.start() }
            case .failure(let error):
                restoreErrors.append("\(account.userId): \(error.actionMessage)")
            case nil:
                break
            }
        }
        selectedID = UserDefaults.standard.string(forKey: "selectedAccount") ?? accounts.first?.id
    }

    /// Registers a freshly logged-in client as a new account.
    func add(client: Client, storeID: String, passphrase: String) throws {
        let session = try client.session()
        guard session.slidingSyncVersion == .native else {
            throw LoginError.slidingSyncUnsupported
        }
        let stored = StoredAccount(id: storeID,
                                   userId: session.userId,
                                   deviceId: session.deviceId,
                                   homeserverUrl: session.homeserverUrl,
                                   accessToken: session.accessToken,
                                   refreshToken: session.refreshToken,
                                   oauthData: session.oauthData,
                                   nativeSlidingSync: true,
                                   passphrase: passphrase)
        SessionVault.shared.add(stored)
        let account = AccountSession(id: storeID, userID: session.userId, client: client)
        accounts.append(account)
        selectedID = account.id
        Task { await account.start() }
    }

    func isLoggedIn(userID: String) -> Bool {
        accounts.contains { $0.userID == userID }
    }

    func signOut(_ account: AccountSession) async {
        await account.stop()
        Notifier.shared.clear(accountID: account.id)
        try? await account.client.logout()
        SessionVault.shared.remove(id: account.id)
        accounts.removeAll { $0.id == account.id }
        StorePaths(storeID: account.id).delete()
        UserDefaults.standard.removeObject(forKey: "drafts.\(account.id)")
        if selectedID == account.id { selectedID = accounts.first?.id }
    }
}

enum LoginError: LocalizedError {
    case slidingSyncUnsupported
    case alreadyLoggedIn(String)
    case noSupportedLoginMethod
    case cancelled

    var errorDescription: String? {
        switch self {
        case .slidingSyncUnsupported:
            "This homeserver doesn’t support native sliding sync (MSC4186), which Huddle requires."
        case .alreadyLoggedIn(let userID):
            "\(userID) is already signed in."
        case .noSupportedLoginMethod:
            "This homeserver offers no login method Huddle supports."
        case .cancelled:
            "Sign-in was cancelled."
        }
    }
}
