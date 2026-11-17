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
                Button("Add Account…") { store.isAddingAccount = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
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
                MainView(account: account)
                    .id(account.id)
            } else {
                LoginView(isFirstAccount: true)
            }
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

    var body: some View {
        NavigationSplitView {
            HStack(spacing: 0) {
                AccountRail()
                Divider()
                RoomListView(account: account)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 460)
        } detail: {
            if let roomID = account.selectedRoomID {
                RoomView(account: account, roomID: roomID)
                    .id(roomID)
            } else {
                ContentUnavailableView("No Room Selected",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("Pick a conversation from the list."))
            }
        }
    }
}
