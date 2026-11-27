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
///                        invitation) to browse at launch; "" for Home
///   HUDDLE_DEV_SHEET     with HUDDLE_DEV_SPACE: newRoom, newSpace, addRooms or leave, to open that sheet
///                        (editSpace: the space's page, ready to change its name and topic, as Edit Space… does);
///                        profile, password, devices, verify or recovery for the account's own; manage for its OAuth account page
///   HUDDLE_DEV_NOTIFICATION  with HUDDLE_DEV_SPACE: name of a room to open as clicking its notification
///                        does, once the space is showing (without bringing the app forward)
///   HUDDLE_DEV_SIGN_OUT  username to sign out at launch (same code path as the Sign Out menu)
///   HUDDLE_DEV_FRESH     start with no accounts loaded (stored ones are left alone), to see first run
///   HUDDLE_DEV_CLEAR_CACHES  comma-separated usernames whose caches to empty at launch (keys are kept),
///                        for a store that has fallen out of step with the server
///   HUDDLE_DEV_APPEARANCE  "light" or "dark", overriding the system appearance and the one chosen in Settings
///   HUDDLE_DEV_ASSUME_ACTIVE  mark rooms as read even while the app is in the background; call windows
///                             and the ringing panel open behind other windows, not over them
///   HUDDLE_DEV_CALL      with HUDDLE_DEV_SELECT "user/Room": start a voice call there at launch
///   HUDDLE_DEV_NO_MIC    calls get no microphone (no system prompt), to test their signalling
///   HUDDLE_DEV_CALL_PER_ACCOUNT  a call for each account at once, so two can call each other here
///   HUDDLE_DEV_LEGACY_CALLS  one-to-one calls are the older kind, as if the server had no Element Call
///                        backend (the local one has); with HUDDLE_DEV_NO_MIC they send silence
///   HUDDLE_DEV_HOVER     text of a message to show the hover actions on ("text!" also opens its emoji picker)
///   HUDDLE_DEV_HOVER_NAMES  comma-separated names of spaces in the rail ("Home" too), rooms in the list,
///                        and accounts in the title bar by user name ("more" for the +N button) to draw as pointed at
///   HUDDLE_DEV_LABEL_PROMPT  user name of an account whose Label… prompt opens when Settings ▸ Accounts shows;
///                        "bar/<user name>" opens it from the title bar instead
///   HUDDLE_DEV_LOG_MENUS  the open account's menu, opened by clicking its chip, is written to the log
///                        ("DEV_MENU …") instead of shown, so tests don't put a menu over the screen; and
///                        each account's menu in Settings ▸ Accounts as its row appears
///   HUDDLE_DEV_MUTE_AUDIO  play audio messages silently (Scripts/run-dev.sh sets this)
///   HUDDLE_DEV_AUDIO_DEVICE  UID of the output device to play through, instead of the Mac's default
///   HUDDLE_DEV_AUDIO_DELAY   seconds to stall before audio starts, standing in for a slow output device
///   HUDDLE_DEV_IMAGE_DELAY   seconds to wait before each image loads, to see the placeholders
///   HUDDLE_DEV_STAGE         comma-separated paths of pictures or files to put in the composer at launch,
///                        as if dropped there (in the room HUDDLE_DEV_SELECT names)
///   HUDDLE_DEV_DOWNLOAD_TO   a folder each file shown in a conversation is downloaded into, as Save File As would
///   HUDDLE_DEV_FREE_SCROLL   treat scrolling done through accessibility as the user's, so tests can scroll up
///   HUDDLE_DEV_WHEEL     scroll the conversation when asked from outside, as a trackpad would: the
///                        "app.huddle.dev.wheel" distributed notification, its object "points,events,ms"
///                        (points per event, up toward older messages when positive). Scroll events posted
///                        from outside don't reach a window in the background; these are handed to the app
///                        from within, past its event monitors, as the reader's are.
///   HUDDLE_DEV_POINTER   where the room list takes the pointer to be, when asked from outside: the
///                        "app.huddle.dev.pointer" distributed notification, its object "x,y" in points from the
///                        main window's top left, or "none" for the real pointer again (which is left alone)
///   HUDDLE_DEV_CROP_THUMBNAILS  send images with a square thumbnail cropped from the middle, as some phone apps do
///   HUDDLE_DEV_SLOW_ANIMATIONS  slow the timeline's animations down by this factor, to inspect them
///   HUDDLE_DEV_PRESENCE_INTERVAL  seconds between presence checks, instead of 30 and 90
///   HUDDLE_DEV_NO_BROWSER  print the OAuth sign-in URL (DEV_OAUTH_URL ...) instead of opening it
///   HUDDLE_DEV_PICK_FILE  a picture file to take as chosen, in place of the open panel (Room Info, Edit Profile)
///   HUDDLE_DEV_SAVE_TO   a file to save the recovery key to, in place of the save panel
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
        case "editSpace": account.editDetails(ofSpace: spaceID)
        case "profile": account.sheet = .profile
        case "password": account.sheet = .changePassword
        case "devices": account.sheet = .devices
        case "verify": account.sheet = .verify
        case "recovery": account.sheet = .recoveryKey
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
    static let deniesMicrophone = AppEnvironment.isDev
        && ProcessInfo.processInfo.environment["HUDDLE_DEV_NO_MIC"] != nil
    /// Answers each message's alert as if this was typed into its Reply field
    /// (HUDDLE_DEV_NOTIFY_REPLY): the system's own alert can't be driven from a test.
    static let notificationReply: String? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_NOTIFY_REPLY"] : nil
    /// A sound file that voice messages record instead of the microphone (HUDDLE_DEV_FAKE_MIC),
    /// so tests never listen to the room.
    static let fakeMicrophone: URL? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_FAKE_MIC"].map { URL(fileURLWithPath: $0) } : nil
    static let callPerAccount = AppEnvironment.isDev
        && ProcessInfo.processInfo.environment["HUDDLE_DEV_CALL_PER_ACCOUNT"] != nil
    static let legacyCalls = AppEnvironment.isDev
        && ProcessInfo.processInfo.environment["HUDDLE_DEV_LEGACY_CALLS"] != nil

    /// Whether to empty an account's caches at launch (HUDDLE_DEV_CLEAR_CACHES), as if it had
    /// just signed in on this device: its encryption keys are kept.
    nonisolated static func clearsCaches(for userID: String) -> Bool {
        guard AppEnvironment.isDev, let names = ProcessInfo.processInfo.environment["HUDDLE_DEV_CLEAR_CACHES"] else { return false }
        return names.split(separator: ",").contains { userID == "@\($0):localhost" || userID == String($0) }
    }

    /// Stands in for the pointer, which automation cannot move over the Dev app.
    /// A file to take as chosen wherever a picture is asked for, in place of the open panel.
    static let pickedFile: String? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_PICK_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        : nil

    /// Where Save… puts the recovery key, in place of the save panel.
    static let savePath: URL? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_SAVE_TO"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
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

    /// The account whose Label… prompt opens with Settings ▸ Accounts, by user name.
    static let labelPrompt: String? = AppEnvironment.isDev ? ProcessInfo.processInfo.environment["HUDDLE_DEV_LABEL_PROMPT"] : nil
    /// Starts naming this member (a user ID) in place as Room Info opens (HUDDLE_DEV_RENAME_MEMBER).
    static let renamesMember: String? = AppEnvironment.isDev ? ProcessInfo.processInfo.environment["HUDDLE_DEV_RENAME_MEMBER"] : nil

    /// Menus written to the log instead of shown.
    static let logsMenus = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_LOG_MENUS"] != nil

    /// Spaces, rooms and accounts drawn as pointed at, by name, to see their hover effects
    /// without moving the pointer.
    static let hoveredNames: Set<String> = AppEnvironment.isDev
        ? Set((ProcessInfo.processInfo.environment["HUDDLE_DEV_HOVER_NAMES"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        : []

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

    /// The room's conversation, for HUDDLE_DEV_WHEEL to scroll.
    static weak var conversationScrollView: NSScrollView?

    private static func listenForWheel() {
        DistributedNotificationCenter.default().addObserver(forName: .init("app.huddle.dev.wheel"), object: nil,
                                                            queue: .main) { note in
            let parts = (note.object as? String ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 3 else { return }
            MainActor.assumeIsolated { wheel(points: parts[0], events: Int(parts[1]), gap: parts[2] / 1000) }
        }
    }

    /// A trackpad scroll over the middle of the conversation: fingers down, `events` moves of
    /// `points` each, `gap` seconds apart, fingers up.
    private static func wheel(points: Double, events: Int, gap: Double) {
        guard let scrollView = conversationScrollView, let window = scrollView.window else { return }
        let middle = window.convertPoint(toScreen: scrollView.convert(NSPoint(x: scrollView.bounds.midX,
                                                                              y: scrollView.bounds.midY), to: nil))
        let location = CGPoint(x: middle.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - middle.y)
        func post(_ delta: Int32, phase: Int64, after delay: Double) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                            wheel1: delta, wheel2: 0, wheel3: 0) else { return }
                cgEvent.location = location
                cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))
                cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
                cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
                                             value: Int64(window.windowNumber))
                // Without a window (one can't be given it), the app can't route it: straight to
                // the conversation, after the app's monitors (the conversation's, telling the
                // reader's scrolling from its own) have seen it.
                guard let event = NSEvent(cgEvent: cgEvent) else { return }
                NSApp.sendEvent(event)
                scrollView.scrollWheel(with: event)
            }
        }
        post(0, phase: 1, after: 0)
        for step in 1...max(events, 1) { post(Int32(points), phase: 2, after: gap * Double(step)) }
        post(0, phase: 4, after: gap * Double(max(events, 1) + 1))
    }

    private static func listenForPointer() {
        DistributedNotificationCenter.default().addObserver(forName: .init("app.huddle.dev.pointer"), object: nil,
                                                            queue: .main) { note in
            let parts = (note.object as? String ?? "").split(separator: ",").compactMap { Double($0) }
            MainActor.assumeIsolated {
                if parts.count == 2, let window = MainWindow.window {
                    RoomListHover.devPointer = NSPoint(x: parts[0], y: window.frame.height - parts[1])
                } else {
                    RoomListHover.devPointer = nil
                }
                NotificationCenter.default.post(name: RoomListHover.devPointerMoved, object: nil)
            }
        }
    }

    static let freeScroll = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_FREE_SCROLL"] != nil

    /// How many rows of history a room's timeline loads as it opens, for measuring how it copes
    /// with a long one (HUDDLE_DEV_PERF times each rebuild of its rows).
    static let historyRows: Int? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_HISTORY"].flatMap(Int.init)
        : nil

    /// Each time a timeline's rows are made, makes them all again from nothing as well, and says
    /// whether they're the same (DEV_ROWS_SAME, DEV_ROWS_DIFFER): a check on what's kept of them.
    static let checksRows = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_CHECK_ROWS"] != nil

    /// How long Media and Files goes on looking back with nothing found, in seconds, in place of
    /// ten: for seeing it stop, and look further, in a room of a few thousand messages.
    static let mediaSearchPatience: TimeInterval? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_MEDIA_PATIENCE"].flatMap(TimeInterval.init)
        : nil
    /// Gives every message its actions as accessibility actions even without VoiceOver, so tests
    /// can reach them.
    static let accessibilityActions = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_AX_ACTIONS"] != nil
    /// Milliseconds between pages of the full-history pass (HUDDLE_DEV_INDEX_PAUSE), to watch its
    /// progress on a test server whose rooms would otherwise be done in moments.
    static let indexPauseMilliseconds: Int? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_INDEX_PAUSE"].flatMap(Int.init) : nil

    /// Whether indexing counts Huddle as idle (HUDDLE_DEV_INDEXING=idle or busy), whatever its
    /// state: Dev runs in the background during tests, which on its own counts as idle.
    static let indexingIdle: Bool? = AppEnvironment.isDev
        ? ProcessInfo.processInfo.environment["HUDDLE_DEV_INDEXING"].map { $0 != "busy" } : nil

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
        if env["HUDDLE_DEV_WHEEL"] != nil { listenForWheel() }
        if env["HUDDLE_DEV_POINTER"] != nil { listenForPointer() }

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
                    // Show it in the list too, which the space selected last time might hide.
                    account.showInList(room.id)
                    account.selectedRoomID = room.id
                    if env["HUDDLE_DEV_CALL"] != nil {
                        CallCenter.shared.call(account: account, roomID: room.id, title: room.name)
                    }
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
