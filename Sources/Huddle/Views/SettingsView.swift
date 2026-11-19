import SwiftUI

/// How messages are laid out in a room.
enum MessageLayout: String, CaseIterable, Identifiable {
    /// Avatar, then the sender's name above their messages.
    case modern
    /// Chat bubbles: yours on the right, others' on the left.
    case bubbles
    /// One line per message: time, sender, text. No avatars.
    case irc

    static let key = "messageLayout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modern: "Modern"
        case .bubbles: "Bubbles"
        case .irc: "IRC"
        }
    }

    var summary: String {
        switch self {
        case .modern: "Avatars, with names above messages"
        case .bubbles: "Chat bubbles, yours on the right"
        case .irc: "Compact, one line per message"
        }
    }
}

/// How a message of nothing but a few emoji is drawn.
enum EmojiSize: String, CaseIterable, Identifiable {
    case normal
    case large
    case extraLarge

    static let key = "emojiOnlySize"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .normal: "Normal"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    /// The emoji's point size; nil for the size of ordinary text.
    var pointSize: CGFloat? {
        switch self {
        case .normal: nil
        case .large: 30
        case .extraLarge: 44
        }
    }
}

extension EnvironmentValues {
    /// A layout that overrides the user's choice, for places that need one (threads, whose
    /// narrow panel suits only the modern layout).
    @Entry var forcedMessageLayout: MessageLayout? = nil
    /// The layout a timeline's messages are drawn in, read once by the timeline rather than by
    /// every message, each of which would otherwise keep its own watch on the setting.
    @Entry var messageLayout: MessageLayout = .modern
    /// How emoji-only messages are drawn; read once by the timeline, like the layout.
    @Entry var emojiSize: EmojiSize = .large
    /// How wide the IRC layout's column of names is; read once by the timeline, like the layout.
    @Entry var ircNameWidth: CGFloat = IRCNameColumn.defaultWidth
    /// How wide a message's content (text, pictures, players) can be where it is shown.
    /// Pictures and players shrink to fit it instead of spilling out of a narrow column.
    @Entry var messageContentWidth: CGFloat = .infinity
    /// The width a timeline has been given, set by whatever lays it out. Measuring the timeline
    /// itself won't do: its content sizes itself to the measurement, and a picture that is too
    /// wide keeps the timeline too wide.
    @Entry var timelineWidth: CGFloat = 0
    /// The account whose room is on screen, for what reaches beyond one timeline: forwarding a
    /// message to another of its rooms, or the room's pinned messages.
    @Entry var accountSession: AccountSession? = nil
}

/// The IRC layout's column of names: each room's as wide as it was last dragged to there, and
/// the standard width in a room where it never was.
enum IRCNameColumn {
    static let defaultWidth: CGFloat = 88
    static let widths: ClosedRange<CGFloat> = 40...260
    /// Where the column starts: after the time.
    static let leading: CGFloat = 54 + 8

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width.rounded(), widths.lowerBound), widths.upperBound)
    }
}

/// The rooms' names column widths, by room ID, read from the defaults once and kept in memory:
/// looking one up as a conversation draws costs nothing, and a room open in two places (the
/// conversation and a thread beside it) follows a change made in either.
@MainActor @Observable
final class IRCNameWidths {
    static let shared = IRCNameWidths()
    private static let key = "ircNameColumnWidths"

    private var widths: [String: Double]

