import MatrixRustSDK
import SwiftUI
import Perception

/// Setting up the account's recovery key, or changing it, on its own sheet: from Settings ▸
/// Accounts and the room list's suggestion.
struct RecoveryKeySheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss

    var body: some View { WithPerceptionTracking {
        VStack(spacing: 20) {
            RecoveryKeySetup(account: account, finish: { dismiss() })
        }
        .centredSheetLayout()
    } }
}

extension View {
    /// The verification and recovery sheets' shape: content centred under a symbol, buttons along
    /// the bottom.
    func centredSheetLayout() -> some View {
        padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
            .frame(width: 480)
    }
}

/// Making a recovery key, then showing it once to keep: it can't be shown again, so finishing
/// waits until it has been copied or saved.
struct RecoveryKeySetup: View {
    let account: AccountSession
    /// Straight after resetting the account's identity: always a new key, which can wait.
    var afterReset = false
    let finish: () -> Void

    private enum Purpose { case setUp, change, changeWithCurrentKey }

    @State private var purpose: Purpose
    @State private var key: String?
    @State private var currentKey = ""
    @State private var isBusy = false
    @State private var error: String?
    /// The account has a key backup this Mac can't open, which stops a new one being made.
    @State private var findsUnreadableBackup = false
    @State private var confirmsReplacing = false
    /// How the key was kept, once it has been.
    @State private var kept: String?
    @FocusState private var isFocused: Bool

    init(account: AccountSession, afterReset: Bool = false, finish: @escaping () -> Void) {
        self.account = account
        self.afterReset = afterReset
        self.finish = finish
        _purpose = State(initialValue: afterReset || account.recoveryState == .disabled ? .setUp
                         : account.recoveryState == .incomplete ? .changeWithCurrentKey : .change)
    }

    var body: some View { WithPerceptionTracking {
        if let key {
            keyToKeep(key)
        } else {
            intro
        }
    } }

