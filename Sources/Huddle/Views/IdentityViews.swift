import SwiftUI

/// Under a message whose sender can't be fully trusted: what's wrong, in a few words, with what
/// that means in its tooltip.
struct ShieldNote: View {
    let shield: MessageRow.Shield

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: shield.isSerious ? "exclamationmark.shield.fill" : "exclamationmark.shield")
            Text(shield.label)
        }
        .font(.caption)
        .foregroundStyle(shield.isSerious ? Color.red : Color.secondary)
        .help(shield.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(shield.label). \(shield.detail)")
    }
}

/// Above the composer while someone in the room has a changed identity: who, what it may mean,
/// and the one thing to do about it. One person at a time; the next shows once that's done.
struct IdentityWarningBar: View {
    let warning: IdentityWarning
    let account: AccountSession?
    @State private var isBusy = false
    @State private var failure: String?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .font(.system(size: 22))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .fontWeight(.medium)
                Text(failure ?? detail)
                    .font(.callout)
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if isBusy { ProgressView().controlSize(.small) }
            Button(warning.wasVerified ? "Withdraw Verification" : "OK", action: act)
                .disabled(isBusy || account == nil)
                .help(warning.wasVerified
                      ? "Stop treating \(warning.name) as verified, so you can verify them again"
                      : "Accept \(warning.name)’s new identity")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(tint.opacity(0.08))
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
        .accessibilityElement(children: .contain)
    }

    private var tint: Color { warning.wasVerified ? .red : .orange }

    private var title: String {
        warning.wasVerified ? "\(warning.name)’s verified identity was reset" : "\(warning.name)’s identity was reset"
    }

    private var detail: String {
        warning.wasVerified
            ? "You verified \(warning.name) before. Withdraw that, then verify them again to trust their new identity."
            : "It may be a new device, or someone else may have their account. If in doubt, check with them another way."
    }

    private func act() {
        guard let account, !isBusy else { return }
        isBusy = true
        failure = nil
        Task {
            defer { isBusy = false }
            do {
                if warning.wasVerified {
                    try await account.withdrawVerification(of: warning.userID)
                } else {
                    try await account.acceptIdentity(of: warning.userID)
                }
            } catch {
                failure = error.actionMessage
            }
        }
    }
}

/// Beside a member's name: a seal for someone verified, a warning for someone whose identity
/// changed, nothing otherwise.
struct IdentityBadge: View {
    let identity: PersonIdentity?

    var body: some View {
        switch identity {
        case .verified:
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help("Verified")
                .accessibilityLabel("Verified")
        case .changed:
            Image(systemName: "exclamationmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Their identity was reset")
                .accessibilityLabel("Identity reset")
        case .changedSinceVerified:
            Image(systemName: "exclamationmark.shield.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help("Their verified identity was reset")
                .accessibilityLabel("Verified identity reset")
        case .unverified, .noIdentity, nil:
            EmptyView()
        }
    }
}

/// In a direct chat's Room Info: whether the other person is who they say, and what to do about
/// it, without having to look for it in a menu.
struct PersonIdentityRow: View {
    let account: AccountSession
    let person: RoomDetails.Member
    @State private var isBusy = false
    @State private var failure: String?

    private var identity: PersonIdentity? { account.peopleIdentities[person.userID] }
    private var name: String { person.name }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
                .font(.system(size: 15))
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(failure ?? detail)
                    .font(.callout)
                    .foregroundStyle(failure == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
                // A change has more to say than one button.
                if identity == .changed || identity == .changedSinceVerified {
                    HStack(spacing: 8) {
                        if identity == .changed {
                            if account.canVerify(person.userID) {
                                Button("Verify…", action: verify)
                            }
                            Button("Accept", action: accept)
                                .help("Accept \(name)’s new identity")
                        } else {
                            Button("Withdraw Verification", action: withdraw)
                                .help("Stop treating \(name) as verified, so you can verify them again")
                        }
                    }
                    .controlSize(.small)
                    .disabled(isBusy)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if identity == .unverified, account.canVerify(person.userID) {
                Button("Verify…", action: verify)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .task(id: person.userID) {
            await account.refreshIdentities(of: [person.userID], fromServer: true)
        }
    }

    @ViewBuilder private var icon: some View {
        switch identity {
        case nil:
            ProgressView().controlSize(.small)
        case .verified:
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case .unverified:
            Image(systemName: "checkmark.seal").foregroundStyle(.secondary)
        case .changed:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.orange)
        case .changedSinceVerified:
            Image(systemName: "exclamationmark.shield.fill").foregroundStyle(.red)
        case .noIdentity:
            Image(systemName: "seal").foregroundStyle(.tertiary)
        }
    }

    private var title: String {
        switch identity {
        case nil: "Checking \(name)’s identity…"
        case .verified: "\(name) is verified"
        case .unverified: "\(name) isn’t verified"
        case .changed: "\(name)’s identity was reset"
        case .changedSinceVerified: "\(name)’s verified identity was reset"
        case .noIdentity: "\(name) can’t be verified"
        }
    }

    private var detail: String {
        switch identity {
        case nil: "Seeing whether you’ve confirmed it’s really them."
        case .verified: "You’ve confirmed it’s really them."
        case .unverified:
            account.canVerifyPeople ? "Compare emoji with them to confirm it’s really them."
                : "Verify this Mac first, then you can verify them."
        case .changed: "It may be a new device, or someone else. Check with them, then verify them or accept it."
        case .changedSinceVerified: "Withdraw your verification, then verify them again."
        case .noIdentity: "Their app hasn’t set up the keys verifying needs."
        }
    }

    private func verify() {
        account.verify(person: person.userID, name: person.name)
    }

    private func accept() {
        run { try await account.acceptIdentity(of: person.userID) }
    }

    private func withdraw() {
        run { try await account.withdrawVerification(of: person.userID) }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        failure = nil
        Task {
            defer { isBusy = false }
            do { try await work() } catch { failure = error.actionMessage }
        }
    }
}

/// At the start of the message field: a faint closed lock where messages are encrypted, an open
/// one where they aren't (amber in a direct chat or private room, where encryption is expected;
/// grey in a public room, where it usually isn't). Clicked, the room's details.
struct EncryptionGlyph: View {
    let encryption: RoomEncryption
    let showInfo: (() -> Void)?

    var body: some View {
        switch encryption {
        case .unknown:
            EmptyView()
        case .encrypted:
            glyph("lock.fill", style: AnyShapeStyle(.tertiary),
                  help: "Encrypted: only the people in this room can read what you send",
                  label: "Encrypted")
        case .notEncrypted(let isPublic):
            glyph("lock.open.fill", style: isPublic ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange),
                  help: "Not encrypted: your server can read what you send",
                  label: "Not encrypted")
        }
    }

    private func glyph(_ symbol: String, style: AnyShapeStyle, help: String, label: String) -> some View {
        Button {
            showInfo?()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style)
                .contentShape(Rectangle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
        .accessibilityHint(showInfo == nil ? "" : "Shows the room’s details")
    }
}
