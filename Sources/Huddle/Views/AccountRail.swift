import SwiftUI

/// Vertical strip of account avatars for switching between accounts.
struct AccountRail: View {
    @Environment(AccountStore.self) private var store
    @State private var accountToSignOut: AccountSession?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(store.accounts) { account in
                    AccountButton(account: account, isSelected: account.id == store.selected?.id)
                        .onTapGesture { store.selectedID = account.id }
                        .contextMenu {
                            Text(account.userID)
                            Button("Copy User ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(account.userID, forType: .string)
                            }
                            Button("Mark All as Read") { account.markAllRead() }
                                .disabled(!account.hasUnreadRooms)
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
                        .padding(7)
                }
                .buttonStyle(.plain)
                .help("Add account")
                if let account = store.selected {
                    SpaceRailSection(account: account)
                }
            }
            .padding(.vertical, 3)
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
            .railBadge(RailBadge.count(urgent: account.urgentCount, other: account.badgeCount))
            .contentShape(Circle())
            // Room for the badge inside this view's bounds: the context menu attached to it
            // clips anything drawn outside them.
            .padding(RailBadge.overhang)
            .help(helpText)
    }

    private var helpText: String {
        var lines = [account.userID]
        if account.urgentCount > 0 {
            lines.append(account.urgentCount == 1
                ? "1 direct message, mention or invitation"
                : "\(account.urgentCount) direct messages, mentions or invitations")
        }
        let other = account.badgeCount - account.urgentCount
        if other > 0 {
            lines.append("\(other) room\(other == 1 ? "" : "s") with new messages")
        }
        return lines.joined(separator: "\n")
    }
}

/// A badge on an account or space in the rail, at the top trailing corner of its avatar.
struct RailBadge {
    let shape: AnyView
    let offset: CGSize

    /// Room around an avatar for its badge, inside the view's own bounds: a context menu
    /// attached to it clips anything drawn outside them.
    static let overhang: CGFloat = 4
    /// Width of the clear ring between a badge and the avatar behind it.
    static let gap: CGFloat = 2

    /// Red for direct messages, mentions and invitations; otherwise blue for other rooms with
    /// notifications. Both count rooms. Red wins when there are both.
    static func count(urgent: Int, other: Int) -> RailBadge? {
        let count = urgent > 0 ? urgent : other
        guard count > 0 else { return nil }
        let label = Text("\(min(count, 99))")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(urgent > 0 ? Color.red : Color.accentColor, in: Capsule())
        return RailBadge(shape: AnyView(label), offset: CGSize(width: 2, height: -2))
    }

    /// A small dot: something unread, or an invitation (in red).
    static func dot(_ color: Color, size: CGFloat = 8) -> RailBadge {
        RailBadge(shape: AnyView(Circle().fill(color).frame(width: size, height: size)),
                  offset: CGSize(width: 0, height: 0))
    }
}

extension View {
    /// Puts a badge on the view's top trailing corner, with a gap punched out of what is
    /// behind it so the two never touch.
    func railBadge(_ badge: RailBadge?) -> some View {
        self
            .overlay(alignment: .topTrailing) {
                if let badge {
                    // Grown evenly on every side, then shifted back out so it stays centred on the badge.
                    badge.shape
                        .padding(RailBadge.gap)
                        .background(.black, in: Capsule())
                        .blendMode(.destinationOut)
                        .offset(x: badge.offset.width + RailBadge.gap,
                                y: badge.offset.height - RailBadge.gap)
                }
            }
            .compositingGroup()
            .overlay(alignment: .topTrailing) {
                if let badge {
                    badge.shape.offset(badge.offset)
                }
            }
    }
}