    private init() {
        widths = (UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func width(for roomID: String) -> CGFloat {
        IRCNameColumn.clamped(widths[roomID].map { CGFloat($0) } ?? IRCNameColumn.defaultWidth)
    }

    /// Saved only when it changes, and the standard width not at all: a room set back to it is
    /// one fewer to remember.
    func setWidth(_ width: CGFloat, for roomID: String) {
        let width = IRCNameColumn.clamped(width)
        let saved: Double? = width == IRCNameColumn.defaultWidth ? nil : Double(width)
        guard widths[roomID] != saved else { return }
        widths[roomID] = saved
        UserDefaults.standard.set(widths, forKey: Self.key)
    }
}

/// The Settings window: a tab for each kind of setting, as Mac apps have them. Each tab is as
/// tall as what it holds, and the window takes the height of the tab showing.
struct SettingsView: View {
    enum Tab: String {
        case notifications, appearance, privacy, accounts, updates
    }

    @AppStorage("settingsTab") private var tab = Tab.notifications

    var body: some View {
        TabView(selection: $tab) {
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
                .tag(Tab.notifications)
            AppearanceSettingsTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
                .tag(Tab.appearance)
            PrivacySettingsTab()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
                .tag(Tab.privacy)
            AccountsSettingsTab()
                .tabItem { Label("Accounts", systemImage: "at") }
                .tag(Tab.accounts)
            UpdateSettingsTab()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
                .tag(Tab.updates)
        }
    }
}

/// One tab's form: grouped, as wide as every other tab, and as tall as what it holds.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A note under a section, sized and coloured like the rows' own descriptions and lined up with
/// their text.
private struct SectionNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
    }
}

/// A row with its name and a line about it on the left and its control on the right, like a
/// toggle's row. Laid out by hand for controls the form would otherwise put under their label.
private struct SettingRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            control
        }
    }
}

// MARK: - Notifications

private struct NotificationSettingsTab: View {
    @AppStorage(NotificationSettings.enabledKey) private var notificationsEnabled = NotificationSettings.enabledByDefault
    @AppStorage(NotificationSettings.soundKey) private var notificationSound = true

