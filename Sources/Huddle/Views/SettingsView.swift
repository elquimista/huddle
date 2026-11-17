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

    var summary: String {
        switch self {
        case .modern: "Avatars, with names above messages"
        case .irc: "Compact, one line per message"
        }
    }
}

extension EnvironmentValues {
    /// A layout that overrides the user's choice, for places that need one (threads, whose
    /// narrow panel suits only the modern layout).
    @Entry var forcedMessageLayout: MessageLayout? = nil
    /// How wide a message's content (text, pictures, players) can be where it is shown.
    /// Pictures and players shrink to fit it instead of spilling out of a narrow column.
    @Entry var messageContentWidth: CGFloat = .infinity
    /// The width a timeline has been given, set by whatever lays it out. Measuring the timeline
    /// itself won't do: its content sizes itself to the measurement, and a picture that is too
    /// wide keeps the timeline too wide.
    @Entry var timelineWidth: CGFloat = 0
}

struct SettingsView: View {
    @AppStorage(MessageLayout.key) private var layout = MessageLayout.modern
    @AppStorage(NotificationSettings.enabledKey) private var notificationsEnabled = NotificationSettings.enabledByDefault
    @AppStorage(NotificationSettings.soundKey) private var notificationSound = true
    @AppStorage(OwnPresence.sharingKey) private var sharesPresence = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $notificationsEnabled) {
                    Text("Show notifications")
                    Text("For new messages, mentions and invitations.")
                }
                Toggle(isOn: $notificationSound) {
                    // A disabled switch dims by itself; its label has to be told.
                    Text("Play sound")
                        .foregroundStyle(notificationsEnabled ? .primary : .tertiary)
                    Text("For direct messages, mentions and invitations.")
                        .foregroundStyle(notificationsEnabled ? .secondary : .tertiary)
                }
                .disabled(!notificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                // Sized and coloured like the rows' own descriptions, and lined up with their text.
                Text("Your Matrix account's notification rules decide which rooms notify.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }

            Section {
                Toggle(isOn: $sharesPresence) {
                    Text("Show when I'm online")
                    Text("People in your direct chats see when you're online or away.")
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Some servers don't share anyone's online status.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 10)
            }

            Section("Message Layout") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(MessageLayout.allCases) { option in
                        LayoutOption(layout: option, isSelected: layout == option) { layout = option }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        // The window takes its height from the form, so nothing scrolls or clips.
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One choice of message layout: a small drawing of it, its name and a line about it.
private struct LayoutOption: View {
    let layout: MessageLayout
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                LayoutThumbnail(layout: layout)
                    .frame(height: 92)
                    .frame(maxWidth: .infinity)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.separator),
                                          lineWidth: isSelected ? 2.5 : 1)
                    }
                VStack(spacing: 2) {
                    Text(layout.title)
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(layout.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(layout.title) layout. \(layout.summary)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A schematic of a few messages in the given layout: bars for text, dots for avatars.
private struct LayoutThumbnail: View {
    let layout: MessageLayout

    private static let text = Color.primary.opacity(0.26)
    private static let time = Color.primary.opacity(0.13)
    private static let senders: [Color] = [.orange, .teal, .purple]

    var body: some View {
        Group {
            switch layout {
            case .modern: modern
            case .irc: irc
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var modern: some View {
        VStack(alignment: .leading, spacing: 9) {
            group(sender: 0, name: 34, lines: [96, 62])
            group(sender: 1, name: 26, lines: [78])
        }
    }

    private func group(sender: Int, name: CGFloat, lines: [CGFloat]) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(Self.senders[sender])
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    bar(name, Self.senders[sender])
                    bar(14, Self.time)
                }
                ForEach(lines, id: \.self) { bar($0, Self.text) }
            }
            .padding(.top, 2)
        }
    }

    private var irc: some View {
        VStack(alignment: .leading, spacing: 8) {
            line(sender: 0, name: 30, text: 92)
            line(sender: 0, name: 30, text: 58)
            line(sender: 1, name: 22, text: 76)
            line(sender: 2, name: 26, text: 84)
            line(sender: 1, name: 22, text: 44)
        }
    }

    private func line(sender: Int, name: CGFloat, text: CGFloat) -> some View {
        HStack(spacing: 6) {
            bar(14, Self.time)
            bar(name, Self.senders[sender])
                .frame(width: 30, alignment: .trailing)
            bar(text, Self.text)
        }
    }

    private func bar(_ width: CGFloat, _ color: Color) -> some View {
        Capsule().fill(color).frame(width: width, height: 5)
    }
}
