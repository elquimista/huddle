import AppKit
import SwiftUI

/// A room's details in the panel beside it: its picture, name and topic (changeable where this
/// account may), whether it's encrypted, when it notifies you, who is in it (with inviting people and, for admins
/// and moderators, changing their roles and removing them), and leaving it.
struct RoomInfoPanelView: View {
    let account: AccountSession
    let roomID: String
    /// Goes to the room's pictures, videos, sounds and files.
    let showMedia: () -> Void
    /// Goes to the room's pinned messages.
    let showPinned: () -> Void
    @State private var details: RoomDetails?

    var body: some View {
        Group {
            if let details {
                RoomInfoContent(account: account, details: details, showMedia: showMedia, showPinned: showPinned)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if details == nil, let room = account.room(id: roomID) {
                details = RoomDetails(room: room, ownUserID: account.userID)
            }
        }
        .onDisappear {
            details?.stop()
            details = nil
        }
    }
}

private struct RoomInfoContent: View {
    let account: AccountSession
    let details: RoomDetails
    let showMedia: () -> Void
    let showPinned: () -> Void
    @State private var isEditing = false
    @State private var draftName = ""
    @State private var draftTopic = ""
    @State private var isSaving = false
    @State private var isChangingPicture = false
    @State private var failure: String?
    @State private var asksToTurnOnEncryption = false
    @State private var asksToLeave = false
    @State private var showsAllMembers = false
    /// Someone about to be taken out of the room, or have their invitation withdrawn.
    @State private var removing: RoomDetails.Member?
    /// In a direct chat, giving the person a name of the user's own (ContactNames.swift), in
    /// the header where their name is.
    @State private var isNaming = false
    @State private var draftNickname = ""
    /// The editor's first field takes the keyboard as it opens, from the message field or
    /// wherever it was: what's typed next is meant for it.
    @FocusState private var focusedField: EditorField?

    private enum EditorField {
        case name, nickname
    }
    /// A role change that can't be undone, waiting to be confirmed.
    @State private var roleChange: RoleChange?
    @State private var actionFailure: ActionFailure?

    private struct ActionFailure {
        let title: String
        let message: String
    }

    private struct RoleChange {
        let member: RoomDetails.Member
        let choice: RoomDetails.RoleChoice
        let isOwnAccount: Bool
    }

    private var canEditText: Bool { details.canChangeName || details.canChangeTopic }

