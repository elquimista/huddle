import SwiftUI

/// Light or dark: as the Mac is set, or one of them whatever it's set to.
enum AppAppearance: String, CaseIterable, Identifiable {
    case automatic, light, dark

    static let key = "appearance"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var summary: String {
        switch self {
        case .automatic: "Light or dark, as your Mac is set"
        case .light: "Light, even when your Mac is dark"
        case .dark: "Dark, even when your Mac is light"
        }
    }

    /// The one chosen in Settings.
    static var chosen: AppAppearance {
        UserDefaults.standard.string(forKey: key).flatMap(AppAppearance.init) ?? .automatic
    }

    /// Puts the chosen appearance on every window, sheet and menu of the app's (nil: the Mac's
    /// own). A Dev build started with HUDDLE_DEV_APPEARANCE keeps that one.
    @MainActor static func apply() {
        NSApp.appearance = switch chosen {
        case .automatic: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        DevHooks.applyAppearance()
    }
}

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

    /// The tab showing, kept across launches; set it to open Settings at a tab.
    static let tabKey = "settingsTab"

    @AppStorage(Self.tabKey) private var tab = Tab.notifications
    /// The height the tabs are given, which the window follows: the tab's own, reached in
    /// steps when it changes (WindowHeightAnimation).
    @State private var shownHeight: CGFloat?
    @State private var resize = WindowHeightAnimation()

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
        .environment(\.settingsFormHeight) { height in
            // The first height at once; a new tab's, or a tab growing, in steps.
            guard let from = shownHeight else { shownHeight = height; return }
            resize.run(from: from, to: height) { shownHeight = $0 }
        }
        .frame(height: shownHeight, alignment: .top)
    }
}

extension EnvironmentValues {
    /// Told a settings tab's height as it's laid out.
    @Entry var settingsFormHeight: (CGFloat) -> Void = { _ in }
}

/// Moves the Settings window from one height to another as Mac preference windows do, eased
/// in and out over a quarter of a second. SwiftUI sizes the window to its content at once, and
/// a SwiftUI animation only moves what's drawn inside it: so the height is stepped, about once
/// a screen refresh, each step a size the window takes.
@MainActor
final class WindowHeightAnimation {
    private static let duration: TimeInterval = 0.25
    private var task: Task<Void, Never>?
    private var target: CGFloat?

    func run(from start: CGFloat, to end: CGFloat, step: @escaping (CGFloat) -> Void) {
        guard end != target else { return }
        target = end
        task?.cancel()
        // With Reduce Motion, straight there.
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, abs(end - start) > 1 else {
            step(end)
            return
        }
        let began = Date()
        task = Task { @MainActor in
            while !Task.isCancelled {
                let t = min(1, Date().timeIntervalSince(began) / Self.duration)
                // Ease in and out: slow to start, quick through the middle, settling at the end.
                let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
                step((start + (end - start) * eased).rounded())
                if t >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }
}

/// One tab's form: grouped, as wide as every other tab, and as tall as what it holds.
private struct SettingsForm<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.settingsFormHeight) private var reportHeight

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { reportHeight($0) }
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
    /// Lines the detail always takes, for one that changes, so the row (and the window) keeps
    /// its height as it does.
    var detailLines: Int? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLines ?? .max, reservesSpace: detailLines != nil)
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
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @AppStorage(MessageLayout.key) private var layout = MessageLayout.modern
    @AppStorage(EmojiSize.key) private var emojiSize = EmojiSize.large

    var body: some View {
        SettingsForm {
            Section {
                SettingRow(title: "Appearance", detail: appearance.summary) {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
            }
            .onChange(of: appearance) { AppAppearance.apply() }
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
                // What the two choices above look like, in the box with them.
                ConversationPreview(layout: layout, emojiSize: emojiSize)
            } header: {
                Text("Messages")
            }
            QuickReactionsSection(layout: layout)
        }
    }
}

