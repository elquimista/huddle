import SwiftUI

@main
struct HuddleApp: App {
    @State private var store = AccountStore()

    var body: some Scene {
        WindowGroup {
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
                    Button("Find Previous") { account?.showSearchResult(after: -1) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
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
            }
            CommandMenu("Accounts") {
                ForEach(Array(store.accounts.enumerated()), id: \.element.id) { index, account in
                    Button(account.displayName ?? account.userID) { store.selectedID = account.id }
                        .keyboardShortcut(index < 9 ? KeyEquivalent(Character("\(index + 1)")) : KeyEquivalent("0"),
                                          modifiers: .command)
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
