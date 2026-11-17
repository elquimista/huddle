import SwiftUI

/// How messages are laid out in a room.
enum MessageLayout: String, CaseIterable, Identifiable {
    /// Avatar, then the sender's name above their messages.
    case modern
    /// One line per message: time, sender, text. No avatars.
    case irc

    static let key = "messageLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .irc: "IRC"
        }
    }
}

struct SettingsView: View {
    @AppStorage(MessageLayout.key) private var layout = MessageLayout.modern

    var body: some View {
        Form {
            Picker("Message layout:", selection: $layout) {
                ForEach(MessageLayout.allCases) { layout in
                    Text(layout.title).tag(layout)
                }
            }
            .pickerStyle(.radioGroup)
            Text(layout == .modern
                 ? "Avatars, with each sender's name above their messages."
                 : "Compact, one line per message: time, sender, then the text.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 400)
    }
}