/// The six quick reactions, each a button that opens the emoji picker to put another in its
/// place, and how many of them a message's bar shows. Where that's three, a line sets them apart.
private struct QuickReactionsSection: View {
    let layout: MessageLayout
    @State private var editing: Int?

    private var reactions: QuickReactions { .shared }

    var body: some View {
        Section {
            SettingRow(title: "Quick reactions", detail: "Click one to choose another.") {
                HStack(spacing: 3) {
                    ForEach(Array(reactions.emoji.enumerated()), id: \.offset) { index, emoji in
                        if index == reactions.onBarCount {
                            Divider().frame(height: 18).padding(.horizontal, 3)
                        }
                        slot(emoji, at: index)
                    }
                }
            }
            SettingRow(title: "On a message’s bar", detail: barDetail, detailLines: 1) {
                Picker("On a message’s bar", selection: Binding(
                    get: { reactions.onBarCount },
                    set: { count in withAnimation(.snappy(duration: 0.2)) { reactions.setOnBarCount(count) } }
                )) {
                    Text("Three").tag(3)
                    Text("Six").tag(6)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        } header: {
            Text("Reactions")
        } footer: {
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    withAnimation(.snappy(duration: 0.2)) { reactions.restoreDefaults() }
                }
                .disabled(reactions.areDefaults)
            }
        }
    }

    /// Bubbles have no bar of their own; a thread's messages, always in the modern layout, do.
    /// (Where six won't fit, as in a thread beside the conversation, the bar shows three.)
    private var barDetail: String {
        layout == .bubbles
            ? "In threads only, as bubbles have no bar."
            : "As the pointer rests on a message."
    }

    private func slot(_ emoji: String, at index: Int) -> some View {
        QuickReactionSlot(emoji: emoji, index: index, isEditing: editing == index) { editing = index }
            .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } }),
                     arrowEdge: .bottom) {
                EmojiPicker(recordsUse: false) { picked in
                    editing = nil
                    withAnimation(.snappy(duration: 0.2)) { reactions.set(picked, at: index) }
                }
            }
    }
}

/// One quick reaction in Settings: a small well that lights up under the pointer, and outlined
/// in the accent colour while its picker is open.
private struct QuickReactionSlot: View {
    let emoji: String
    let index: Int
    let isEditing: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 17))
                .frame(width: 30, height: 28)
                .background(Color.primary.opacity(isHovering || isEditing ? 0.1 : 0.05),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isEditing ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      lineWidth: isEditing ? 1.5 : 0.5)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Choose another emoji")
        .accessibilityLabel("Quick reaction \(index + 1)")
        .accessibilityValue(emoji)
        .accessibilityHint("Chooses another emoji")
    }
}

/// Two messages as a room would show them with the choices above: the layout, and an
/// emoji-only reply at its size. Always as tall as the tallest choice needs, the messages
/// sitting at its foot as in a room, so the window keeps its height as the choices change.
private struct ConversationPreview: View {
    let layout: MessageLayout
    let emojiSize: EmojiSize

    private struct Line: Identifiable {
        let id: Int
        let sender: String
        /// Their colour (Decorative), as a person's name and avatar have it.
        let color: Int
        let time: String
        let text: String
        var isEmoji = false
    }

