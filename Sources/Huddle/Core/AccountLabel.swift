import Foundation

/// A name of the user's own for one of their accounts ("Work", "Personal"), for telling it from
/// their others where that matters: which account a notification arrived on, Settings ▸
/// Accounts, the title bar's tooltips and its +N menu. Kept in the account's own data on the
/// server, under a type of Huddle's, so Huddle on the user's other Macs has it too; other
/// apps leave it alone.
private let labelEventType = "app.huddle.account"

extension AccountSession {
    /// Reads the label from the account's own copy of its data, which sync keeps current (it's
    /// read along with the typing setting, in Typing.swift).
    func readLabel() async {
        let json = try? await client.accountData(eventType: labelEventType)
        let object = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let value = Self.cleaned(object?["label"] as? String)
        // Just changed here: the account's copy says so only once sync brings the change back.
        if let saved = labelSaved {
            guard value == saved.value || Date.now.timeIntervalSince(saved.date) > 60 else { return }
            labelSaved = nil
        }
        if value != label { label = value }
    }

    /// Sets the label, or takes it away with nil or nothing but spaces.
    func setLabel(_ newLabel: String?) async throws {
        let value = Self.cleaned(newLabel)
        let before = label
        label = value
        labelSaved = (value, .now)
        do {
            let json = try JSONSerialization.data(withJSONObject: value.map { ["label": $0] } ?? [:])
            try await client.setAccountData(eventType: labelEventType, content: String(decoding: json, as: UTF8.self))
        } catch {
            label = before
            labelSaved = nil
            throw error
        }
    }

    private static func cleaned(_ label: String?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
