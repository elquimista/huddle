import SwiftUI

/// Verifying this Mac, by comparing emoji with another of the account's devices or with the
/// recovery key, and answering requests to verify from elsewhere. One sheet for every step of
/// the account's `VerificationFlow`. From the room list's banner, Settings ▸ Accounts, and by
/// itself when a request comes in.
struct VerificationSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var usesRecoveryKey = false
    /// How many of the account's other devices are verified, once known: with none, there's no
    /// device to compare emoji with.
    @State private var otherVerifiedDevices: Int?

    private var flow: VerificationFlow { account.verificationFlow }

    var body: some View {
        VStack(spacing: 20) {
            content
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(width: 480)
        .onAppear { flow.windowOpened() }
        .onDisappear { flow.windowClosed() }
        .onChange(of: flow.step) { _, step in
            // A request that went away by itself, on a Mac with nothing else to verify.
            if step == .idle, account.verification == .verified { dismiss() }
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .idle:
            if usesRecoveryKey {
                RecoveryKeyForm(account: account, back: { usesRecoveryKey = false })
            } else {
                choices
            }
        case .requesting:
            waiting(symbol: "laptopcomputer.and.iphone",
                    title: "Accept on Your Other Device",
                    message: "On a phone or computer where you’re signed in as \(account.userID), open Huddle, Element or another Matrix app and accept the request.",
                    status: "Waiting for your other device…")
        case .incoming:
            incoming
        case .starting:
            waiting(symbol: subjectSymbol,
                    title: "Getting Ready",
                    message: "Working out the emoji to compare with \(partner).",
                    status: "Connecting…")
        case .comparing(let code):
            comparing(code)
            SheetBar {
                Button("They Don’t Match", action: flow.reject)
                    .keyboardShortcut(.cancelAction)
                // Prominent, but not on Return: saying they match should be a deliberate click.
                Button("They Match", action: flow.confirm)
                    .buttonStyle(.borderedProminent)
            }
        case .confirming(let code):
            comparing(code)
            SheetBar {
                ProgressView().controlSize(.small)
                Text("Waiting for \(partner) to confirm…")
                    .foregroundStyle(.secondary)
            } trailing: {
                Button("Cancel", action: stop)
                    .keyboardShortcut(.cancelAction)
            }
        case .verified:
            verified
            SheetBar {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        case .ended(let ending):
            ended(ending)
        }
    }

    // MARK: Steps

    /// How to verify this Mac.
    @ViewBuilder private var choices: some View {
        SheetHeader(symbol: "lock.shield",
                    title: "Verify This Mac",
                    message: "Confirm that this Mac is yours, so it can read your encrypted messages and others can trust it.")
        VStack(spacing: 8) {
            ChoiceRow(symbol: "laptopcomputer.and.iphone",
                      title: "Use Another Device",
                      detail: otherVerifiedDevices == 0
                        ? "None of your other devices is verified yet."
                        : "Compare emoji with one of your other devices.",
                      isEnabled: otherVerifiedDevices != 0,
                      action: flow.verifyThisMac)
            ChoiceRow(symbol: "key.horizontal",
                      title: "Use Recovery Key",
                      detail: "Enter the recovery key you saved.",
                      action: { usesRecoveryKey = true })
        }
        SheetBar {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .task {
            guard otherVerifiedDevices == nil, let devices = try? await account.devices() else { return }
            otherVerifiedDevices = devices.filter { $0.id != account.currentDeviceID && $0.trust == .verified }.count
        }
    }

    /// Waiting on the other side, with a way to stop.
    @ViewBuilder
    private func waiting(symbol: String, title: String, message: String, status: String) -> some View {
        SheetHeader(symbol: symbol, title: title, message: message)
        SheetBar {
            ProgressView().controlSize(.small)
            Text(status)
                .foregroundStyle(.secondary)
        } trailing: {
            Button("Cancel", action: stop)
                .keyboardShortcut(.cancelAction)
        }
    }

    /// A request from elsewhere: who it's from, and whether to go ahead.
    @ViewBuilder private var incoming: some View {
        if let request = flow.request {
            switch flow.subject {
            case .thisMac:
                SheetHeader(symbol: "laptopcomputer.and.iphone",
                            title: "Verify This Mac?",
                            message: "One of your other devices asked to verify this Mac. Accept if you started this on it.")
                DeviceDetails(request: request)
            case .device(let name, let id):
                SheetHeader(symbol: "laptopcomputer.and.iphone",
                            title: "Verify “\(name ?? id)”?",
                            message: "Accept only if you just signed in on it. If you didn’t, someone else may know your password.")
                DeviceDetails(request: request)
            case .person(let id, let name):
                SheetHeader(symbol: "person.badge.shield.checkmark",
                            title: "Verify \(name ?? id)?",
                            message: "\(name ?? id) asked to verify with you. You’ll each check the same emoji on your screens, in person or on a call you trust.")
                PersonDetails(request: request, media: account.media)
            }
        }
        SheetBar {
            Button("Decline") {
                dismiss()
                flow.cancel()
            }
            .keyboardShortcut(.cancelAction)
            Button("Accept", action: flow.accept)
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder private func comparing(_ code: VerificationFlow.Code) -> some View {
        let isEmoji = if case .emoji = code { true } else { false }
        let what = isEmoji ? "emoji" : "numbers"
        let message = switch flow.subject {
        case .thisMac: "Check that your other device shows the same \(what), in the same order."
        case .device: "Check that \(partner) shows the same \(what), in the same order."
        case .person: "Check with \(partner) that their screen shows the same \(what), in the same order."
        }
        SheetHeader(symbol: nil, title: isEmoji ? "Compare Emoji" : "Compare Numbers", message: message)
        CodeView(code: code)
            .padding(.vertical, 4)
    }

    @ViewBuilder private var verified: some View {
        switch flow.subject {
        case .thisMac:
            SheetHeader(symbol: "checkmark.seal.fill", tint: .green, isFilled: true,
                        title: "This Mac Is Verified",
                        message: "Your encrypted messages can be read here, and your other devices trust this Mac.")
        case .device(let name, let id):
            SheetHeader(symbol: "checkmark.seal.fill", tint: .green, isFilled: true,
                        title: "“\(name ?? id)” Is Verified",
                        message: "It can read your encrypted messages, and your other devices trust it.")
        case .person(let id, let name):
            SheetHeader(symbol: "checkmark.seal.fill", tint: .green, isFilled: true,
                        title: "\(name ?? id) Is Verified",
                        message: "You’ve confirmed that \(name ?? id) is who they say they are.")
        }
    }

    @ViewBuilder private func ended(_ ending: VerificationFlow.Ending) -> some View {
        switch ending {
        case .mismatch:
            SheetHeader(symbol: "exclamationmark.shield.fill", tint: .red, isFilled: true,
                        title: "The Emoji Didn’t Match",
                        message: "Nothing was verified. If they still don’t match when you try again, someone may be interfering with the connection.")
        case .cancelledThere:
            SheetHeader(symbol: "xmark.circle", tint: .secondary,
                        title: "Verification Cancelled",
                        message: "\(partner.prefix(1).uppercased() + partner.dropFirst()) cancelled it. Nothing was verified.")
        case .timedOut:
            SheetHeader(symbol: "clock", tint: .secondary,
                        title: "Request Timed Out",
                        message: flow.request == nil
                            ? "None of your other devices answered in time. Try again with one of them at hand."
                            : "The request expired before it was answered.")
        case .answeredElsewhere:
            SheetHeader(symbol: "checkmark.circle", tint: .secondary,
                        title: "Answered on Another Device",
                        message: "Another of your devices took this request.")
        case .failed(let message):
            SheetHeader(symbol: "exclamationmark.triangle.fill", tint: .orange,
                        title: "Verification Failed",
                        message: message)
        }
        SheetBar {
            if flow.request == nil, case .thisMac = flow.subject {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again", action: flow.verifyThisMac)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Parts

    /// Who is on the other side, as a sentence names them.
    private var partner: String {
        switch flow.subject {
        case .thisMac: "your other device"
        case .device(let name, let id): "“\(name ?? id)”"
        case .person(let id, let name): name ?? id
        }
    }

    private var subjectSymbol: String {
        if case .person = flow.subject { "person.badge.shield.checkmark" } else { "laptopcomputer.and.iphone" }
    }

    /// Stops what is under way; the other side is told.
    private func stop() {
        dismiss()
        flow.cancel()
    }
}

/// The symbol, title and explanation at the top of each step, centred.
private struct SheetHeader: View {
    let symbol: String?
    var tint: Color = .accentColor
    /// A solid badge with a white mark, for an outcome: verified, or not.
    var isFilled = false
    let title: String
    let message: String
    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 8) {
            if let symbol {
                Group {
                    if isFilled {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, tint)
                    } else {
                        Image(systemName: symbol)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(tint)
                    }
                }
                .font(.system(size: 40))
                .symbolEffect(.bounce, value: isFilled && hasAppeared)
                .onAppear { hasAppeared = true }
                .frame(height: 50)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Along the bottom: what's happening, if anything, then the buttons, trailing.
private struct SheetBar<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            trailing
        }
        .padding(.top, 4)
    }
}

extension SheetBar where Leading == EmptyView {
    init(@ViewBuilder trailing: () -> Trailing) {
        self.init(leading: { EmptyView() }, trailing: trailing)
    }
}

/// One way to verify, as a row to click.
private struct ChoiceRow: View {
    let symbol: String
    let title: String
    let detail: String
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.medium)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0.04),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }
}

/// The seven emoji, or three numbers, both sides show.
private struct CodeView: View {
    let code: VerificationFlow.Code

    var body: some View {
        switch code {
        case .emoji(let emoji):
            // Four, then three: big enough to tell apart at a glance, in reading order.
            VStack(spacing: 10) {
                row(Array(emoji.enumerated().prefix(4)))
                row(Array(emoji.enumerated().dropFirst(4)))
            }
        case .numbers(let numbers):
            HStack(spacing: 20) {
                ForEach(Array(numbers.enumerated()), id: \.offset) { _, number in
                    Text(String(number))
                        .font(.system(size: 34, weight: .medium, design: .rounded))
                        .monospacedDigit()
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func row(_ emoji: [(offset: Int, element: VerificationFlow.Emoji)]) -> some View {
        HStack(spacing: 10) {
            ForEach(emoji, id: \.offset) { index, emoji in
                VStack(spacing: 4) {
                    Text(emoji.symbol)
                        .font(.system(size: 40))
                        .frame(height: 50)
                    Text(emoji.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(width: 88, height: 90)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(index + 1): \(emoji.name)")
            }
        }
    }
}

/// The device a request came from: its name, ID, and when it signed in.
private struct DeviceDetails: View {
    let request: VerificationFlow.Request

    /// “Today at 5:08 PM”: how recently matters more than the date.
    private static let signedIn: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            if let name = request.deviceName {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    Text(name)
                }
            }
            GridRow {
                Text("Device ID").foregroundStyle(.secondary)
                Text(request.deviceID)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            if let firstSeen = request.firstSeen {
                GridRow {
                    Text("Signed in").foregroundStyle(.secondary)
                    Text(Self.signedIn.string(from: firstSeen))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailsBackground()
    }
}

/// The person a request came from.
private struct PersonDetails: View {
    let request: VerificationFlow.Request
    let media: MediaLoader

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(media: media, url: request.senderAvatarURL,
                       name: request.senderName ?? request.senderID, seed: request.senderID, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(request.senderName ?? request.senderID.matrixLocalpart)
                    .fontWeight(.medium)
                Text(request.senderID)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .detailsBackground()
    }
}

private extension View {
    func detailsBackground() -> some View {
        background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
    }
}

/// Verifying with the recovery key instead: it unlocks the account's keys, which verify this Mac.
private struct RecoveryKeyForm: View {
    let account: AccountSession
    let back: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var isBusy = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        SheetHeader(symbol: "key.horizontal",
                    title: "Enter Your Recovery Key",
                    message: "You were given it when you set up encryption, on this Mac or another device.")
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Recovery key", text: $key)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(submit)
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { isFocused = true }
        SheetBar {
            Button("Back", action: back)
            if isBusy { ProgressView().controlSize(.small) }
        } trailing: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Verify", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || isBusy)
        }
    }

    private func submit() {
        guard !key.isEmpty, !isBusy else { return }
        isBusy = true
        error = nil
        Task {
            defer { isBusy = false }
            do {
                try await account.recover(with: key.trimmingCharacters(in: .whitespacesAndNewlines))
                dismiss()
            } catch {
                self.error = error.actionMessage
            }
        }
    }
}
