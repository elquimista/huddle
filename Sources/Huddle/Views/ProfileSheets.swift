import AppKit
import SwiftUI

/// Your name and picture, as everyone sees them in every room. A new picture is shown here
/// first and saved, with the name, by Save; Cancel leaves both as they were.
struct ProfileSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var picture = PictureChange.unchanged
    @State private var capabilities = AccountSession.ProfileCapabilities()
    @State private var isSaving = false
    @State private var failure: String?

    private enum PictureChange {
        case unchanged
        case new(AvatarImage)
        case removed
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { trimmedName != (account.displayName ?? "") }
    private var pictureChanged: Bool {
        if case .unchanged = picture { false } else { true }
    }
    private var hasPicture: Bool {
        switch picture {
        case .unchanged: account.avatarURL != nil
        case .new: true
        case .removed: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Profile")
                .font(.headline)
            HStack(alignment: .center, spacing: 16) {
                EditableAvatar(canChange: capabilities.canSetPicture, isBusy: false, hasPicture: hasPicture,
                               chooseMessage: "Choose a picture for your profile") { url in
                    do {
                        picture = .new(try AvatarImage(contentsOf: url))
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                } remove: {
                    picture = .removed
                } picture: {
                    pictureView
                }
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Display name", text: $name, prompt: Text("Display name"))
                        .accessibilityLabel("Display name")
                        .textFieldStyle(.roundedBorder)
                        .disabled(!capabilities.canSetName || isSaving)
                        .onSubmit(save)
                    Text(account.userID)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Text("Your name and picture show in every room you're in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || trimmedName.isEmpty || !(nameChanged || pictureChanged))
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            name = account.displayName ?? ""
            capabilities = await account.profileCapabilities()
        }
    }

    @ViewBuilder private var pictureView: some View {
        switch picture {
        case .new(let image):
            Image(nsImage: image.preview)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 76)
                .clipShape(Circle())
        case .removed:
            AvatarView(media: account.media, url: nil, name: trimmedName.isEmpty ? account.userID : trimmedName,
                       seed: account.userID, size: 76)
        case .unchanged:
            AvatarView(media: account.media, url: account.avatarURL,
                       name: trimmedName.isEmpty ? account.userID : trimmedName, seed: account.userID, size: 76)
        }
    }

    private func save() {
        guard !isSaving, !trimmedName.isEmpty, nameChanged || pictureChanged else { return }
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                if nameChanged { try await account.setDisplayName(trimmedName) }
                switch picture {
                case .new(let image): try await account.setPicture(image)
                case .removed: try await account.removePicture()
                case .unchanged: break
                }
                dismiss()
            } catch {
                failure = "Couldn't save your profile: \(error.actionMessage)"
            }
        }
    }
}

/// A new password for an account that signs in with one, given the current one. Optionally
/// signs out the account's other devices; this one stays signed in. Where the server keeps
/// passwords to its own sign-in service, it says so and offers that service's account page.
struct ChangePasswordSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var confirmation = ""
    @State private var signsOutOtherDevices = false
    /// Nil until the server has said; the form shows, disabled, meanwhile.
    @State private var canChange: Bool?
    /// Where the password is changed instead, when the server doesn't let apps change it.
    @State private var accountPage: URL?
    @State private var isChanging = false
    @State private var failure: String?
    @State private var isDone = false

    private var mismatch: Bool { !confirmation.isEmpty && confirmation != new }
    private var canSubmit: Bool {
        canChange == true && !isChanging && !current.isEmpty && !new.isEmpty && confirmation == new
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change Password")
                    .font(.headline)
                Text(account.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if isDone {
                done
            } else if canChange == false {
                managedElsewhere
            } else {
                form
            }
        }
        .padding(20)
        .frame(width: 420)
        .task {
            let allowed = await account.profileCapabilities().canChangePassword
            if !allowed { accountPage = await account.accountPageURL() }
            canChange = allowed
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 10) {
                GridRow {
                    Text("Current password:").gridColumnAlignment(.trailing)
                    SecureField("Current password", text: $current, prompt: Text("Required"))
                        .accessibilityLabel("Current password")
                }
                GridRow {
                    Text("New password:")
                    SecureField("New password", text: $new, prompt: Text("Required"))
                        .accessibilityLabel("New password")
                }
                GridRow {
                    Text("Confirm:")
                    SecureField("Confirm new password", text: $confirmation, prompt: Text("New password again"))
                        .accessibilityLabel("Confirm new password")
                        .onSubmit(submit)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(canChange != true || isChanging)
            // What went wrong last time no longer applies once the passwords are changed.
            .onChange(of: [current, new, confirmation]) { failure = nil }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Sign out of your other devices", isOn: $signsOutOtherDevices)
                    .toggleStyle(.checkbox)
                    .disabled(canChange != true || isChanging)
                Text("They'll need the new password to sign in again. This Mac stays signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = mismatch ? "The new passwords don't match." : failure {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isChanging { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Password", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
    }

    /// The server doesn't let apps change the password: where it can be changed, if anywhere.
    private var managedElsewhere: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(accountPage == nil
                 ? "Your server doesn't allow changing your password from an app."
                 : "Your password is managed by your server's sign-in service. Change it on your account page there.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if accountPage == nil {
                    Button("OK") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Open Account Page") {
                        openAccountPage(of: account)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your password has been changed.")
                    Text(signsOutOtherDevices
                         ? "Your other devices have been signed out."
                         : "Your other devices are still signed in.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isChanging = true
        failure = nil
        Task {
            defer { isChanging = false }
            do {
                try await account.changePassword(from: current, to: new, signingOutOtherDevices: signsOutOtherDevices)
                current = ""
                new = ""
                confirmation = ""
                isDone = true
            } catch {
                failure = error.actionMessage
            }
        }
    }
}

/// Manage Account…, for an account signed in through OAuth: its page on the sign-in server,
/// where its password is changed. Says so if the page can't be opened.
@MainActor
func openAccountPage(of account: AccountSession) {
    Task {
        do {
            try await account.openAccountPage()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't Open Your Account Page"
            alert.informativeText = error.actionMessage
            alert.runModal()
        }
    }
}