    /// Two people, so each layout shows how it tells them apart.
    private let lines = [
        Line(id: 0, sender: "Bob", color: 5, time: "9:41 AM", text: "Shall we ship the build today?"),
        Line(id: 1, sender: "Alice", color: 3, time: "9:42 AM", text: "🎉🙌", isEmoji: true),
    ]

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Each layout with the largest emoji, unseen: the height the choices can need.
            ForEach(MessageLayout.allCases) { layout in
                messages(in: layout, emojiSize: .extraLarge).hidden()
            }
            messages(in: layout, emojiSize: emojiSize)
        }
        // A row of the Messages box, which frames it: a card of its own would be a box in a box.
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
        .animation(.snappy(duration: 0.25), value: layout)
        .animation(.snappy(duration: 0.25), value: emojiSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of messages in the \(layout.title) layout, with emoji \(emojiSize.title.lowercased())")
    }

    private func messages(in layout: MessageLayout, emojiSize: EmojiSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                switch layout {
                case .modern: modernRow(line, emojiSize: emojiSize)
                case .bubbles: bubbleRow(line, emojiSize: emojiSize)
                case .irc: ircRow(line, emojiSize: emojiSize)
                }
            }
        }
    }

    private func text(_ line: Line, emojiSize: EmojiSize) -> some View {
        Text(line.text)
            .font(line.isEmoji ? emojiSize.pointSize.map { .system(size: $0) } ?? .body : .body)
    }

    private func modernRow(_ line: Line, emojiSize: EmojiSize) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Decorative.avatarBackground[line.color])
                .frame(width: 28, height: 28)
                .overlay {
                    Text(String(line.sender.prefix(1)))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(line.sender)
                        .fontWeight(.semibold)
                        .foregroundStyle(Decorative.text[line.color])
                    Text(line.time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                text(line, emojiSize: emojiSize)
            }
        }
        .padding(.top, 9)
    }

    /// Alice's message stands for yours, on the right.
    private func bubbleRow(_ line: Line, emojiSize: EmojiSize) -> some View {
        let isOwn = line.sender == "Alice"
        return HStack {
            if isOwn { Spacer(minLength: 40) }
            Group {
                if line.isEmoji {
                    text(line, emojiSize: emojiSize).padding(isOwn ? .trailing : .leading, Bubble.tailWidth)
                } else {
                    text(line, emojiSize: emojiSize)
                        .padding(Bubble.textInset)
                        .padding(isOwn ? .trailing : .leading, Bubble.tailWidth)
                        .background {
                            BubbleShape(isOwn: isOwn, joinsAbove: false, joinsBelow: false)
                                .fill(isOwn ? Bubble.own : Bubble.others)
                        }
                }
            }
            if !isOwn { Spacer(minLength: 40) }
        }
        .padding(.top, 8)
    }

    private func ircRow(_ line: Line, emojiSize: EmojiSize) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .trailing)
            Text(line.sender)
                .fontWeight(.semibold)
                .foregroundStyle(Decorative.text[line.color])
                .frame(width: 44, alignment: .trailing)
            text(line, emojiSize: emojiSize)
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
    @State private var accountToLabel: AccountSession?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(media: account.media,
                       url: account.avatarURL,
                       name: account.displayName ?? account.userID,
                       seed: account.userID,
                       size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.displayName ?? account.userID.matrixLocalpart)
                        .fontWeight(.medium)
                    if let label = account.label {
                        // The user's own name for the account, set apart from its profile name.
                        Text(label)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                            .accessibilityLabel("Labelled \(label)")
                    }
                }
                Text(account.userID)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                verificationLine
            }
            Spacer(minLength: 8)
            // Signing out is rare and can't be undone: in a menu, not a button on every row. The
            // account's own items, as the title bar's menu has them (AccountMenu).
            Menu {
                AccountMenuContent(sections: { menuSections })
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
        .onAppear {
            if DevHooks.labelPrompt == account.userID.matrixLocalpart { accountToLabel = account }
            if DevHooks.logsMenus {
                print("DEV_SETTINGS_MENU \(account.userID.matrixLocalpart): " + menuSections.map { $0.map(\.title).joined(separator: " | ") }.joined(separator: " | — | "))
                fflush(stdout)
            }
        }
        .accountLabelPrompt(for: $accountToLabel)
    }

    /// The account's menu, its sheets opening here in Settings.
    private var menuSections: [[AccountMenuItem]] {
        AccountMenu.sections(for: account, actions: AccountMenu.Actions(
            label: { accountToLabel = account },
            editProfile: editProfile,
            changePassword: changePassword,
            devices: devices,
            verify: verify,
            recoveryKey: recoveryKey,
            signOut: signOut))
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

