import AppKit
import SwiftUI

/// One item of an account's menu.
struct AccountMenuItem: Identifiable {
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

/// An account's menu, the same wherever it is (the title bar's avatars and chip, its ⋯ in
/// Settings ▸ Accounts): the account's own items, in one order and one wording, so a new one
/// can't reach one menu and not the other. Each place says what the items do there (a sheet in
/// the main window, or in Settings), and may add a group of its own before Sign Out.
enum AccountMenu {
    struct Actions {
        let label: () -> Void
        let editProfile: () -> Void
        let changePassword: () -> Void
        let devices: () -> Void
        let verify: () -> Void
        let recoveryKey: () -> Void
        let signOut: () -> Void
    }

    /// Copy User ID and Label; the profile, password and devices; this Mac's verification and
    /// the recovery key, where there's something to do; the place's own group; Sign Out.
    @MainActor
    static func sections(for account: AccountSession, actions: Actions, extras: [AccountMenuItem] = []) -> [[AccountMenuItem]] {
        let security = [
            account.verification == .unverified ? AccountMenuItem("Verify This Mac…", action: actions.verify) : nil,
            account.managesRecoveryKey
                ? AccountMenuItem(account.recoveryState == .disabled ? "Set Up Recovery Key…" : "Change Recovery Key…",
                                  action: actions.recoveryKey)
                : nil,
        ].compactMap { $0 }
        let sections: [[AccountMenuItem]] = [
            [AccountMenuItem("Copy User ID") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(account.userID, forType: .string)
             },
             AccountMenuItem("Label…", action: actions.label)],
            [AccountMenuItem("Edit Profile…", action: actions.editProfile),
             account.signsInWithOAuth
                ? AccountMenuItem("Manage Account…") { openAccountPage(of: account) }
                : AccountMenuItem("Change Password…", action: actions.changePassword),
             AccountMenuItem("Devices…", action: actions.devices)],
            security,
            extras,
            [AccountMenuItem("Sign Out…", isDestructive: true, action: actions.signOut)],
        ]
        return sections.filter { !$0.isEmpty }
    }
}

/// An account's menu as SwiftUI draws one (a context menu, a Menu's items): its user ID on
/// top, where asked, then its groups of items.
struct AccountMenuContent: View {
    var header: String?
    let sections: () -> [[AccountMenuItem]]

    var body: some View {
        if let header { Text(header) }
        ForEach(Array(sections().enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil, action: item.action)
                    .disabled(!item.isEnabled)
            }
        }
    }
}

extension View {
    /// Asks for an account's label (AccountLabel.swift) while `account` is set: its own name for
    /// the account, saved to the account's data, or taken away.
    func accountLabelPrompt(for account: Binding<AccountSession?>) -> some View {
        modifier(AccountLabelPrompt(account: account))
    }
}

private struct AccountLabelPrompt: ViewModifier {
    @Binding var account: AccountSession?
    @State private var text = ""
    @State private var shown: AccountSession?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: account?.id, initial: true) {
                guard let account else { return }
                text = account.label ?? ""
                shown = account
            }
            .alert("Label for \(shown?.displayName ?? shown?.userID ?? "")",
                   isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil; account = nil } })) {
                TextField("Work, Personal", text: $text)
                Button("Save") { save(text) }
                if shown?.label != nil {
                    Button("Remove Label", role: .destructive) { save(nil) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Notifications say which account they arrived on by its label. It’s kept with your account, so Huddle on your other Macs has it too.")
            }
            .alert("Couldn’t Save the Label", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func save(_ label: String?) {
        guard let target = shown else { return }
        Task {
            do { try await target.setLabel(label) } catch { failure = error.actionMessage }
        }
    }
}

extension View {
    /// Asks for the user's own name for someone (ContactNames.swift) while `person` is set: saved
    /// to the account's data, or taken away to go back to their own name.
    func contactNamePrompt(for person: Binding<(userID: String, name: String)?>, in account: AccountSession) -> some View {
        modifier(ContactNamePrompt(person: person, account: account))
    }
}

private struct ContactNamePrompt: ViewModifier {
    @Binding var person: (userID: String, name: String)?
    let account: AccountSession
    @State private var text = ""
    @State private var shown: (userID: String, name: String)?
    @State private var failure: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: person?.userID, initial: true) {
                guard let person else { return }
                text = account.contactName(for: person.userID) ?? ""
                shown = person
            }
            .alert("Name for \(shown?.name ?? "")",
                   isPresented: Binding(get: { shown != nil }, set: { if !$0 { shown = nil; person = nil } })) {
                TextField(shown?.name ?? "Name", text: $text)
                Button("Save") { save(text) }
                if let shown, account.contactName(for: shown.userID) != nil {
                    Button("Use Their Own Name", role: .destructive) { save(nil) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Only you see it, wherever Huddle shows \(shown?.name ?? "them"). It’s kept with your account, so Huddle on your other Macs has it too.")
            }
            .alert("Couldn’t Save the Name", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(failure ?? "")
            }
    }

    private func save(_ name: String?) {
        guard let target = shown else { return }
        Task {
            do { try await account.setContactName(name, for: target.userID) } catch { failure = error.actionMessage }
        }
    }
}
