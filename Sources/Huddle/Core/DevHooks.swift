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
///   HUDDLE_DEV_SEARCH    with HUDDLE_DEV_SELECT: opens the search beside the room with this query
///                        (HUDDLE_DEV_SEARCH_ALL=1 for every room)
///   HUDDLE_DEV_SPACE     with HUDDLE_DEV_SELECT: name of a space (one of the account's, or an
///                        invitation) to browse at launch; "" for all rooms
///   HUDDLE_DEV_SHEET     with HUDDLE_DEV_SPACE: newRoom, newSpace, addRooms or leave, to open that sheet;
///                        profile, password, devices or verify for the account's own; manage for its OAuth account page
///   HUDDLE_DEV_NOTIFICATION  with HUDDLE_DEV_SPACE: name of a room to open as clicking its notification
///                        does, once the space is showing (without bringing the app forward)
///   HUDDLE_DEV_SIGN_OUT  username to sign out at launch (same code path as the Sign Out menu)
///   HUDDLE_DEV_FRESH     start with no accounts loaded (stored ones are left alone), to see first run
///   HUDDLE_DEV_APPEARANCE  "light" or "dark", overriding the system appearance
///   HUDDLE_DEV_ASSUME_ACTIVE  mark rooms as read even while the app is in the background
///   HUDDLE_DEV_HOVER     text of a message to show the hover actions on ("text!" also opens its emoji picker)
///   HUDDLE_DEV_MUTE_AUDIO  play audio messages silently (Scripts/run-dev.sh sets this)
///   HUDDLE_DEV_AUDIO_DEVICE  UID of the output device to play through, instead of the Mac's default
///   HUDDLE_DEV_AUDIO_DELAY   seconds to stall before audio starts, standing in for a slow output device
///   HUDDLE_DEV_IMAGE_DELAY   seconds to wait before each image loads, to see the placeholders
///   HUDDLE_DEV_STAGE         comma-separated paths of pictures or files to put in the composer at launch,
///                        as if dropped there (in the room HUDDLE_DEV_SELECT names)
///   HUDDLE_DEV_DOWNLOAD_TO   a folder each file shown in a conversation is downloaded into, as Save File As would
///   HUDDLE_DEV_FREE_SCROLL   treat scrolling done through accessibility as the user's, so tests can scroll up
///   HUDDLE_DEV_CROP_THUMBNAILS  send images with a square thumbnail cropped from the middle, as some phone apps do
///   HUDDLE_DEV_SLOW_ANIMATIONS  slow the timeline's animations down by this factor, to inspect them
///   HUDDLE_DEV_PRESENCE_INTERVAL  seconds between presence checks, instead of 30 and 90
///   HUDDLE_DEV_NO_BROWSER  print the OAuth sign-in URL (DEV_OAUTH_URL ...) instead of opening it
///   HUDDLE_DEV_PICK_FILE  a picture file to take as chosen, in place of the open panel (Room Info, Edit Profile)
///   HUDDLE_DEV_UPDATE_FEED  appcast URL to look for updates at (the Dev build otherwise never does);
///                        build with HUDDLE_SPARKLE_PUBLIC_KEY set to the key its updates are signed with
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

    /// Browses a space by name and, if asked, opens one of its sheets.
    private static func openSpace(_ name: String, sheet: String?, in account: AccountSession) async {
        for _ in 0..<100 {
            if name.isEmpty {
                account.show(space: nil)
                break
            }
            if let space = account.spaces.first(where: { $0.displayName == name }) {
                account.browse(space: space.roomId)
                break
            }
            if let invite = account.invitedSpaces.first(where: { $0.name == name }) {
                account.selectedRoomID = nil
                account.browsingSpaceID = invite.id
                break
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let roomName = ProcessInfo.processInfo.environment["HUDDLE_DEV_NOTIFICATION"] {
            // Once the rooms and what each space holds are known, as they would be by then.
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<50 {
                if !account.spaceFilters.isEmpty,
                   let room = account.allRooms.first(where: { $0.name == roomName && !$0.isSpace }) {
                    Notifier.shared.show(accountID: account.id, roomID: room.id, thread: nil)
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        guard let sheet else { return }
        // Editable spaces are known a moment after the spaces themselves.
        try? await Task.sleep(for: .seconds(1))
        let spaceID = account.selectedSpaceID ?? ""
        switch sheet {
        case "newRoom": account.sheet = .newRoom(inSpace: account.selectedSpaceID)
        case "newSpace": account.sheet = .newSpace
        case "addRooms": account.sheet = .addRooms(toSpace: spaceID)
        case "leave": account.sheet = .leaveSpace(spaceID)
        case "profile": account.sheet = .profile
        case "password": account.sheet = .changePassword
        case "devices": account.sheet = .devices
        case "verify": account.sheet = .verify
        case "manage": openAccountPage(of: account)
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
    /// A file to take as chosen wherever a picture is asked for, in place of the open panel.
    static let pickedFile: String? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_PICK_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        : nil

    /// A folder every file shown in a conversation is downloaded into, as Save File As would,
    /// so tests can check what arrives without a save panel or opening another app.
    static let fileDownloadFolder: URL? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_DOWNLOAD_TO"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        : nil

    /// A test appcast for Check for Updates. Without one the Dev build doesn't look for updates.
    nonisolated static let updateFeed: String? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_UPDATE_FEED"].flatMap { $0.isEmpty ? nil : $0 }
        : nil

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
    /// Gives every message its actions as accessibility actions even without VoiceOver, so tests
    /// can reach them.
    static let accessibilityActions = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_AX_ACTIONS"] != nil
    /// Milliseconds between pages of the full-history pass (HUDDLE_DEV_INDEX_PAUSE), to watch its
    /// progress on a test server whose rooms would otherwise be done in moments.
    static let indexPauseMilliseconds: Int? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_INDEX_PAUSE"].flatMap(Int.init) : nil

    /// Images to stage in the composer of the room opened at launch.
    static let stagedImagePaths: [String] = AppEnvironment.isDev
        ? (ProcessInfo.processInfo.environment["HUDDLE_DEV_STAGE"] ?? "").split(separator: ",").map(String.init) : []

    /// Whether to stage those in this room: the one HUDDLE_DEV_SELECT names, if it names one,
    /// rather than a room opened before it (the one last open, say).
    static func stagesFiles(inRoomNamed name: String?) -> Bool {
        guard !stagedImagePaths.isEmpty, !didStageImages else { return false }
        let selected = ProcessInfo.processInfo.environment["HUDDLE_DEV_SELECT"] ?? ""
        guard let slash = selected.firstIndex(of: "/") else { return true }
        return name == String(selected[selected.index(after: slash)...])
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
            if let space = env["HUDDLE_DEV_SPACE"] {
                await openSpace(space, sheet: env["HUDDLE_DEV_SHEET"], in: account)
                return
            }
            guard parts.count > 1 else { return }
            // The room list fills in asynchronously after sync starts.
            for _ in 0..<100 {
                if let room = account.allRooms.first(where: { $0.name == parts[1] && !$0.isSpace }) {
                    // Show it in the list too, which a space selected last time might hide.
                    if let space = account.selectedSpaceID, !account.roomIDs(inSpace: space).contains(room.id) {
                        account.selectedSpaceID = nil
                    }
                    account.selectedRoomID = room.id
                    await openThread(env["HUDDLE_DEV_THREAD"], in: room.id, of: account)
                    if let query = env["HUDDLE_DEV_SEARCH"] {
                        account.showSearch(scope: env["HUDDLE_DEV_SEARCH_ALL"] == nil ? .room : .all)
                        account.search.query = query
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}
