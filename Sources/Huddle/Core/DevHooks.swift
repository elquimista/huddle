import AppKit
import Foundation

/// Launch-time automation for the Dev build, driven by environment variables
/// (see Scripts/run-dev.sh). Never runs in the release app.
///
///   HUDDLE_DEV_SERVER    homeserver to sign in to, e.g. http://localhost:8008
///   HUDDLE_DEV_ACCOUNTS  comma-separated usernames to sign in if missing
///   HUDDLE_DEV_PASSWORD  their shared test password
///   HUDDLE_DEV_SELECT    "username" or "username/Room Name" to open at launch
///   HUDDLE_DEV_SIGN_OUT  username to sign out at launch (same code path as the Sign Out menu)
///   HUDDLE_DEV_FRESH     start with no accounts loaded (stored ones are left alone), to see first run
///   HUDDLE_DEV_APPEARANCE  "light" or "dark", overriding the system appearance
///   HUDDLE_DEV_NO_BROWSER  print the OAuth sign-in URL (DEV_OAUTH_URL ...) instead of opening it
@MainActor
enum DevHooks {
    static func applyAppearance() {
        guard AppEnvironment.isDev else { return }
        switch ProcessInfo.processInfo.environment["HUDDLE_DEV_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    /// First-run preview: nothing is restored and no hooks run.
    static var startsFresh: Bool {
        AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_FRESH"] != nil
    }

    static func run(store: AccountStore) async {
        guard AppEnvironment.isDev, !startsFresh else { return }
        let env = ProcessInfo.processInfo.environment

        if let server = env["HUDDLE_DEV_SERVER"], let password = env["HUDDLE_DEV_PASSWORD"] {
            let names = (env["HUDDLE_DEV_ACCOUNTS"] ?? "").split(separator: ",").map(String.init)
            for name in names where !store.accounts.contains(where: { $0.userID.hasPrefix("@\(name):") }) {
                let storeID = UUID().uuidString
                let passphrase = makeStorePassphrase()
                do {
                    let client = try await ClientFactory.makeClient(storeID: storeID,
                                                                    passphrase: passphrase,
                                                                    server: .discover(server))
                    try await client.login(username: name, password: password,
                                           initialDeviceName: "Huddle Dev", deviceId: nil)
                    try store.add(client: client, storeID: storeID, passphrase: passphrase)
                } catch {
                    StorePaths(storeID: storeID).delete()
                    NSLog("DevHooks: signing in \(name) failed: \(error)")
                }
            }
        }

        if let name = env["HUDDLE_DEV_SIGN_OUT"],
           let account = store.accounts.first(where: { $0.userID.hasPrefix("@\(name):") }) {
            await store.signOut(account)
        }

        if let selection = env["HUDDLE_DEV_SELECT"], !selection.isEmpty {
            let parts = selection.split(separator: "/", maxSplits: 1).map(String.init)
            guard let account = store.accounts.first(where: { $0.userID.hasPrefix("@\(parts[0]):") }) else { return }
            store.selectedID = account.id
            guard parts.count > 1 else { return }
            // The room list fills in asynchronously after sync starts.
            for _ in 0..<100 {
                if let room = account.rooms.first(where: { $0.name == parts[1] }) {
                    account.selectedRoomID = room.id
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
