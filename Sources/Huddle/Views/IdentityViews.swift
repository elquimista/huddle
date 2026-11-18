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
