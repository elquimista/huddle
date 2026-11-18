import SwiftUI

/// The accounts, as a row of small avatars in the title bar above the sidebar: the one shown
/// is ringed, and each carries its own unread badge. They sit above what they switch (the
/// spaces rail and the room list), out of the way of the open room's own title and buttons.
struct AccountBar: View {
    /// The sidebar's width, which decides how many avatars fit beside the window controls.
    let sidebar: SidebarWidth
    @Environment(AccountStore.self) private var store
    @State private var accountToSignOut: AccountSession?

    /// Room taken by the window controls and the sidebar button before the first avatar, and
    /// by the New Message button and the toolbar's own margin after the last. On the generous side: the toolbar hides an
    /// item that is a little too wide outright rather than squeezing it.
    private static let reserved: CGFloat = 196
    /// One avatar with its ring and the room its badge needs.
    private static let slot: CGFloat = AccountButton.size + 4 + 2 * RailBadge.overhang

    /// The accounts shown as avatars, and the rest, behind a "+N" menu. The open account is
    /// always among those shown.
    private var split: (shown: [(Int, AccountSession)], more: [(Int, AccountSession)]) {
        let all = Array(store.accounts.enumerated())
        let fits = max(1, Int((max(sidebar.width, 280) - Self.reserved) / Self.slot))
        guard all.count > fits else { return (all, []) }
        // One slot goes to the "+N" button.
        var shown = Array(all.prefix(max(0, fits - 1)))
        if let selected = all.first(where: { $0.element.id == store.selected?.id }),
           !shown.contains(where: { $0.element.id == selected.element.id }) {
            if !shown.isEmpty { shown.removeLast() }
            shown.append(selected)
        }
        let more = all.filter { item in !shown.contains { $0.element.id == item.element.id } }
        return (shown.map { ($0.offset, $0.element) }, more.map { ($0.offset, $0.element) })
    }

    var body: some View {
        let split = split
        HStack(spacing: 0) {
            ForEach(split.shown, id: \.1.id) { index, account in
                AccountButton(account: account, isSelected: account.id == store.selected?.id, index: index) {
                    store.selectedID = account.id
                }
                .contextMenu {
                    Text(account.userID)
                    Button("Copy User ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(account.userID, forType: .string)
                    }
                    Button("Mark All as Read") { account.markAllRead() }
                        .disabled(!account.hasUnreadRooms)
                    Divider()
                    Button("Edit Profile…") {
                        store.selectedID = account.id
                        account.sheet = .profile
                    }
                    if account.signsInWithOAuth {
                        Button("Manage Account…") { openAccountPage(of: account) }
                    } else {
                        Button("Change Password…") {
                            store.selectedID = account.id
                            account.sheet = .changePassword
                        }
                    }
                    Divider()
                    Button("New Space…") {
                        store.selectedID = account.id
                        account.sheet = .newSpace
                    }
                    Button("Add Account…") { store.isAddingAccount = true }
                    Divider()
                    Button("Sign Out…", role: .destructive) { accountToSignOut = account }
                }
            }
            if !split.more.isEmpty {
                MoreAccountsButton(accounts: split.more) { store.selectedID = $0.id }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accounts")
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

/// "+2": the accounts that don't fit, in a menu, with a dot when any of them has something new.
/// The sidebar's width as it is laid out, for the account bar above it to fit itself to.
@Observable
final class SidebarWidth {
    /// Starts at the narrowest the sidebar can be. The toolbar drops an item that is too wide
    /// for it when first laid out, and doesn't bring it back once it shrinks; it does let an
    /// item grow.
    var width: CGFloat = 280
}

private struct MoreAccountsButton: View {
    let accounts: [(Int, AccountSession)]
    let select: (AccountSession) -> Void
    @State private var anchor = MenuAnchor()

    private var badge: RailBadge? {
        if accounts.contains(where: { $0.1.urgentCount > 0 }) { return .dot(.red, size: 7) }
        if accounts.contains(where: { $0.1.badgeCount > 0 }) { return .dot(.accentColor, size: 7) }
        return nil
    }

    var body: some View {
        Button(action: open) {
            Text("+\(accounts.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: AccountButton.size, height: AccountButton.size)
                .background(Color.secondary.opacity(0.2), in: Circle())
                .padding(2)
                .railBadge(badge)
                .padding(RailBadge.overhang)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .help("More accounts")
        .accessibilityLabel("\(accounts.count) more accounts")
    }

    /// The other accounts, each with its unread count as the menu's own badge.
    private func open() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        for (_, account) in accounts {
            let item = ClosureMenuItem(title: account.displayName ?? account.userID) { select(account) }
            if account.badgeCount > 0 { item.badge = NSMenuItemBadge(count: account.badgeCount) }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: RailBadge.overhang, y: view.bounds.height), in: view)
    }
}

private struct AccountButton: View {
    let account: AccountSession
    let isSelected: Bool
    let index: Int
    let select: () -> Void
    @State private var isHovering = false

    static let size: CGFloat = 22

    var body: some View {
        AvatarView(media: account.media,
                   url: account.avatarURL,
                   name: account.displayName ?? account.userID,
                   seed: account.userID,
                   size: Self.size)
            .padding(2)
            .overlay {
                Circle().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .railBadge(RailBadge.count(urgent: account.urgentCount, other: account.badgeCount, compact: true))
            .opacity(isSelected || isHovering ? 1 : 0.85)
            .contentShape(Circle())
            .padding(RailBadge.overhang)
            .onTapGesture(perform: select)
            .onHover { isHovering = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
            .help(helpText)
    }

    private var name: String { account.displayName ?? account.userID }

    private var helpText: String {
        var lines = [index < 9 ? "\(name) (⌘\(index + 1))" : name, account.userID]
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

    private var accessibilityLabel: String {
        account.badgeCount > 0 ? "\(name), \(account.badgeCount) with new messages" : name
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
    /// notifications. Both count rooms. Red wins when there are both. Compact for the small
    /// avatars in the title bar.
    static func count(urgent: Int, other: Int, compact: Bool = false) -> RailBadge? {
        let count = urgent > 0 ? urgent : other
        guard count > 0 else { return nil }
        let label = Text("\(min(count, 99))")
            .font(.system(size: compact ? 9 : 10, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 3 : 4)
            .frame(minWidth: compact ? 13 : 16, minHeight: compact ? 13 : 16)
            .background(urgent > 0 ? Color.red : Color.accentColor, in: Capsule())
        let shift: CGFloat = compact ? 3 : 2
        return RailBadge(shape: AnyView(label), offset: CGSize(width: shift, height: -shift))
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
