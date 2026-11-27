import CryptoKit
import Foundation

/// An account's unsent messages, kept across launches, encrypted, in its store's folder.
///
/// What's being written in an encrypted room is as private as what's been sent there, so it
/// isn't kept in the plain preferences file, where drafts were until 1.4.4 (any of those are
/// moved in here the first time). The key comes from the passphrase of the account's store,
/// kept in the Keychain with its session, so it needs no Keychain item of its own; signing out
/// deletes the folder, and the drafts with it.
struct DraftsFile {
    private let url: URL
    private let key: SymmetricKey

    init(storeID: String, passphrase: String) {
        url = StorePaths(storeID: storeID).data.appendingPathComponent("drafts")
        key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(passphrase.utf8)),
                                     salt: Data("app.huddle.drafts".utf8), info: Data(), outputByteCount: 32)
    }

    /// The drafts' text, by draft key ("room", or "room|thread root"). Empty if there are none,
    /// or the file can't be read (its key isn't this one, say).
    func read() -> [String: String] {
        guard let sealed = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: sealed),
              let plain = try? AES.GCM.open(box, using: key),
              let drafts = try? JSONDecoder().decode([String: String].self, from: plain) else { return [:] }
        return drafts
    }

    /// Replaces what's kept. No drafts, no file.
    func write(_ drafts: [String: String]) throws {
        let manager = FileManager.default
        guard !drafts.isEmpty else {
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
            return
        }
        guard let sealed = try AES.GCM.seal(try JSONEncoder().encode(drafts), using: key).combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The drafts kept, moving any left in the preferences file by an earlier version in here.
    /// Those stay where they were unless they're safely written here.
    func readMoving(fromDefaultsKey key: String) -> [String: String] {
        guard let old = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else { return read() }
        // Anything already here is newer than what was left behind.
        let drafts = read().merging(old) { kept, _ in kept }
        guard (try? write(drafts)) != nil else { return drafts }
        UserDefaults.standard.removeObject(forKey: key)
        return drafts
    }
}
