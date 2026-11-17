import AppKit
import Foundation

/// Launch-time automation for the Dev build, driven by environment variables
/// (see Scripts/run-dev.sh). Never runs in the release app.
///
///   HUDDLE_DEV_SERVER    homeserver to sign in to, e.g. http://localhost:8008
///   HUDDLE_DEV_ACCOUNTS  comma-separated usernames to sign in if missing
///   HUDDLE_DEV_PASSWORD  their shared test password
///   HUDDLE_DEV_SELECT    "username" or "username/Room Name" to open at launch
///   HUDDLE_DEV_THREAD    with HUDDLE_DEV_SELECT: "list", or text of a message whose thread to open
///   HUDDLE_DEV_SIGN_OUT  username to sign out at launch (same code path as the Sign Out menu)
///   HUDDLE_DEV_FRESH     start with no accounts loaded (stored ones are left alone), to see first run
///   HUDDLE_DEV_APPEARANCE  "light" or "dark", overriding the system appearance
///   HUDDLE_DEV_ASSUME_ACTIVE  mark rooms as read even while the app is in the background
///   HUDDLE_DEV_HOVER     text of a message to show the hover actions on ("text!" also opens its emoji picker)
///   HUDDLE_DEV_MUTE_AUDIO  play audio messages silently (Scripts/run-dev.sh sets this)
///   HUDDLE_DEV_AUDIO_DEVICE  UID of the output device to play through, instead of the Mac's default
///   HUDDLE_DEV_AUDIO_DELAY   seconds to stall before audio starts, standing in for a slow output device
///   HUDDLE_DEV_IMAGE_DELAY   seconds to wait before each image loads, to see the placeholders
///   HUDDLE_DEV_STAGE         comma-separated image paths to put in the composer at launch, as if dropped there
///   HUDDLE_DEV_FREE_SCROLL   treat scrolling done through accessibility as the user's, so tests can scroll up
///   HUDDLE_DEV_CROP_THUMBNAILS  send images with a square thumbnail cropped from the middle, as some phone apps do
///   HUDDLE_DEV_SLOW_ANIMATIONS  slow the timeline's animations down by this factor, to inspect them
///   HUDDLE_DEV_PRESENCE_INTERVAL  seconds between presence checks, instead of 30 and 90
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

    private static func openThread(_ request: String?, in roomID: String, of account: AccountSession) async {
        guard let request, !request.isEmpty else { return }
        if request == "list" {
            account.sidePanels[roomID] = .threadList
            return
        }
        // The timeline fills in asynchronously after the room opens.
        for _ in 0..<50 {
            let rows = account.timeline(for: roomID)?.rows ?? []
            for row in rows.reversed() {
                if case .message(let message) = row.kind, case .text(let text) = message.body,
                   text.contains(request), let eventID = message.eventID {
                    account.sidePanels[roomID] = .thread(eventID)
                    return
                }
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    static let assumesActive = AppEnvironment.isDev
        && ProcessInfo.processInfo.environment["HUDDLE_DEV_ASSUME_ACTIVE"] != nil

    /// Stands in for the pointer, which automation cannot move over the Dev app.
    static let hoverText: String? = AppEnvironment.isDev ? ProcessInfo.processInfo.environment["HUDDLE_DEV_HOVER"] : nil

    /// Keeps test runs from making noise.
    static let mutesAudio = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_MUTE_AUDIO"] != nil

    static let audioDevice: String? = AppEnvironment.isDev ? ProcessInfo.processInfo.environment["HUDDLE_DEV_AUDIO_DEVICE"] : nil

    static let audioStartDelay: TimeInterval = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_AUDIO_DELAY"].flatMap(TimeInterval.init) ?? 0 : 0

    nonisolated static let presenceInterval: TimeInterval? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_PRESENCE_INTERVAL"].flatMap(TimeInterval.init) : nil

    nonisolated static let cropsThumbnails = AppEnvironment.isDev
        && ProcessInfo.processInfo.environment["HUDDLE_DEV_CROP_THUMBNAILS"] != nil

    nonisolated static let imageLoadDelay: TimeInterval = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_IMAGE_DELAY"].flatMap(TimeInterval.init) ?? 0 : 0

    static var didStageImages = false

    static let freeScroll = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_FREE_SCROLL"] != nil

    /// Images to stage in the composer of the room opened at launch.
    static let stagedImagePaths: [String] = AppEnvironment.isDev
        ? (ProcessInfo.processInfo.environment["HUDDLE_DEV_STAGE"] ?? "").split(separator: ",").map(String.init) : []

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
                    await openThread(env["HUDDLE_DEV_THREAD"], in: room.id, of: account)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
