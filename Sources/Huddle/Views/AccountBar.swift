import SwiftUI

/// The accounts, as a row of small avatars in the title bar above the sidebar: the one shown
/// opens into a chip with its name, and each carries its own unread badge. They sit above what
/// they switch (the spaces rail and the room list), out of the way of the open room's own title
/// and buttons.
struct AccountBar: View {
    /// The sidebar's width, which decides how many avatars fit beside the window controls.
    let sidebar: SidebarWidth
    @Environment(AccountStore.self) private var store
    @State private var accountToSignOut: AccountSession?

    /// Room taken by the window controls and the sidebar button before the first avatar, and
    /// by the New Message button and the toolbar's own margin after the last. On the generous side: the toolbar hides an
    /// item that is a little too wide outright rather than squeezing it.
    private static let reserved: CGFloat = 196
    /// One avatar and the room its badge needs.
    private static let slot: CGFloat = AccountButton.size + 2 * RailBadge.overhang

    /// The accounts shown as avatars, and the rest, behind a "+N" menu. The open account is
    /// always among those shown.
    private var split: (shown: [(Int, AccountSession)], more: [(Int, AccountSession)]) {
        let all = Array(store.accounts.enumerated())
        // The open account's chip takes its name's width on top of an avatar's slot.
        let chip = store.selected.map { AccountButton.nameRoom(for: $0) } ?? 0
        let fits = max(1, Int((max(sidebar.width, 280) - Self.reserved - chip) / Self.slot))
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
                AccountButton(account: account, isSelected: account.id == store.selected?.id, index: index,
                              select: { store.selectedID = account.id },
                              menu: { menuSections(for: account) })
                // Its own view, made only as the menu opens, so its checks (unread rooms, for
                // Mark All as Read) aren't run each time the bar is drawn.
                .contextMenu { AccountContextMenu(header: account.userID, sections: { menuSections(for: account) }) }
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

extension AccountBar {
    /// An account's menu: the same for right-clicking any account's avatar and for clicking the
    /// open account's chip.
    fileprivate func menuSections(for account: AccountSession) -> [[AccountMenuItem]] {
        let store = store
        let select = { store.selectedID = account.id }
        let accountPage = account.signsInWithOAuth
            ? AccountMenuItem("Manage Account…") { openAccountPage(of: account) }
            : AccountMenuItem("Change Password…") { select(); account.sheet = .changePassword }
        return [
            [AccountMenuItem("Copy User ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.userID, forType: .string)
             },
             AccountMenuItem("Mark All as Read", isEnabled: account.hasUnreadRooms) { account.markAllRead() }],
            [AccountMenuItem("Edit Profile…") { select(); account.sheet = .profile },
             accountPage,
             AccountMenuItem("Devices…") { select(); account.sheet = .devices }],
            [AccountMenuItem("New Space…") { select(); account.sheet = .newSpace },
             AccountMenuItem("Add Account…") { store.isAddingAccount = true }],
            [AccountMenuItem("Sign Out…", isDestructive: true) { accountToSignOut = account }],
        ]
    }
}

/// One item of an account's menu.
private struct AccountMenuItem: Identifiable {
    let title: String
    var isEnabled = true
    var isDestructive = false
    let action: () -> Void
    var id: String { title }

    init(_ title: String, isEnabled: Bool = true, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

/// An account's menu as a context menu: its user ID on top, then its groups of items.
private struct AccountContextMenu: View {
    let header: String
    let sections: () -> [[AccountMenuItem]]

    var body: some View {
        Text(header)
        ForEach(Array(sections().enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil, action: item.action)
                    .disabled(!item.isEnabled)
            }
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
    @State private var isHovering = false

    private var badge: RailBadge? {
        if accounts.contains(where: { $0.1.urgentCount > 0 }) { return .dot(.red, size: 7) }
        if accounts.contains(where: { $0.1.badgeCount > 0 }) { return .dot(.accentColor, size: 7) }
        return nil
    }

    var body: some View {
        Button(action: open) {
            Text("+\(accounts.count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: AccountButton.size, height: AccountButton.size)
                .background(Color.secondary.opacity(isHovering ? 0.32 : 0.2), in: Circle())
                .railBadge(badge)
                .padding(RailBadge.overhang)
                .contentShape(Circle())
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .onAppear { if DevHooks.hoveredNames.contains("more") { isHovering = true } }
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
    /// The account's menu, which clicking the open account's chip shows, as right-clicking does.
    let menu: () -> [[AccountMenuItem]]
    @State private var isHovering = false
    @State private var isMenuOpen = false
    @State private var anchor = MenuAnchor()

    static let size: CGFloat = 22

    /// The longest a name in the chip runs before it's cut short.
    private static let longestName: CGFloat = 110
    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// What the open account's chip adds to an avatar's width: its name, and the chip's margin.
    static func nameRoom(for account: AccountSession) -> CGFloat {
        let width = (chipName(account) as NSString).size(withAttributes: [.font: nameFont]).width
        return min(ceil(width), longestName) + 6 + 8 + 2 * chipInset
    }

    /// Between the chip's edge and the avatar in it.
    private static let chipInset: CGFloat = 2

    /// Its display name, or the name part of its Matrix ID.
    private static func chipName(_ account: AccountSession) -> String {
        account.displayName ?? account.userID.matrixLocalpart
    }

    var body: some View {
        // The open account opens into a chip with its name, so it's plain at a glance which one
        // is shown.
        HStack(spacing: 6) {
            AvatarView(media: account.media,
                       url: account.avatarURL,
                       name: account.displayName ?? account.userID,
                       seed: account.userID,
                       size: Self.size)
                .padding(isSelected ? Self.chipInset : 0)
                .railBadge(RailBadge.count(urgent: account.urgentCount, other: account.badgeCount, compact: true))
            if isSelected {
                Text(Self.chipName(account))
                    .font(Font(Self.nameFont))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Self.longestName, alignment: .leading)
                    .fixedSize()
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .background {
            if isSelected {
                // A shade deeper pointed at, and while its menu is open, as a pop-up button.
                Capsule().fill(.quaternary)
                    .overlay { Capsule().fill(Color.primary.opacity(isHovering || isMenuOpen ? 0.07 : 0)) }
                    .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
            } else if isHovering {
                // Another account pointed at: the chip it would open into, without the name yet.
                Circle().fill(.quaternary)
                    .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                    .padding(-Self.chipInset)
                    .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.22), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovering)
            .contentShape(Capsule())
            .onHoverInFrontWindow { isHovering = $0 }
            .onAppear { if DevHooks.hoveredNames.contains(account.userID.matrixLocalpart) { isHovering = true } }
            .background(MenuAnchorView(anchor: anchor))
            .padding(RailBadge.overhang)
            .onTapGesture(perform: activate)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, activate)
            .help(helpText)
    }

    /// Another account is switched to; the open one shows its menu.
    private func activate() {
        if isSelected { openMenu() } else { select() }
    }

    /// The menu hangs from the chip, lined up with its left side, and returns once it has closed.
    private func openMenu() {
        guard let view = anchor.view else { return }
        let nsMenu = NSMenu()
        nsMenu.autoenablesItems = false
        let header = NSMenuItem(title: account.userID, action: nil, keyEquivalent: "")
        header.isEnabled = false
        nsMenu.addItem(header)
        for (index, section) in menu().enumerated() {
            if index > 0 { nsMenu.addItem(.separator()) }
            for item in section {
                let menuItem = ClosureMenuItem(title: item.title, handler: item.action)
                menuItem.isEnabled = item.isEnabled
                nsMenu.addItem(menuItem)
            }
        }
        if DevHooks.logsMenus {
            print("DEV_MENU " + nsMenu.items.map { $0.isSeparatorItem ? "—" : ($0.isEnabled ? $0.title : "(\($0.title))") }
                .joined(separator: " | ")); fflush(stdout)
            return
        }
        isMenuOpen = true
        nsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        isMenuOpen = false
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