    /// In a direct chat with one other person, that person: whether they are who they say is
    /// what matters most about the chat.
    private var directPerson: RoomDetails.Member? {
        guard details.isDirect else { return nil }
        let others = details.members.filter { !$0.isInvited && $0.userID != account.userID }
        return others.count == 1 ? others[0] : nil
    }
    private var noun: String { details.isDirect ? "Chat" : "Room" }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                Divider()
                encryption
                if let person = directPerson {
                    Divider()
                    PersonIdentityRow(account: account, person: person)
                }
                Divider()
                notifications
                Divider()
                pinnedRow
                Divider()
                mediaRow
                Divider()
                members
                Divider()
                Button(role: .destructive) {
                    asksToLeave = true
                } label: {
                    Label("Leave \(noun)…", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .alert("Turn On Encryption?", isPresented: $asksToTurnOnEncryption) {
            Button("Turn On") { run { try await details.turnOnEncryption() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("From now on, only the people in this \(noun.lowercased()) can read its messages. Encryption can’t be turned off again.")
        }
        .confirmationDialog("Leave “\(details.name)”?", isPresented: $asksToLeave) {
            Button("Leave", role: .destructive) { run { try await account.leave(roomID: details.roomID) } }
        } message: {
            Text("You’ll stop getting its messages, and may need an invitation to come back.")
        }
        .confirmationDialog(removalQuestion, isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { member in
            Button(member.isInvited ? "Withdraw Invitation" : "Remove", role: .destructive) { remove(member) }
        } message: { member in
            Text(member.isInvited
                 ? "They won’t be able to join with it."
                 : "They’ll stop getting its messages, and will see that you removed them.")
        }
        .confirmationDialog(roleChangeQuestion, isPresented: Binding(
            get: { roleChange != nil }, set: { if !$0 { roleChange = nil } }
        ), presenting: roleChange) { change in
            Button("Make \(change.isOwnAccount ? "Yourself" : change.member.name) \(Self.withArticle(change.choice.title))",
                   role: change.isOwnAccount ? .destructive : nil) {
                apply(change.choice, to: change.member)
            }
        } message: { change in
            Text(change.isOwnAccount
                 ? "You can’t undo this. Only someone whose role is above \(change.choice.title) could change it back."
                 : "\(change.member.name) will have as much power as you, so you won’t be able to change their role or remove them later.")
        }
        .alert(actionFailure?.title ?? "", isPresented: Binding(
            get: { actionFailure != nil }, set: { if !$0 { actionFailure = nil } }
        ), presenting: actionFailure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            picture
            if isEditing {
                editor
            } else if isNaming, let person = directPerson {
                nameEditor(for: person)
            } else {
                // A direct chat is the person: the user's name for them, where they've given one,
                // with their own beneath.
                let nickname = directPerson.flatMap { account.contactName(for: $0.userID) }
                Text(nickname ?? details.shownName(names: account.contactNames))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if nickname != nil, let person = directPerson {
                    Text(person.name)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
                if let topic = details.topic {
                    Text(topic)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if canEditText, directPerson == nil {
                    // Somewhere to put one, then; a direct chat is the person, without one.
                    Text("No topic")
                        .foregroundStyle(.tertiary)
                }
                // A direct chat is named after the person: the name to set is the user's own for
                // them, not one for the chat that both would see.
                if let person = directPerson {
                    Button("Set Name…") { startNaming(person) }
                        .controlSize(.small)
                        .padding(.top, 2)
                } else if canEditText {
                    Button("Edit Name and Topic…") { startEditing() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            if let failure, !isEditing, !isNaming {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The room's picture: clicked to change it, where that's allowed.
    /// A direct chat's picture is the person's (unless the chat was given one of its own), and
    /// isn't the user's to change from here: a picture for the chat would be one both see.
    private var picture: some View {
        let shown = details.avatarURL ?? directPerson?.avatarURL
        return EditableAvatar(
            canChange: details.canChangeAvatar && directPerson == nil, isBusy: isChangingPicture,
            hasPicture: details.avatarURL != nil,
            chooseMessage: "Choose a picture for “\(details.name)”",
            choose: { url in
                isChangingPicture = true
                run { try await details.setAvatar(from: url) } done: { isChangingPicture = false }
            },
            remove: {
                isChangingPicture = true
                run { try await details.removeAvatar() } done: { isChangingPicture = false }
            },
            showLarge: shown.map { url in { viewPicture(url) } },
            picture: {
                // A direct chat's looks like the person, as it does in the room list: their
                // colour, and the initial of the name it goes by.
                AvatarView(media: account.media, url: shown,
                           name: directPerson.flatMap { account.contactName(for: $0.userID) }
                               ?? details.shownName(names: account.contactNames),
                           seed: directPerson?.userID ?? details.roomID, size: 76)
            })
    }

    /// The picture at full size, in the viewer messages' pictures open in: the copy already
    /// shown at once, the original once it's in.
    private func viewPicture(_ url: String) {
        let name = directPerson.flatMap { account.contactName(for: $0.userID) ?? $0.name } ?? details.name
        guard let image = ImageAttachment(picture: url, name: name) else { return }
        ImageViewerState.shared.open(image, media: account.media, placeholder: account.media.cached(url: url, size: 76))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if details.canChangeName {
                TextField("Name", text: $draftName, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .name)
                    .onSubmit(save)
            }
            if details.canChangeTopic {
                TextField("Topic", text: $draftTopic, prompt: Text("Topic"), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...6)
            }
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    isEditing = false
                    failure = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || details.canChangeName && draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        // Escape cancels the edit, rather than closing the panel and losing it.
        .preference(key: PanelTakesEscape.self, value: true)
        .task { await Self.focus { focusedField = details.canChangeName ? .name : nil } }
    }

    /// Puts the keyboard in a field just shown, once it's in the window: asked for as it
    /// appears, the focus can stay where it was.
    @MainActor
    static func focus(_ set: () -> Void) async {
        try? await Task.sleep(for: .milliseconds(60))
        set()
    }

    /// The person's name of the user's own, edited where it shows, as a room's name is: their
    /// own name standing in the empty field, as what they'll go by without one.
    private func nameEditor(for person: RoomDetails.Member) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name", text: $draftNickname, prompt: Text(person.name))
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .nickname)
                .onSubmit { saveNickname(for: person) }
            Text("Only you see this name, on all your Macs. Leave it empty to use “\(person.name)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") {
                    isNaming = false
                    failure = nil
                }
                .keyboardShortcut(.cancelAction)
                Button("Save") { saveNickname(for: person) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .task { await Self.focus { focusedField = .nickname } }
        // Escape cancels, rather than closing the panel.
        .preference(key: PanelTakesEscape.self, value: true)
    }

    private func startNaming(_ person: RoomDetails.Member) {
        draftNickname = account.contactName(for: person.userID) ?? ""
        failure = nil
        isEditing = false
        isNaming = true
    }

    private func saveNickname(for person: RoomDetails.Member) {
        guard !isSaving else { return }
        isSaving = true
        failure = nil
        let name = draftNickname
        Task {
            defer { isSaving = false }
            do {
                try await account.setContactName(name, for: person.userID)
                isNaming = false
            } catch {
                failure = error.actionMessage
            }
        }
    }

    private func startEditing() {
        draftName = details.name
        draftTopic = details.topic ?? ""
        failure = nil
        isNaming = false
        isEditing = true
    }

    private func save() {
        guard !isSaving else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        let topic = draftTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                if details.canChangeName, !name.isEmpty, name != details.name { try await details.setName(name) }
                if details.canChangeTopic, topic != (details.topic ?? "") { try await details.setTopic(topic) }
                isEditing = false
            } catch {
                failure = error.actionMessage
            }
        }
    }

    // MARK: Encryption

    private var encryption: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: details.isEncrypted ? "lock.fill" : "lock.open")
                .font(.system(size: 15))
                .foregroundStyle(details.isEncrypted ? Color.green : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(details.isEncrypted ? "Encrypted" : "Not encrypted")
                Text(details.isEncrypted
                     ? "Only the people in this \(noun.lowercased()) can read its messages."
                     : "Your server can read this \(noun.lowercased())’s messages.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if details.canTurnOnEncryption {
                Button("Turn On…") { asksToTurnOnEncryption = true }
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Pinned messages and media

    /// To the room's pinned messages, with how many there are.
    private var pinnedRow: some View {
        let count = account.timeline(for: details.roomID)?.pinnedEventIDs.count ?? 0
        return pageRow("Pinned Messages", systemImage: "pin", detail: count > 0 ? "\(count)" : nil,
                       help: "Messages pinned in this \(noun.lowercased()), in full", action: showPinned)
    }

    private func pageRow(_ title: String, systemImage: String, detail: String?, help: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                Text(title)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// To everything sent in the room as a picture, video, sound or file.
    private var mediaRow: some View {
        pageRow("Media and Files", systemImage: "photo.on.rectangle.angled", detail: nil,
                help: "Images, videos, audio, PDFs and other files sent in this \(noun.lowercased())", action: showMedia)
    }

    // MARK: Notifications

    private var notifications: some View {
        let summary = account.allRooms.first { $0.id == details.roomID }
        return NotificationModeRow(mode: account.notificationModes[details.roomID],
                                   defaultMode: summary.flatMap(account.defaultNotificationMode(for:)),
                                   noun: noun) { mode in
            Task {
                do {
                    try await account.setNotificationMode(mode, for: details.roomID)
                } catch {
                    actionFailure = ActionFailure(title: "Couldn’t Change Notifications", message: error.actionMessage)
                }
            }
        }
    }

    // MARK: Members

    private var members: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(details.joinedCount == 1 ? "1 Member" : "\(details.joinedCount) Members")
                    .font(.subheadline.weight(.semibold))
                if details.invitedCount > 0 {
                    Text("\(details.invitedCount) invited")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if details.canInvite {
                    Button("Invite…") { account.sheet = .invite(roomID: details.roomID) }
                        .controlSize(.small)
                        .help("Invite people to this \(noun.lowercased())")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if !details.membersLoaded {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .padding(12)
            } else {
                let shown = showsAllMembers ? details.members : Array(details.members.prefix(50))
                ForEach(shown) { member in
                    MemberRow(account: account, member: member, noun: noun,
                              identity: account.peopleIdentities[member.userID],
                              verify: !member.isInvited && account.canVerify(member.userID)
                                ? { account.verify(person: member.userID, name: member.name) } : nil,
                              roles: details.roleChoices(for: member),
                              setRole: { choose($0, for: member) },
                              remove: details.canRemove(member) ? { removing = member } : nil)
                }
                // Where each of them stands, asking the server about anyone this Mac doesn't keep
                // track of, so it shows in an unencrypted room too.
                .task(id: shown.map(\.userID)) {
                    await account.refreshIdentities(of: shown.filter { !$0.isInvited }.map(\.userID), fromServer: true)
                }
                if shown.count < details.members.count {
                    Button("Show All \(details.members.count)") { showsAllMembers = true }
                        .buttonStyle(.link)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
            }
        }
        .padding(.bottom, 8)
    }

    private var removalQuestion: String {
        guard let removing else { return "" }
        return removing.isInvited
            ? "Withdraw \(removing.name)’s invitation?"
            : "Remove \(removing.name) from “\(details.name)”?"
    }

    private func remove(_ member: RoomDetails.Member) {
        Task {
            do {
                try await details.remove(member.userID)
            } catch {
                actionFailure = ActionFailure(
                    title: member.isInvited ? "Couldn’t Withdraw the Invitation" : "Couldn’t Remove \(member.name)",
                    message: error.actionMessage)
            }
        }
    }

    /// Changes someone's role, first asking about a change that can't be undone: lowering
    /// this account's own, or raising someone to the same level as this account.
    private func choose(_ choice: RoomDetails.RoleChoice, for member: RoomDetails.Member) {
        guard !choice.isCurrent, choice.isAllowed else { return }
        let isOwnAccount = details.isOwnAccount(member)
        if isOwnAccount || choice.level == details.ownPowerLevel {
            roleChange = RoleChange(member: member, choice: choice, isOwnAccount: isOwnAccount)
        } else {
            apply(choice, to: member)
        }
    }

    private func apply(_ choice: RoomDetails.RoleChoice, to member: RoomDetails.Member) {
        Task {
            do {
                try await details.setPowerLevel(choice.level, for: member.userID)
            } catch {
                actionFailure = ActionFailure(
                    title: details.isOwnAccount(member) ? "Couldn’t Change Your Role" : "Couldn’t Change \(member.name)’s Role",
                    message: error.actionMessage)
            }
        }
    }

    private var roleChangeQuestion: String {
        guard let roleChange else { return "" }
        let who = roleChange.isOwnAccount ? "Yourself" : roleChange.member.name
        return "Make \(who) \(Self.withArticle(roleChange.choice.title))?"
    }

    /// "an Admin", "a Moderator".
    private static func withArticle(_ role: String) -> String {
        (role.first.map { "AEIOU".contains($0) } ?? false ? "an " : "a ") + role
    }

    /// Does something to the room, showing what went wrong if it fails.
    private func run(_ work: @escaping () async throws -> Void, done: @escaping () -> Void = {}) {
        failure = nil
        Task {
            do { try await work() } catch { failure = error.actionMessage }
            done()
        }
    }
}

/// Someone in the room: their picture and name, and their role or that they're only invited.
/// Where this account may change their role or remove them, a button on hover (and the
/// right-click menu) offers to.
private struct MemberRow: View {
    let account: AccountSession
    let member: RoomDetails.Member
    /// "Room" or "Chat".
    let noun: String
    /// What is known of their encryption identity.
    let identity: PersonIdentity?
    /// Set when they can be verified from here.
    let verify: (() -> Void)?
    /// The roles they could be given, when this account may change theirs.
    let roles: [RoomDetails.RoleChoice]?
    let setRole: (RoomDetails.RoleChoice) -> Void
    /// Set when this account may take them out of the room, or withdraw their invitation.
    let remove: (() -> Void)?
    @State private var isHovering = false
    @State private var anchor = MenuAnchor()
    /// Giving them a name of the user's own, in place of theirs in the row, as Finder renames a
    /// file: Return keeps it, Escape doesn't, and clicking elsewhere keeps it too.
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var nameFocused: Bool

    private var removeTitle: String { member.isInvited ? "Withdraw Invitation…" : "Remove from \(noun)…" }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(media: account.media, url: member.avatarURL, name: nickname ?? member.name,
                       seed: member.userID, size: 28)
                .opacity(member.isInvited ? 0.6 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                if isRenaming {
                    nameField
                } else {
                    HStack(spacing: 4) {
                        Text(member.userID == account.userID ? "\(member.name) (you)" : nickname ?? member.name)
                            .lineLimit(1)
                        IdentityBadge(identity: identity)
                    }
                }
                if isRenaming {
                    Text("Only you see this name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if nickname != nil {
                    // Their own name beside their ID, where the user calls them something else.
                    Text(member.name == member.userID ? member.userID : "\(member.name) · \(member.userID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if member.name != member.userID {
                    Text(member.userID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // On hover, the button takes the tag's place.
            if !isRenaming {
            ZStack(alignment: .trailing) {
                Group {
                    if member.isInvited {
                        tag("Invited", color: .secondary)
                    } else if let role = member.role {
                        tag(role, color: .accentColor)
                    }
                }
                .opacity(showsMenuButton ? 0 : 1)
                if hasActions {
                    menuButton
                        .opacity(showsMenuButton ? 1 : 0)
                }
            }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHoverInFrontWindow { isHovering = $0 }
        .contextMenu {
            Button("Copy User ID", action: copyUserID)
            if canName {
                Button("Set Name…", action: startRenaming)
            }
            if let verify {
                Button("Verify \(member.name)…", action: verify)
            }
            if roles != nil || remove != nil { Divider() }
            if let roles {
                Menu("Role") {
                    ForEach(roles) { choice in
                        Toggle(choice.title, isOn: Binding(get: { choice.isCurrent }, set: { _ in setRole(choice) }))
                            .disabled(!choice.isAllowed)
                    }
                }
            }
            if let remove {
                Button(removeTitle, role: .destructive, action: remove)
            }
        }
        .accessibilityElement(children: .combine)
        // While naming, Escape is the field's, not the panel's to close.
        .preference(key: PanelTakesEscape.self, value: isRenaming)
        .task { if DevHooks.renamesMember == member.userID { startRenaming() } }
        .accessibilityActions {
            if canName {
                Button("Set Name", action: startRenaming)
            }
            if let verify {
                Button("Verify \(member.name)", action: verify)
            }
            ForEach(roles?.filter { $0.isAllowed && !$0.isCurrent } ?? []) { choice in
                Button("Make \(choice.title)") { setRole(choice) }
            }
            if let remove {
                Button(member.isInvited ? "Withdraw Invitation" : "Remove from \(noun)", action: remove)
            }
        }
    }

    private var hasActions: Bool { roles != nil || remove != nil || verify != nil || canName }

    /// Anyone but the user can be given a name of their own.
    private var canName: Bool { member.userID != account.userID }

    /// Where their name was: their own name standing in it while it's empty.
    private var nameField: some View {
        TextField("Name", text: $draftName, prompt: Text(member.name))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .focused($nameFocused)
            .onSubmit(finishRenaming)
            .onKeyPress(.escape) {
                isRenaming = false
                return .handled
            }
            .onChange(of: nameFocused) {
                if !nameFocused { finishRenaming() }
            }
            .task { await RoomInfoContent.focus { nameFocused = true } }
            .accessibilityLabel("Your name for \(member.name)")
    }

    private func startRenaming() {
        draftName = nickname ?? ""
        isRenaming = true
    }

    /// Keeps the name typed, or with nothing typed, goes back to theirs.
    private func finishRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name != (nickname ?? "") else { return }
        let account = account
        let userID = member.userID
        FailureAlert.run("Couldn’t Save the Name") { try await account.setContactName(name, for: userID) }
    }

    /// The user's own name for them (ContactNames.swift).
    private var nickname: String? { account.contactName(for: member.userID) }
    private var showsMenuButton: Bool { isHovering && hasActions }

    private var menuButton: some View {
        Button(action: openMenu) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(MenuAnchorView(anchor: anchor))
        .help("More")
        .accessibilityHidden(true)
    }

    private func openMenu() {
        guard let view = anchor.view, hasActions else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(title: "Copy User ID", handler: copyUserID))
        if canName {
            menu.addItem(ClosureMenuItem(title: "Set Name…", handler: startRenaming))
        }
        if let verify {
            menu.addItem(ClosureMenuItem(title: "Verify \(member.name)…", handler: verify))
        }
        if roles != nil || remove != nil { menu.addItem(.separator()) }
        if let roles {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for choice in roles {
                let item = ClosureMenuItem(title: choice.title) { setRole(choice) }
                item.state = choice.isCurrent ? .on : .off
                item.isEnabled = choice.isAllowed
                submenu.addItem(item)
            }
            let item = NSMenuItem(title: "Role", action: nil, keyEquivalent: "")
            item.submenu = submenu
            menu.addItem(item)
        }
        if let remove {
            menu.addItem(ClosureMenuItem(title: removeTitle, handler: remove))
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func copyUserID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(member.userID, forType: .string)
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