    @ViewBuilder private var intro: some View {
        switch purpose {
        case .setUp:
            SheetHeader(symbol: "key.horizontal",
                        title: "Set Up a Recovery Key",
                        message: "If you lose all your devices, your recovery key is how you read your encrypted messages again. Huddle makes one for you to keep somewhere safe.")
        case .change:
            SheetHeader(symbol: "key.horizontal",
                        title: "Change Your Recovery Key",
                        message: "You’ll get a new key to save, and your current one will stop working.")
        case .changeWithCurrentKey:
            SheetHeader(symbol: "key.horizontal",
                        title: "Change Your Recovery Key",
                        message: "Enter your current recovery key first. You’ll get a new one to save, and the current one will stop working.")
            SecureField("Current recovery key", text: $currentKey)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(make)
                .onAppear { isFocused = true }
        }
        if findsUnreadableBackup {
            Text("Your account already has a key backup, but this Mac doesn’t have its key. If another of your devices has it, open Huddle or Element there, then try again here in a moment. If none does, replace the old backup with a new one.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .detailsBackground()
        } else if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        SheetBar {
            if isBusy { ProgressView().controlSize(.small) }
        } trailing: {
            Button(afterReset ? "Not Now" : "Cancel", action: finish)
                .keyboardShortcut(.cancelAction)
            if findsUnreadableBackup {
                Button("Replace Old Backup…", role: .destructive) { confirmsReplacing = true }
                    .disabled(isBusy)
            }
            Button(findsUnreadableBackup ? "Try Again" : purpose == .setUp ? "Continue" : "Change Key", action: make)
                .keyboardShortcut(.defaultAction)
                .disabled(isBusy || (purpose == .changeWithCurrentKey && currentKey.isEmpty))
        }
        .confirmationDialog("Replace your old key backup?", isPresented: $confirmsReplacing) { WithPerceptionTracking {
            Button("Replace Backup", role: .destructive) { make(replacing: true) }
        } } message: {
            Text("Messages whose keys are only in the old backup can’t be read again.")
        }
    }

    @ViewBuilder private func keyToKeep(_ key: String) -> some View {
        SheetHeader(symbol: "key.horizontal",
                    title: "Save Your Recovery Key",
                    message: "Keep it somewhere safe, like a password manager. Anyone who has it can read your encrypted messages.")
        VStack(spacing: 8) {
            RecoveryKeyText(key: key)
            Text(kept ?? "Copy it or save it to a file to finish.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        SheetBar {
            Button("Copy") {
                RecoveryKeyKeeper.copy(key)
                kept = "Copied. Paste it into your password manager."
            }
            Button("Save…") {
                RecoveryKeyKeeper.save(key, for: account.userID) { url in
                    if let url { kept = "Saved as “\(url.lastPathComponent)”." }
                }
            }
        } trailing: {
            Button("Done", action: finish)
                .keyboardShortcut(.defaultAction)
                .disabled(kept == nil)
                .help(kept == nil ? "Copy or save the key first" : "")
        }
    }

    private func make() { make(replacing: false) }

    private func make(replacing: Bool) {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        Task {
            defer { isBusy = false }
            do {
                if replacing { try await account.deleteUnreadableKeyBackup() }
                switch purpose {
                case .setUp:
                    key = try await account.setUpRecoveryKey()
                case .change:
                    key = try await account.changeRecoveryKey(current: nil)
                case .changeWithCurrentKey:
                    key = try await account.changeRecoveryKey(
                        current: currentKey.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            } catch let failure as RecoveryError {
                if case .BackupExistsOnServer = failure {
                    findsUnreadableBackup = true
                } else {
                    findsUnreadableBackup = false
                    error = failure.actionMessage
                }
            } catch {
                findsUnreadableBackup = false
                self.error = error.actionMessage
            }
        }
    }
}

/// A recovery key, large and in two lines, to read, select or copy.
private struct RecoveryKeyText: View {
    let key: String

    var body: some View { WithPerceptionTracking {
        Text(lines)
            .font(.system(size: 17, weight: .medium, design: .monospaced))
            .lineSpacing(6)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .detailsBackground()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Recovery key")
            .accessibilityValue(key)
    } }

    /// Its groups of four split over two lines.
    private var lines: String {
        let groups = key.split(separator: " ")
        guard groups.count > 6 else { return key }
        let half = (groups.count + 1) / 2
        return groups[..<half].joined(separator: " ") + "\n" + groups[half...].joined(separator: " ")
    }
}

/// Starting the account's encryption over, for someone with neither another verified device nor
/// their recovery key: what they lose, then their password or their sign-in page to confirm,
/// then a new recovery key.
struct ResetIdentityFlow: View {
    let account: AccountSession
    let back: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case confirm
        /// The account's sign-in page is approving it, in the browser.
        case browser(URL)
        case done
        case recoveryKey
    }

    @State private var step: Step = .confirm
    @State private var handle: IdentityResetHandle?
    @State private var session = ""
    /// Where the server's sign-in page approves the reset, if that's how it confirms it.
    @State private var approvalURL: URL?
    @State private var password = ""
    /// Whether the server wants the password, rather than approval on its sign-in page: nil
    /// until known. A server that hands sign-in to its own service (Matrix Authentication
    /// Service) wants approval there, even from an account signed in with a password through
    /// its compatibility layer.
    @State private var wantsPassword: Bool?
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    init(account: AccountSession, back: @escaping () -> Void) {
        self.account = account
        self.back = back
        _wantsPassword = State(initialValue: account.signsInWithOAuth ? false : nil)
    }

    var body: some View { WithPerceptionTracking {
        switch step {
        case .confirm: confirm
        case .browser(let url): browser(url)
        case .done: done
        case .recoveryKey: RecoveryKeySetup(account: account, afterReset: true, finish: { dismiss() })
        }
    } }

    @ViewBuilder private var confirm: some View {
        SheetHeader(symbol: "exclamationmark.triangle.fill", tint: .orange, isFilled: true,
                    title: "Reset Your Identity?",
                    message: "Only do this if you’ve lost your recovery key and have no other verified device.")
        VStack(alignment: .leading, spacing: 10) {
            consequence("lock.slash", "You’ll lose access to your encrypted message history.")
            consequence("checkmark.shield", "Your other devices will need verifying again, and people who verified you will see that your identity changed.")
            consequence("person.2", "Your account, rooms and contacts stay as they are.")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailsBackground()
        .task {
            if wantsPassword == nil { wantsPassword = await account.accountPageURL() == nil }
        }
        if wantsPassword == true {
            SecureField("Password for \(account.userID)", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onAppear { isFocused = true }
        }
        if let error {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        SheetBar {
            Button("Back", action: back)
                .disabled(isBusy || handle != nil)
            if isBusy { ProgressView().controlSize(.small) }
        } trailing: {
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
            // Destructive: never on Return.
            Button(wantsPassword == false ? "Continue in Browser…" : "Reset Identity", role: .destructive, action: reset)
                .disabled(isBusy || wantsPassword == nil || (wantsPassword == true && password.isEmpty))
        }
    }

    private func consequence(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func browser(_ url: URL) -> some View {
        SheetHeader(symbol: "person.badge.key",
                    title: "Approve in Your Browser",
                    message: "Your account’s sign-in page is open in your browser. Approve the reset there, and Huddle finishes by itself.")
        SheetBar {
            ProgressView().controlSize(.small)
            Text("Waiting for approval…")
                .foregroundStyle(.secondary)
        } trailing: {
            Button("Open Page Again") { AccountSession.openInBrowser(url) }
            Button("Cancel", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder private var done: some View {
        SheetHeader(symbol: "checkmark.seal.fill", tint: .green, isFilled: true,
                    title: "Your Identity Is Reset",
                    message: "This Mac has a new identity and is verified. Set up a recovery key now, so you don’t lose your messages again.")
        SheetBar {
            Button("Not Now") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Set Up Recovery Key") { step = .recoveryKey }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Resetting

    private func reset() {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        Task {
            defer { isBusy = false }
            do {
                // Once started, the account's key backup and recovery key are gone; trying again
                // after a wrong password goes on with the same reset.
                if handle == nil {
                    guard let started = try await account.beginIdentityReset() else {
                        step = .done
                        return
                    }
                    handle = started
                    switch started.authType() {
                    case .uiaa(let info):
                        session = info.session
                        if wantsPassword != true || password.isEmpty {
                            // The server wants the password after all.
                            wantsPassword = true
                            return
                        }
                    case .oAuth(let info):
                        session = info.session
                        wantsPassword = false
                        guard let url = URL(string: info.approvalUrl) else {
                            error = "The server’s sign-in page couldn’t be opened."
                            return
                        }
                        approvalURL = url
                        approve(at: url, with: started)
                        return
                    }
                }
                guard let handle else { return }
                if let approvalURL {
                    approve(at: approvalURL, with: handle)
                    return
                }
                try await handle.reset(auth: .password(passwordDetails: AuthDataPasswordDetails(
                    identifier: account.userID, password: password, session: session)))
                password = ""
                step = .done
            } catch let failure as ClientError {
                if Self.isWrongPassword(failure) {
                    error = "That password isn’t right. Try again."
                    password = ""
                    isFocused = true
                } else {
                    error = failure.actionMessage
                }
            } catch {
                self.error = error.actionMessage
            }
        }
    }

    /// The server turned the password down: it says so either as a refusal or, the way the SDK
    /// passes on a password that didn't satisfy its sign-in check, by asking for one again.
    private static func isWrongPassword(_ error: ClientError) -> Bool {
        switch error {
        case .MatrixApi(.forbidden, _, _, _): true
        case .Generic(let message, _): message.contains("User-Interactive Authentication")
        default: false
        }
    }

    /// Opens the sign-in page and waits, up to two minutes, for the reset to be approved there.
    private func approve(at url: URL, with handle: IdentityResetHandle) {
        step = .browser(url)
        AccountSession.openInBrowser(url)
        Task {
            do {
                try await handle.reset(auth: .oAuth(session: session))
                if case .browser = step { step = .done }
            } catch {
                guard case .browser = step else { return }
                step = .confirm
                self.error = "The reset wasn’t approved in time. Try again."
            }
        }
    }

    private func cancel() {
        if let handle, step != .done, step != .recoveryKey {
            Task { await handle.cancel() }
        }
        dismiss()
    }
}
