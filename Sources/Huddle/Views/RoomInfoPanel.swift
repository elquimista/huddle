import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A room's details in the panel beside it: its picture, name and topic (changeable where this
/// account may), whether it's encrypted, who is in it (with inviting people and, for admins
/// and moderators, removing them), and leaving it.
struct RoomInfoPanelView: View {
    let account: AccountSession
    let roomID: String
    @State private var details: RoomDetails?

    var body: some View {
        Group {
            if let details {
                RoomInfoContent(account: account, details: details)
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
    @State private var removalFailure: RemovalFailure?

    private struct RemovalFailure {
        let title: String
        let message: String
    }

    private var canEditText: Bool { details.canChangeName || details.canChangeTopic }
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
            Text("From now on, only the people in this \(noun.lowercased()) can read its messages. Encryption can't be turned off again.")
        }
        .confirmationDialog("Leave “\(details.name)”?", isPresented: $asksToLeave) {
            Button("Leave", role: .destructive) { run { try await account.leave(roomID: details.roomID) } }
        } message: {
            Text("You'll stop getting its messages, and may need an invitation to come back.")
        }
        .confirmationDialog(removalQuestion, isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        ), presenting: removing) { member in
            Button(member.isInvited ? "Withdraw Invitation" : "Remove", role: .destructive) { remove(member) }
        } message: { member in
            Text(member.isInvited
                 ? "They won't be able to join with it."
                 : "They'll stop getting its messages, and will see that you removed them.")
        }
        .alert(removalFailure?.title ?? "", isPresented: Binding(
            get: { removalFailure != nil }, set: { if !$0 { removalFailure = nil } }
        ), presenting: removalFailure) { _ in
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
            } else {
                Text(details.name)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                if let topic = details.topic {
                    Text(topic)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else if canEditText {
                    Text("No topic")
                        .foregroundStyle(.tertiary)
                }
                if canEditText {
                    Button("Edit Name and Topic…") { startEditing() }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            if let failure, !isEditing {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// The room's picture: clicked to change it, where that's allowed.
    private var picture: some View {
        AvatarPicker(account: account, details: details, isBusy: isChangingPicture) { action in
            switch action {
            case .choose(let url):
                isChangingPicture = true
                run { try await details.setAvatar(from: url) } done: { isChangingPicture = false }
            case .remove:
                isChangingPicture = true
                run { try await details.removeAvatar() } done: { isChangingPicture = false }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            if details.canChangeName {
                TextField("Name", text: $draftName, prompt: Text("Name"))
                    .textFieldStyle(.roundedBorder)
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
                    .disabled(isSaving || details.canChangeName && draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func startEditing() {
        draftName = details.name
        draftTopic = details.topic ?? ""
        failure = nil
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
                     : "Your server can read this \(noun.lowercased())'s messages.")
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
                              remove: details.canRemove(member) ? { removing = member } : nil)
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
            ? "Withdraw \(removing.name)'s invitation?"
            : "Remove \(removing.name) from “\(details.name)”?"
    }

    private func remove(_ member: RoomDetails.Member) {
        Task {
            do {
                try await details.remove(member.userID)
            } catch {
                removalFailure = RemovalFailure(
                    title: member.isInvited ? "Couldn't Withdraw the Invitation" : "Couldn't Remove \(member.name)",
                    message: error.actionMessage)
            }
        }
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

/// The room's picture, large, and the way to change it: a click chooses a new one (or,
/// for a room that has one, offers to remove it too).
private struct AvatarPicker: View {
    enum Action {
        case choose(URL)
        case remove
    }

    let account: AccountSession
    let details: RoomDetails
    let isBusy: Bool
    let perform: (Action) -> Void
    @State private var isHovering = false
    @State private var anchor = MenuAnchor()

    private var canChange: Bool { details.canChangeAvatar && !isBusy }

    var body: some View {
        Button(action: open) {
            AvatarView(media: account.media, url: details.avatarURL, name: details.name, seed: details.roomID, size: 76)
                .overlay {
                    if isBusy {
                        Circle().fill(.black.opacity(0.35))
                        ProgressView().controlSize(.small).tint(.white)
                    } else if canChange, isHovering {
                        Circle().fill(.black.opacity(0.4))
                        Text("Edit")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canChange)
        .background(MenuAnchorView(anchor: anchor))
        .onHover { isHovering = $0 }
        .help(canChange ? "Change the picture" : "")
        .accessibilityLabel(canChange ? "Change picture" : "Picture")
    }

    private func open() {
        guard details.avatarURL != nil, let view = anchor.view else { return choose() }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Choose Picture…") { choose() })
        menu.addItem(ClosureMenuItem(title: "Remove Picture") { perform(.remove) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture for “\(details.name)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(.choose(url))
    }
}

/// Someone in the room: their picture and name, and their role or that they're only invited.
/// For those this account may remove, a button on hover (and the right-click menu) offers to.
private struct MemberRow: View {
    let account: AccountSession
    let member: RoomDetails.Member
    /// "Room" or "Chat".
    let noun: String
    /// Set when this account may take them out of the room, or withdraw their invitation.
    let remove: (() -> Void)?
    @State private var isHovering = false
    @State private var anchor = MenuAnchor()

    private var removeTitle: String { member.isInvited ? "Withdraw Invitation…" : "Remove from \(noun)…" }

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(media: account.media, url: member.avatarURL, name: member.name, seed: member.userID, size: 28)
                .opacity(member.isInvited ? 0.6 : 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(member.userID == account.userID ? "\(member.name) (you)" : member.name)
                    .lineLimit(1)
                if member.name != member.userID {
                    Text(member.userID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            // On hover, the button takes the tag's place.
            ZStack(alignment: .trailing) {
                Group {
                    if member.isInvited {
                        tag("Invited", color: .secondary)
                    } else if let role = member.role {
                        tag(role, color: .accentColor)
                    }
                }
                .opacity(showsMenuButton ? 0 : 1)
                if remove != nil {
                    menuButton
                        .opacity(showsMenuButton ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy User ID", action: copyUserID)
            if let remove {
                Divider()
                Button(removeTitle, role: .destructive, action: remove)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let remove {
                Button(member.isInvited ? "Withdraw Invitation" : "Remove from \(noun)", action: remove)
            }
        }
    }

    private var showsMenuButton: Bool { isHovering && remove != nil }

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
        guard let view = anchor.view, let remove else { return }
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: "Copy User ID", handler: copyUserID))
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: removeTitle, handler: remove))
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
