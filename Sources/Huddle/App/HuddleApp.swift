import SwiftUI

@main
struct HuddleApp: App {
    @State private var store = AccountStore()
    /// Started with the app, so it can look for updates on its schedule.
    private let updater = AppUpdater.shared
    /// Opens the window at launch if macOS couldn't put it back (MainWindow.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Under a fixed name, so macOS finds it again whatever changes inside it (MainWindow).
        WindowGroup(id: MainWindow.id) {
            RootView()
                .environment(store)
                .frame(minWidth: 720, minHeight: 540)
                .task { await store.restore() }
                .onChange(of: store.totalBadgeCount, initial: true) { _, count in
                    NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
                }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Huddle")") {
                    AboutPanel.show()
                }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            CommandGroup(replacing: .newItem) {
                let account = store.selected
                Button("New Message…") { account?.sheet = .newMessage }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(account == nil || account?.sheet != nil)
                Button("New Room…") {
                    // In the space whose rooms are showing, where that's allowed.
                    let space = account?.browsingSpaceID ?? account?.selectedSpaceID
                    account?.sheet = .newRoom(inSpace: space)
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(account == nil || account?.sheet != nil)
                Button("New Space…") { account?.sheet = .newSpace }
                    .disabled(account == nil || account?.sheet != nil)
                Button("New Section…") { account?.asksForNewSection = true }
                    .disabled(account == nil || account?.sheet != nil)
                Divider()
                Button("Add Account…") { store.isAddingAccount = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                let account = store.selected
                let canSearch = account?.selectedRoomID != nil && account?.browsingSpaceID == nil
                Divider()
                Menu("Find") {
                    Button("Find…") { account?.showSearch(scope: .room) }
                        .keyboardShortcut("f", modifiers: .command)
                        .disabled(!canSearch)
                    Button("Find in All Rooms…") { account?.showSearch(scope: .all) }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .disabled(!canSearch)
                    Divider()
                    Button("Find Next") { account?.showSearchResult(after: 1) }
                        .keyboardShortcut("g", modifiers: .command)
                        .disabled(!canSearch)
                    Button("Find Previous") { account?.showSearchResult(after: -1) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .disabled(!canSearch)
                }
            }
            // View ▸ Show/Hide Sidebar (⌃⌘S).
            SidebarCommands()
            // Window ▸ Huddle (⌘0): the window back after closing it.
            CommandGroup(before: .windowList) {
                MainWindowCommand()
                Divider()
            }
            // There is no help book: no Huddle Help item that only says so. The Help menu keeps
            // its search of the menus.
            CommandGroup(replacing: .help) {}
            // Moving around: rooms, spaces, accounts, and the way back. Paused while something is
            // over the conversation, which has keys of its own.
            CommandMenu("Go") {
                let account = store.selected
                let paused = store.navigationPaused
                let history = RoomHistory.shared
                Button("Go to Room…") { store.isGoingToRoom.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(store.accounts.isEmpty || (paused && !store.isGoingToRoom))
                Divider()
                Button("Back") { history.go(-1) }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!history.canGoBack || paused)
                Button("Forward") { history.go(1) }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!history.canGoForward || paused)
                Divider()
                // As Element goes from room to room.
                Button("Next Room") { account?.showRoom(step: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                    .disabled(account == nil || paused)
                Button("Previous Room") { account?.showRoom(step: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                    .disabled(account == nil || paused)
                Button("Next Unread Room") { account?.showRoom(step: 1, unreadOnly: true) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                    .disabled(!(account?.hasUnreadRooms ?? false) || paused)
                Button("Previous Unread Room") { account?.showRoom(step: -1, unreadOnly: true) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                    .disabled(!(account?.hasUnreadRooms ?? false) || paused)
                if let account {
                    Divider()
                    // Home and the account's spaces, as the rail has them. The spaces are ⌘1 to
                    // ⌘9 from the top, as the first is the one a hand reaches for; Home, the base
                    // they're numbered from, is ⇧⌘H, Finder's Go ▸ Home (RailShortcut).
                    Toggle("Home", isOn: Binding(get: { account.selectedSpaceID == nil },
                                                 set: { _ in account.choose(inRail: .home) }))
                        .keyboardShortcut(RailShortcut.home)
                        .disabled(paused)
                    ForEach(Array(account.spaces.enumerated()), id: \.element.roomId) { index, space in
                        Toggle(space.displayName, isOn: Binding(
                            get: { account.selectedSpaceID == space.roomId },
                            set: { _ in account.choose(inRail: .space(space.roomId)) }))
                            .keyboardShortcut(RailShortcut.space(at: index))
                            .disabled(paused)
                    }
                }
                Divider()
                // Round the accounts; with two, back and forth. ⌥⌘→ and ⌥⌘← too (NavigationKeys).
                Button("Next Account") { store.selectAccount(step: 1) }
                    .keyboardShortcut(.tab, modifiers: .control)
                    .disabled(store.accounts.count < 2 || paused)
                Button("Previous Account") { store.selectAccount(step: -1) }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                    .disabled(store.accounts.count < 2 || paused)
                // The one showing ticked; ⌃1 to ⌃9 for the first nine, and no shortcut after that
                // (rather than all of the rest sharing one).
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    Toggle(account.displayName ?? account.userID, isOn: Binding(
                        get: { store.selectedID == account.id }, set: { _ in store.selectedID = account.id }))
                        .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                                                       modifiers: .control) : nil)
                        .disabled(paused)
                }
            }
            CommandMenu("Room") {
                let account = store.selected
                let roomID = account?.selectedRoomID
                Button("Room Info") {
                    if let account, let roomID {
                        account.sidePanels[roomID] = account.sidePanels[roomID] == .info ? nil : .info
                    }
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(roomID == nil || account?.browsingSpaceID != nil)
                Divider()
                let unread = roomID.map { account?.isUnread($0) ?? false } ?? false
                Button(unread ? "Mark as Read" : "Mark as Unread") {
                    if let account, let roomID { account.setRoom(roomID, unread: !unread) }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(roomID == nil)
                Button("Mark All as Read") { account?.markAllRead() }
                    .disabled(!(account?.hasUnreadRooms ?? false))
                Divider()
                // The open room's, as its menu in the list has them.
                let place = roomID.flatMap { id in account?.allRooms.first { $0.id == id } }.map { account?.place(of: $0) }
                ForEach([("Favourite", SectionPlace.favourites), ("Low Priority", .lowPriority)], id: \.0) { title, target in
                    Toggle(title, isOn: Binding(get: { place == target }, set: { isOn in
                        guard let account, let roomID else { return }
                        FailureAlert.run("Couldn’t Move the Room") { try await account.move(roomID, to: isOn ? target : .usual) }
                    }))
                    .disabled(roomID == nil || account?.browsingSpaceID != nil)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(AccountStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Group {
            if store.isRestoring {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let account = store.selected {
                // Not rebuilt for each account (its columns' contents are): a rebuilt split view
                // puts its toolbar items back at the far end, the account bar included.
                MainView(account: account)
            } else {
                LoginView(isFirstAccount: true)
            }
        }
        .background { CallPages() }
        .overlay {
            if store.isGoingToRoom { GoToRoomPanel() }
        }
        // The full-size image viewer covers the whole window, title bar included, which an
        // overlay here can't reach. `ImageViewerPresenter` puts it above everything, where it
        // takes every click. (Don't switch hit-testing off on this content instead: that makes
        // the sidebar lose its place under the toolbar and jump upward.)
        .onChange(of: ImageViewerState.shared.item?.id) {
            ImageViewerPresenter.shared.show(ImageViewerState.shared.item)
        }
        .sheet(isPresented: Binding(
            get: { store.isAddingAccount && !store.accounts.isEmpty },
            set: { store.isAddingAccount = $0 })) {
            LoginView(isFirstAccount: false)
                .frame(width: 440, height: 520)
        }
        // Links in messages open only web pages and email (LinkPolicy). Set here, inside the
        // window's view, not on it in the scene: macOS reopens the window by a name made from
        // the type of the scene's view, and a modifier added there would change it, so after an
        // update the window wouldn't come back.
        .environment(\.openURL, LinkPolicy.action)
    }
}

struct MainView: View {
    @Environment(AccountStore.self) private var store
    @Bindable var account: AccountSession
    @State private var sidebar = SidebarWidth()

    var body: some View {
        NavigationSplitView {
            HStack(spacing: 0) {
                if SpaceRail.isShown(for: account) {
                    SpaceRail(account: account)
                    Divider()
                }
                RoomListView(account: account)
            }
            .id(account.id)
            // Measured inside the column-width modifier: outside it, the split view no longer
            // sees the width and opens the sidebar far narrower than its minimum.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { sidebar.width = $0 }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    AccountBar(sidebar: sidebar)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        account.sheet = .newMessage
                    } label: {
                        Label("New Message", systemImage: "square.and.pencil")
                    }
                    .help("New message (⌘N)")
                }
            }
        } detail: {
            // The edge between the toolbar and the conversation, drawn here because AppKit's
            // own separator is turned off (see `detailTitlebarSeparatorHidden`). Above the
            // content rather than over it: pictures scrolling up under it would cover it.
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                Group {
                    if let spaceID = account.browsingSpaceID {
                        SpaceBrowserView(account: account, spaceID: spaceID)
                            .id(spaceID)
                    } else if let roomID = account.selectedRoomID {
                        RoomView(account: account, roomID: roomID)
                            .id(roomID)
                    } else {
                        ContentUnavailableView("No Room Selected",
                                               systemImage: "bubble.left.and.bubble.right",
                                               description: Text("Pick a conversation from the list."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .id(account.id)
            }
        }
        .sheet(item: $account.sheet) { sheet in
            AccountSheetView(account: account, sheet: sheet)
        }
        .detailTitlebarSeparatorHidden()
    }
}
