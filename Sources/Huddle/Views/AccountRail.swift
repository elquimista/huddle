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
            // Punch a gap out of the avatar and ring so the badge never touches them.
            .overlay(alignment: .topTrailing) {
                if let badge {
                    badge.shape
                        .padding(2)
                        .background(.black, in: Capsule())
                        .blendMode(.destinationOut)
                        .offset(badge.offset)
                }
            }
            .compositingGroup()
            .overlay(alignment: .topTrailing) {
                if let badge {
                    badge.shape.offset(badge.offset)
                }
            }
            .contentShape(Circle())
            .help(helpText)
    }

    private struct Badge {
        let shape: AnyView
        let offset: CGSize
    }

    /// Red and numbered for mentions and invitations; a quiet dot for ordinary unread rooms.
    private var badge: Badge? {
        if account.urgentCount > 0 {
            let label = Text("\(min(account.urgentCount, 99))")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: 16, minHeight: 16)
                .background(.red, in: Capsule())
            return Badge(shape: AnyView(label), offset: CGSize(width: 2, height: -2))
        }
        if account.badgeCount > 0 {
            let dot = Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
            return Badge(shape: AnyView(dot), offset: CGSize(width: -1, height: 1))
        }
        return nil
    }

    private var helpText: String {
        var lines = [account.userID]
        if account.urgentCount > 0 {
            lines.append("\(account.urgentCount) mention\(account.urgentCount == 1 ? "" : "s") or invitation\(account.urgentCount == 1 ? "" : "s")")
        }
        let other = account.badgeCount - account.urgentCount
        if other > 0 {
            lines.append("\(other) room\(other == 1 ? "" : "s") with new messages")
        }
        return lines.joined(separator: "\n")
    }
}
