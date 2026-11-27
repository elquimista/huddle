import AppKit
import Foundation
import MatrixRustSDK
import UniformTypeIdentifiers

/// The account's recovery key, which unlocks its encryption keys kept on the server: setting one
/// up, changing it, and, for an account that has lost both its other devices and its key,
/// starting its encryption over.
extension AccountSession {
    /// A recovery key can be set up or changed only from a verified Mac: one that isn't has no
    /// keys to lock with it, and the SDK won't replace the backup it can't read.
    var managesRecoveryKey: Bool { verification == .verified && recoveryState != .unknown }

    /// Whether to suggest setting up a recovery key: this Mac could, and the account has none.
    var suggestsRecoveryKey: Bool { verification == .verified && recoveryState == .disabled }

    /// Makes a recovery key and keeps the account's keys on the server locked with it. Returns
    /// the key, for the person to save.
    func setUpRecoveryKey() async throws -> String {
        try await client.encryption().enableRecovery(waitForBackupsToUpload: false, key: nil,
                                                     progressListener: RecoveryProgressListener())
    }

    /// Deletes the account's key backup on the server, which this Mac has no key for, so a new
    /// one can take its place: the SDK only deletes a backup it is connected to. Versions go
    /// newest first, until none is left.
    func deleteUnreadableKeyBackup() async throws {
        for _ in 0..<10 {
            let (status, json) = try await clientAPI("GET", "room_keys/version")
            if status == 404 { return }
            guard status == 200, let version = json["version"] as? String else {
                throw ClientAPIError.refused(status: status, message: json["error"] as? String)
            }
            let (deleted, answer) = try await clientAPI("DELETE", "room_keys/version/\(Self.pathComponent(version))")
            guard deleted == 200 || deleted == 404 else {
                throw ClientAPIError.refused(status: deleted, message: answer["error"] as? String)
            }
        }
    }

    /// A new recovery key in place of the old, which stops working. With the keys it unlocks
    /// already on this Mac the old one isn't needed; without them (`.incomplete`) it is.
    func changeRecoveryKey(current: String?) async throws -> String {
        if let current {
            return try await client.encryption().recoverAndReset(oldRecoveryKey: current)
        }
        return try await client.encryption().resetRecoveryKey()
    }

    /// Starts the account's encryption over: new cross-signing keys made here, its key backup
    /// and recovery key deleted. Nil if it's done already; otherwise the server wants the
    /// account's password, or approval on its sign-in page, to finish.
    func beginIdentityReset() async throws -> IdentityResetHandle? {
        try await client.encryption().resetIdentity()
    }
}

/// Saving a recovery key: to the clipboard, marked so clipboard managers don't keep it, or to a
/// text file only its owner can read.
@MainActor
enum RecoveryKeyKeeper {
    static func copy(_ key: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // nspasteboard.org's convention: clipboard managers and history skip concealed items.
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString(key, forType: .string)
    }

    /// Asks where to save it, and saves it. Calls back with where it went, if it did.
    static func save(_ key: String, for userID: String, done: @escaping (URL?) -> Void) {
        let text = "Recovery key for \(userID)\n\n\(key)\n"
        if let url = DevHooks.savePath {
            done(write(text, to: url) ? url : nil)
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Recovery Key (\(userID.matrixLocalpart)).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return done(nil) }
            if write(text, to: url) {
                done(url)
            } else {
                let alert = NSAlert()
                alert.messageText = "The recovery key couldn’t be saved."
                alert.informativeText = "Choose another place, or copy it instead."
                alert.runModal()
                done(nil)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Readable by its owner only, from before the key is in it: made that way, or, replacing a
    /// file that wasn't, made so before anything is written.
    private static func write(_ text: String, to url: URL) -> Bool {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        guard fchmod(descriptor, 0o600) == 0 else { return false }
        do {
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
            return true
        } catch {
            return false
        }
    }
}

final class RecoveryListener: RecoveryStateListener, @unchecked Sendable {
    private let handler: (RecoveryState) -> Void
    init(_ handler: @escaping (RecoveryState) -> Void) { self.handler = handler }
    func onUpdate(status: RecoveryState) { handler(status) }
}

/// Setting up without waiting for keys to upload is quick: nothing to show along the way.
private final class RecoveryProgressListener: EnableRecoveryProgressListener, @unchecked Sendable {
    func onUpdate(status: EnableRecoveryProgress) {}
}
