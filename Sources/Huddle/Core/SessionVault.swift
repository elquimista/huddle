import Foundation
import MatrixRustSDK
import Security

/// Everything needed to restore one logged-in account.
struct StoredAccount: Codable, Identifiable, Equatable {
    /// Local identifier, also the name of the account's on-disk store folder.
    var id: String
    var userId: String
    var deviceId: String
    var homeserverUrl: String
    var accessToken: String
    var refreshToken: String?
    var oauthData: String?
    var nativeSlidingSync: Bool
    /// Passphrase encrypting the account's SQLite stores.
    var passphrase: String

    var session: Session {
        Session(accessToken: accessToken,
                refreshToken: refreshToken,
                userId: userId,
                deviceId: deviceId,
                homeserverUrl: homeserverUrl,
                oauthData: oauthData,
                slidingSyncVersion: nativeSlidingSync ? .native : .none)
    }

    mutating func update(from session: Session) {
        accessToken = session.accessToken
        refreshToken = session.refreshToken
        deviceId = session.deviceId
        homeserverUrl = session.homeserverUrl
        oauthData = session.oauthData
        nativeSlidingSync = session.slidingSyncVersion == .native
    }
}

/// Thread-safe storage of all account sessions in a single Keychain item.
///
/// Also acts as the SDK's session delegate so refreshed OAuth tokens are
/// persisted as soon as the SDK rotates them.
final class SessionVault: ClientSessionDelegate, @unchecked Sendable {
    static let shared = SessionVault()

    private let lock = NSLock()
    private var accounts: [StoredAccount]

    private init() {
        accounts = Keychain.read().flatMap { try? JSONDecoder().decode([StoredAccount].self, from: $0) } ?? []
    }

    var all: [StoredAccount] {
        lock.withLock { accounts }
    }

    func add(_ account: StoredAccount) {
        lock.withLock {
            accounts.removeAll { $0.userId == account.userId }
            accounts.append(account)
            persist()
        }
    }

    func remove(id: String) {
        lock.withLock {
            accounts.removeAll { $0.id == id }
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        Keychain.write(data)
    }

    // MARK: ClientSessionDelegate

    func retrieveSessionFromKeychain(userId: String) throws -> Session {
        guard let account = lock.withLock({ accounts.first { $0.userId == userId } }) else {
            throw VaultError.unknownUser
        }
        return account.session
    }

    func saveSessionInKeychain(session: Session) {
        lock.withLock {
            guard let index = accounts.firstIndex(where: { $0.userId == session.userId }) else { return }
            accounts[index].update(from: session)
            persist()
        }
    }

    enum VaultError: Error { case unknownUser }
}

private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: AppEnvironment.keychainService,
        kSecAttrAccount as String: "accounts",
    ]

    static func read() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data) {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}
