import AppKit
import SwiftUI

/// The devices signed in to an account: this Mac, then the others, most recently active first,
/// with whether each is verified and when it was last active. Others can be renamed and signed
/// out, one at a time or all at once, confirmed with the account's password in a sheet of its
/// own. Where the server hands sign-in to its own service, that service's page does the signing
/// out.
struct DevicesSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AccountDevice] = []
    @State private var isLoading = true
    /// Why the list couldn't be read, shown in its place.
    @State private var loadFailure: String?
    /// Signing out happens on the sign-in service's page, not here.
    @State private var managedByService = false
    @State private var renaming: AccountDevice?
    @State private var newName = ""
    @State private var renameFailure: String?
    /// The devices about to be signed out, while the password is asked for.
    @State private var signingOut: SignOutRequest?
    @State private var isWorking = false

    private var thisMac: AccountDevice? { devices.first { $0.id == account.currentDeviceID } }
    private var others: [AccountDevice] { devices.filter { $0.id != account.currentDeviceID } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Devices")
                    .font(.headline)
                Text(account.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)
            Divider()
            Form {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else if let loadFailure {
                    Section {
                        VStack(spacing: 10) {
                            Label("Couldn’t Get Your Devices", systemImage: "exclamationmark.triangle")
                                .font(.headline)
                            Text(loadFailure)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try Again") { reload() }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                } else {
                    if let thisMac {
                        Section("This Mac") {
                            DeviceRow(device: thisMac, isThisMac: true, rename: { startRenaming(thisMac) }, signOut: nil)
                        }
                    }
                    Section {
                        if others.isEmpty {
                            Text("No other devices are signed in.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(others) { device in
                            DeviceRow(device: device, isThisMac: false, rename: { startRenaming(device) },
                                      signOut: { signOut([device]) })
                        }
                    } header: {
                        Text(others.isEmpty ? "Other Devices" : "Other Devices (\(others.count))")
                    } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            if managedByService, !others.isEmpty {
                                Button("Manage Devices on the Web…") { signOut(others) }
                            } else if others.count > 1 {
                                // Red only while it can be pressed: a disabled destructive button
                                // fades to almost nothing in dark mode.
                                Button("Sign Out of All Other Devices…", role: isWorking ? nil : .destructive) {
                                    signOut(others)
                                }
                                .disabled(isWorking)
                            }
                            Text(managedByService
                                 ? "Your server’s sign-in service manages your devices: signing one out opens its page."
                                 : "A device signed out needs your password to sign in again, and loses the encryption keys it held. Verified devices were confirmed from one of your trusted devices.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
            }
            .formStyle(.grouped)
            // Scrolled, its rows would show through under the title.
            .clipped()
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 540, height: 560)
        .task { await load() }
        .alert("Rename Device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { device in
            TextField("Name", text: $newName)
            Button("Rename") { rename(device) }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Only you see your devices’ names.")
        }
        .alert("Couldn’t Rename the Device", isPresented: Binding(get: { renameFailure != nil },
                                                                  set: { if !$0 { renameFailure = nil } })) {
            Button("OK") {}
        } message: {
            Text(renameFailure ?? "")
        }
        .sheet(item: $signingOut) { request in
            SignOutSheet(account: account, devices: request.devices) { reload() }
        }
    }

    private func load() async {
        do {
            devices = try await account.devices()
            loadFailure = nil
        } catch {
            loadFailure = error.actionMessage
        }
        managedByService = await account.accountPageURL() != nil
        isLoading = false
    }

    private func reload() {
        Task { await load() }
    }

    private func startRenaming(_ device: AccountDevice) {
        newName = device.name ?? ""
        renaming = device
    }

    private func rename(_ device: AccountDevice) {
        let name = newName
        isWorking = true
        Task {
            do {
                try await account.renameDevice(device.id, to: name)
            } catch {
                renameFailure = error.actionMessage
            }
            await load()
            isWorking = false
        }
    }

    private func signOut(_ chosen: [AccountDevice]) {
        guard !chosen.isEmpty else { return }
        if managedByService {
            Task {
                if let url = await account.devicePageURL(for: chosen.count == 1 ? chosen[0].id : nil) {
                    AccountSession.openInBrowser(url)
                }
            }
            return
        }
        signingOut = SignOutRequest(devices: chosen)
    }
}

private struct SignOutRequest: Identifiable {
    let id = UUID()
    let devices: [AccountDevice]
}

/// Asks for the account's password to sign devices out, as macOS asks for one: the field ready
/// to type in, Return to confirm, and a wrong password shaking the sheet, with what went wrong
/// right under the field and the field cleared to try again.
private struct SignOutSheet: View {
    let account: AccountSession
    let devices: [AccountDevice]
    let onSignedOut: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failure: String?
    @State private var isWorking = false
    @State private var window: NSWindow?
    @FocusState private var fieldFocused: Bool

    private var title: String {
        devices.count == 1 ? "Sign Out of “\(devices[0].displayName)”?" : "Sign Out of \(devices.count) Devices?"
    }

    private var message: String {
        devices.count == 1
            ? "It will need your password to sign in again, and will lose the encryption keys it holds."
            : "They will need your password to sign in again, and will lose the encryption keys they hold."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                SecureField("Password", text: $password, prompt: Text("Password"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Password")
                    .focused($fieldFocused)
                    .disabled(isWorking)
                    .onSubmit(submit)
                    .onChange(of: password) { if !password.isEmpty { failure = nil } }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign Out", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 400)
        .animation(.snappy(duration: 0.2), value: failure)
        .background(WindowReader { window = $0 })
        .onAppear { fieldFocused = true }
    }

    private func submit() {
        guard !password.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        let ids = devices.map(\.id)
        let entered = password
        Task {
            do {
                try await account.signOut(devices: ids, password: entered)
                onSignedOut()
                dismiss()
            } catch {
                // Enabled again before the field takes the cursor back.
                isWorking = false
                if case PasswordChangeError.wrongPassword = error {
                    failure = "That password isn’t right. Try again."
                    password = ""
                    window?.shake()
                } else {
                    failure = error.actionMessage
                }
                fieldFocused = true
            }
        }
    }
}

private extension AccountDevice {
    var displayName: String { name ?? id }
}

/// A device: what kind it looks like, its name and ID, how recently it was used and from where,
/// whether it's verified, and its menu.
private struct DeviceRow: View {
    let device: AccountDevice
    let isThisMac: Bool
    let rename: () -> Void
    let signOut: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .lineLimit(1)
                    trust
                }
                Text(details)
                    .font(.caption)
                    .foregroundStyle(device.isInactive && !isThisMac ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Menu {
                Button("Rename…", action: rename)
                if let signOut {
                    Divider()
                    Button("Sign Out…", role: .destructive, action: signOut)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this device")
            .accessibilityLabel("More for \(device.displayName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            Button("Rename", action: rename)
            if let signOut { Button("Sign Out", action: signOut) }
        }
    }

    @ViewBuilder private var trust: some View {
        switch device.trust {
        case .verified:
            Label("Verified", systemImage: "checkmark.seal.fill")
                .labelStyle(TrustLabel(tint: .green))
        case .unverified:
            Label("Not verified", systemImage: "exclamationmark.triangle.fill")
                .labelStyle(TrustLabel(tint: .orange))
        case .noEncryption:
            Label("No encryption", systemImage: "lock.slash")
                .labelStyle(TrustLabel(tint: .secondary))
        case .unknown:
            EmptyView()
        }
    }

    /// "ABCDEF · Last active 2 hours ago · 192.0.2.1"
    private var details: String {
        var parts = [device.id]
        if isThisMac {
            parts.append("This Mac")
        } else if device.isInactive {
            parts.append("Inactive for 90+ days")
        } else if let seen = device.lastSeen {
            parts.append(seen.timeIntervalSinceNow > -60 ? "Active now"
                         : "Last active \(seen.formatted(.relative(presentation: .named)))")
        } else {
            parts.append("No activity yet")
        }
        if let ip = device.lastSeenIP, !isThisMac {
            // An IPv4 address as the server may give it, IPv6-mapped: shown as itself.
            parts.append(ip.hasPrefix("::ffff:") && ip.contains(".") ? String(ip.dropFirst(7)) : ip)
        }
        return parts.joined(separator: " · ")
    }

    /// A guess from the name, as servers don't say what kind of device it is.
    private var icon: String {
        let name = (device.name ?? "").lowercased()
        if ["iphone", "ios", "android", "mobile", "ipad"].contains(where: name.contains) { return "iphone" }
        if ["web", "chrome", "firefox", "safari", "edge", "browser"].contains(where: name.contains) { return "globe" }
        if isThisMac || ["mac", "desktop", "huddle", "linux", "windows"].contains(where: name.contains) {
            return "laptopcomputer"
        }
        return "display"
    }
}

/// A small coloured icon and caption-sized text.
private struct TrustLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
