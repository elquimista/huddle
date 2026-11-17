import SwiftUI

/// Vertical strip of account avatars for switching between accounts.
struct AccountRail: View {
    @Environment(AccountStore.self) private var store
    @State private var accountToSignOut: AccountSession?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(store.accounts) { account in
                    AccountButton(account: account, isSelected: account.id == store.selected?.id)
                        .onTapGesture { store.selectedID = account.id }
                        .contextMenu {
                            Text(account.userID)
                            Button("Copy User ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(account.userID, forType: .string)
                            }
                            Divider()
                            Button("Sign Out…", role: .destructive) { accountToSignOut = account }
                        }
                }
                Button {
                    store.isAddingAccount = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Add account")
            }
            .padding(.vertical, 10)
        }
        .frame(width: 54)
        .confirmationDialog("Sign out of \(accountToSignOut?.userID ?? "")?",
                            isPresented: Binding(get: { accountToSignOut != nil },
                                                 set: { if !$0 { accountToSignOut = nil } })) {
            Button("Sign Out", role: .destructive) {
                if let account = accountToSignOut {
                    Task { await store.signOut(account) }
                }
            }
        } message: {
            Text("Local message history and encryption keys for this account will be removed from this Mac.")
        }
    }
}

private struct AccountButton: View {
    let account: AccountSession
    let isSelected: Bool

    var body: some View {
        AvatarView(media: account.media,
                   url: account.avatarURL,
                   name: account.displayName ?? account.userID,
                   seed: account.userID,
                   size: 34)
            .padding(3)
            .overlay {
                Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if account.badgeCount > 0 {
                    Text("\(min(account.badgeCount, 99))")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(.red, in: Capsule())
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Circle())
            .help(account.userID)
    }
}
