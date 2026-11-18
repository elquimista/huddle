import MatrixRustSDK
import SwiftUI

/// A room's notification setting as a menu of choices, the current one ticked: the default
/// (naming what that is), or one of the room's own.
struct NotificationModeMenu: View {
    let mode: RoomNotificationMode?
    let defaultMode: RoomNotificationMode?
    let choose: (RoomNotificationMode?) -> Void

    var body: some View {
        Menu("Notifications") {
            Toggle(NotificationModeTitles.default(defaultMode), isOn: Binding(get: { mode == nil }, set: { _ in choose(nil) }))
            Divider()
            ForEach(RoomNotificationMode.choices, id: \.self) { choice in
                Toggle(choice.title, isOn: Binding(get: { mode == choice }, set: { _ in choose(choice) }))
            }
        }
    }
}

/// The same choices as a pop-up, with what the setting in force does: for Room Info.
struct NotificationModeRow: View {
    let mode: RoomNotificationMode?
    let defaultMode: RoomNotificationMode?
    let noun: String
    let choose: (RoomNotificationMode?) -> Void

    /// What notifies: the room's own setting, or the default it follows.
    private var effective: RoomNotificationMode? { mode ?? defaultMode }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: effective?.symbol ?? "bell")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                // Level with the title, whose row the pop-up makes taller.
                .frame(height: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Notifications")
                    Spacer(minLength: 8)
                    Picker("Notifications", selection: Binding(get: { mode }, set: { choose($0) })) {
                        Text(NotificationModeTitles.default(defaultMode)).tag(RoomNotificationMode?.none)
                        Divider()
                        ForEach(RoomNotificationMode.choices, id: \.self) { choice in
                            Text(choice.title).tag(Optional(choice))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                    .help("When this \(noun.lowercased()) notifies you")
                }
                .frame(minHeight: 22)
                if let effective {
                    Text(effective.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

enum NotificationModeTitles {
    /// "Default (All Messages)", once the default is known.
    static func `default`(_ mode: RoomNotificationMode?) -> String {
        mode.map { "Default (\($0.title))" } ?? "Default"
    }
}