    var body: some View {
        SettingsForm {
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
            } footer: {
                SectionNote(text: "Your Matrix account’s notification rules decide which rooms notify.")
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsTab: View {
    @AppStorage(MessageLayout.key) private var layout = MessageLayout.modern
    @AppStorage(EmojiSize.key) private var emojiSize = EmojiSize.large

    var body: some View {
        SettingsForm {
            Section {
                SettingRow(title: "Layout", detail: layout.summary) {
                    Picker("Layout", selection: $layout) {
                        ForEach(MessageLayout.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                SettingRow(title: "Emoji-only messages", detail: "Just a few emoji, drawn bigger.") {
                    Picker("Emoji-only messages", selection: $emojiSize) {
                        ForEach(EmojiSize.allCases) { size in
                            Text(size.title).tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            } header: {
                Text("Messages")
            }
            Section {
                ConversationPreview(layout: layout, emojiSize: emojiSize)
            } header: {
                Text("Preview")
            }
        }
    }
}

/// A few messages as a room would show them with the choices above: the layout, and an
/// emoji-only message at its size. Always as tall as the tallest choice needs, the messages
/// sitting at its foot as in a room, so the window keeps its height as the choices change.
private struct ConversationPreview: View {
    let layout: MessageLayout
    let emojiSize: EmojiSize

    private struct Line: Identifiable {
        let id: Int
        let sender: String
        let color: Color
        let time: String
        let text: String
        var isEmoji = false
        /// The first of a run of messages from one person, which carries their name.
        var startsGroup = true
    }

    private let lines = [
        Line(id: 0, sender: "Bob", color: .orange, time: "9:41 AM", text: "Shall we ship the build today?"),
        Line(id: 1, sender: "Alice", color: .indigo, time: "9:42 AM", text: "Yes, right after lunch"),
        Line(id: 2, sender: "Alice", color: .indigo, time: "9:42 AM", text: "🎉🙌", isEmoji: true, startsGroup: false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                switch layout {
                case .modern: modernRow(line)
                case .bubbles: bubbleRow(line, next: lines.first { $0.id == line.id + 1 })
                case .irc: ircRow(line)
                }
            }
        }
        // The section's own box frames it: a card of its own inside would be a box in a box.
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .bottomLeading)
        .animation(.snappy(duration: 0.25), value: layout)
        .animation(.snappy(duration: 0.25), value: emojiSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of messages in the \(layout.title) layout, with emoji \(emojiSize.title.lowercased())")
    }

    private func text(_ line: Line) -> some View {
        Text(line.text)
            .font(line.isEmoji ? emojiSize.pointSize.map { .system(size: $0) } ?? .body : .body)
    }

    private func modernRow(_ line: Line) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if line.startsGroup {
                Circle()
                    .fill(line.color)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Text(String(line.sender.prefix(1)))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            } else {
                Color.clear.frame(width: 28, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if line.startsGroup {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.sender)
                            .fontWeight(.semibold)
                            .foregroundStyle(line.color)
                        Text(line.time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                text(line)
            }
        }
        .padding(.top, line.startsGroup ? 9 : 3)
    }

    /// Alice's messages stand for yours, on the right.
    private func bubbleRow(_ line: Line, next: Line?) -> some View {
        let isOwn = line.sender == "Alice"
        let endsRun = next?.sender != line.sender
        return HStack {
            if isOwn { Spacer(minLength: 40) }
            Group {
                if line.isEmoji {
                    text(line).padding(isOwn ? .trailing : .leading, Bubble.tailWidth)
                } else {
                    text(line)
                        .padding(Bubble.textInset)
                        .padding(isOwn ? .trailing : .leading, Bubble.tailWidth)
                        .background {
                            BubbleShape(isOwn: isOwn, joinsAbove: !line.startsGroup, joinsBelow: !endsRun)
                                .fill(isOwn ? Bubble.own : Bubble.others)
                        }
                }
            }
            if !isOwn { Spacer(minLength: 40) }
        }
        .padding(.top, line.startsGroup ? 8 : 2)
    }

    private func ircRow(_ line: Line) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .trailing)
            Text(line.sender)
                .fontWeight(.semibold)
                .foregroundStyle(line.color)
                .frame(width: 44, alignment: .trailing)
            text(line)
        }
        .padding(.top, 3)
    }
}

// MARK: - Privacy

private struct PrivacySettingsTab: View {
    @Environment(AccountStore.self) private var store
    @AppStorage(OwnPresence.sharingKey) private var sharesPresence = true
    @AppStorage(HistoryIndexer.defaultsKey) private var indexesFullHistory = true
    @AppStorage(EncryptionPreferences.excludesInsecureDevicesKey) private var excludesInsecureDevices = false

    /// Every account's full-history pass, taken together.
    private var progress: (done: Int, total: Int)? {
        let running = store.accounts.map(\.historyIndexer).filter(\.isRunning)
        guard !running.isEmpty else { return nil }
        return (running.reduce(0) { $0 + $1.roomsDone }, running.reduce(0) { $0 + $1.roomsTotal })
    }

    var body: some View {
        SettingsForm {
            Section {
                Toggle(isOn: $sharesPresence) {
                    Text("Show when I’m online")
                    Text("People in your direct chats see when you’re online or away.")
                }
                TypingSharingRows(accounts: store.accounts)
            } footer: {
                SectionNote(text: "Sharing goes both ways: turn one off and you won’t see it from others either. Some servers don’t share anyone’s online status.")
            }
            Section {
                Toggle(isOn: $indexesFullHistory) {
                    Text("Search the full history of encrypted rooms")
                    Text("Downloads each room’s history once, to index it on this Mac.")
                }
                if indexesFullHistory, let progress {
                    SettingRow(title: "Indexing older messages",
                               detail: "\(progress.done) of \(progress.total) rooms done") {
                        ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                            .frame(width: 120)
                    }
                }
            } footer: {
                SectionNote(text: "The index is encrypted and never leaves this Mac. Your server searches unencrypted rooms itself.")
            }
            Section {
                Toggle(isOn: $excludesInsecureDevices) {
                    Text("Exclude unverified devices")
                    Text("Your encrypted messages can only be read on devices their owners have verified, and messages from devices that aren’t are hidden.")
                }
                // The accounts' clients took the setting when Huddle opened.
                if excludesInsecureDevices != EncryptionPreferences.excludedInsecureDevicesAtLaunch {
                    SettingRow(title: "Takes effect when Huddle restarts",
                               detail: "Huddle quits and opens again.") {
                        Button("Restart Now") { AppRelauncher.relaunch() }
                    }
                }
            } footer: {
                SectionNote(text: "People whose apps don’t verify their devices won’t be able to read what you send, and this Mac must be verified to send encrypted messages. Element calls this “exclude insecure devices”.")
            }
        }
        .onChange(of: indexesFullHistory) { _, on in
            for account in store.accounts {
                if on { account.historyIndexer.start(for: account) } else { account.historyIndexer.stop() }
            }
        }
    }
}

/// Element's own setting, kept with each account on the server: one switch for one account, or
/// one for each.
private struct TypingSharingRows: View {
    let accounts: [AccountSession]

    var body: some View {
        if accounts.count == 1, let account = accounts.first {
            TypingSharingToggle(account: account) {
                Text("Show when I’m typing")
                Text("People in a room see when you’re writing a message there. Saved to your account, so Element follows it too.")
            }
        } else if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show when I’m typing")
                Text("People in a room see when you’re writing a message there. Saved to each account, so Element follows it too.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(accounts) { account in
                TypingSharingToggle(account: account) {
                    HStack(spacing: 8) {
                        AvatarView(media: account.media, url: account.avatarURL,
                                   name: account.displayName ?? account.userID, seed: account.userID, size: 20)
                        Text(account.displayName ?? account.userID.matrixLocalpart)
                        Text(account.userID)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }
}

private struct TypingSharingToggle<Label: View>: View {
    let account: AccountSession
    @ViewBuilder let label: Label
    @State private var failure: String?

    var body: some View {
        Toggle(isOn: Binding(get: { account.sharesTyping }, set: save)) {
            label
            if let failure {
                Text(failure).foregroundStyle(.red)
            }
        }
    }

    private func save(_ shares: Bool) {
        failure = nil
        Task {
            do {
                try await account.setSharesTyping(shares)
            } catch {
                failure = "Couldn’t save: \(error.actionMessage)"
            }
        }
    }
}

// MARK: - Accounts

private struct AccountsSettingsTab: View {
    @Environment(AccountStore.self) private var store
    @State private var accountToSignOut: AccountSession?
    @State private var accountToVerify: AccountSession?
    @State private var accountForRecoveryKey: AccountSession?
    @State private var accountToEdit: AccountSession?
    @State private var accountToChangePassword: AccountSession?
    @State private var accountForDevices: AccountSession?

    var body: some View {
        SettingsForm {
            Section {
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account,
                                       editProfile: { accountToEdit = account },
                                       changePassword: { accountToChangePassword = account },
                                       devices: { accountForDevices = account },
                                       verify: { accountToVerify = account },
                                       recoveryKey: { accountForRecoveryKey = account },
                                       signOut: { accountToSignOut = account })
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Add Account…", action: addAccount)
                }
            }
        }
        .sheet(item: $accountToVerify) { account in
            VerificationSheet(account: account)
        }
        .sheet(item: $accountForRecoveryKey) { account in
            RecoveryKeySheet(account: account)
        }
        .sheet(item: $accountToEdit) { account in
            ProfileSheet(account: account)
        }
        .sheet(item: $accountToChangePassword) { account in
            ChangePasswordSheet(account: account)
        }
        .sheet(item: $accountForDevices) { account in
            DevicesSheet(account: account)
        }
        .confirmationDialog("Sign out of \(accountToSignOut?.userID ?? "")?",
                            isPresented: Binding(get: { accountToSignOut != nil },
                                                 set: { if !$0 { accountToSignOut = nil } })) {
            Button("Sign Out", role: .destructive) {
                if let account = accountToSignOut {
                    Task { await store.signOut(account) }
                }
            }
        } message: {
            Text("Local message history and encryption keys for this account will be removed from this Mac.")
        }
    }
}

extension AccountsSettingsTab {
    /// Signing in happens in the main window, as for the first account: a sheet that tall would
    /// hang off the foot of this window, which is only as tall as its list of accounts.
    private func addAccount() {
        let settings = NSApp.keyWindow
        store.isAddingAccount = true
        NSApp.windows.first { $0 !== settings && $0.isVisible && $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        settings?.close()
    }
}

/// An account: who it is, whether this Mac is a trusted session of it, and in its menu,
/// editing its profile and password, and signing out.
private struct AccountSettingsRow: View {
    let account: AccountSession
    let editProfile: () -> Void
    let changePassword: () -> Void
    let devices: () -> Void
    let verify: () -> Void
    let recoveryKey: () -> Void
    let signOut: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(media: account.media,
                       url: account.avatarURL,
                       name: account.displayName ?? account.userID,
                       seed: account.userID,
                       size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName ?? account.userID.matrixLocalpart)
                    .fontWeight(.medium)
                Text(account.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                verificationLine
            }
            Spacer(minLength: 8)
            // Signing out is rare and can't be undone: in a menu, not a button on every row.
            Menu {
                Button("Copy User ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(account.userID, forType: .string)
                }
                if account.verification == .unverified {
                    Button("Verify This Mac…", action: verify)
                }
                if account.managesRecoveryKey {
                    Button(account.recoveryState == .disabled ? "Set Up Recovery Key…" : "Change Recovery Key…",
                           action: recoveryKey)
                }
                Divider()
                Button("Edit Profile…", action: editProfile)
                if account.signsInWithOAuth {
                    Button("Manage Account…") { openAccountPage(of: account) }
                } else {
                    Button("Change Password…", action: changePassword)
                }
                Button("Devices…", action: devices)
                Divider()
                Button("Sign Out…", action: signOut)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this account")
            .accessibilityLabel("More for \(account.displayName ?? account.userID)")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var verificationLine: some View {
        switch account.verification {
        case .verified:
            Label("This Mac is verified", systemImage: "checkmark.seal.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .labelStyle(TintedIconLabel(tint: .green))
            if account.suggestsRecoveryKey {
                HStack(spacing: 6) {
                    Label("No recovery key", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .labelStyle(TintedIconLabel(tint: .orange))
                    Button("Set Up…", action: recoveryKey)
                        .buttonStyle(.link)
                        .font(.subheadline)
                }
            }
        case .unverified:
            HStack(spacing: 6) {
                Label("This Mac isn’t verified", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .labelStyle(TintedIconLabel(tint: .orange))
                Button("Verify…", action: verify)
                    .buttonStyle(.link)
                    .font(.subheadline)
            }
        default:
            EmptyView()
        }
    }
}

/// A label whose icon has its own colour, its text the surrounding one.
private struct TintedIconLabel: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

// MARK: - Updates

private struct UpdateSettingsTab: View {
    @Bindable private var updater = AppUpdater.shared

    var body: some View {
        SettingsForm {
            Section {
                SettingRow(title: "Huddle \(AppUpdater.version)", detail: lastChecked) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck)
                }
            } footer: {
                if !updater.isAvailable {
                    SectionNote(text: "The Dev build doesn’t update itself.")
                }
            }
            Section {
                Toggle(isOn: $updater.checksAutomatically) {
                    Text("Check for updates automatically")
                    Text("Once a day.")
                }
                Toggle(isOn: $updater.installsAutomatically) {
                    // A disabled switch dims by itself; its label has to be told.
                    Text("Download and install automatically")
                        .foregroundStyle(updater.checksAutomatically ? .primary : .tertiary)
                    Text("Updates are installed when you quit Huddle.")
                        .foregroundStyle(updater.checksAutomatically ? .secondary : .tertiary)
                }
                .disabled(!updater.checksAutomatically)
                Toggle(isOn: $updater.includesBetas) {
                    Text("Include beta versions")
                    Text("New features sooner, before they’re finished.")
                }
            }
            .disabled(!updater.isAvailable)
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastChecked else { return "Not checked for updates yet." }
        if date.timeIntervalSinceNow > -60 { return "Last checked just now." }
        return "Last checked \(date.formatted(.relative(presentation: .named)))."
    }
}

