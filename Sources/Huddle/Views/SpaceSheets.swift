import MatrixRustSDK
import SwiftUI

/// Whichever of the account's sheets is up: making a room or space, adding rooms to a
/// space, or leaving one.
struct AccountSheetView: View {
    let account: AccountSession
    let sheet: AccountSheet

    var body: some View {
        switch sheet {
        case .newMessage: NewMessageSheet(account: account)
        case .invite(let roomID): NewMessageSheet(account: account, purpose: .invite(roomID: roomID))
        case .profile: ProfileSheet(account: account)
        case .changePassword: ChangePasswordSheet(account: account)
        case .devices: DevicesSheet(account: account)
        case .verify: VerificationSheet(account: account)
        case .recoveryKey: RecoveryKeySheet(account: account)
        case .newSpace: NewSpaceSheet(account: account)
        case .newRoom(let spaceID): NewRoomSheet(account: account, spaceID: spaceID)
        case .addRooms(let spaceID): AddRoomsSheet(account: account, spaceID: spaceID)
        case .leaveSpace(let spaceID): LeaveSpaceSheet(account: account, spaceID: spaceID)
        }
    }
}

// MARK: - Shared parts

/// A sheet's title and what it is for, above its form.
private struct SheetTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Cancel and the sheet's action along its bottom, with what went wrong, if anything, beside them.
private struct SheetButtons: View {
    let action: String
    var role: ButtonRole?
    let isEnabled: Bool
    let isBusy: Bool
    let failure: String?
    let perform: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .help(failure)
            } else if isBusy {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            // Return shouldn't do something that can't be taken back.
            Button(action, role: role, action: perform)
                .keyboardShortcut(role == .destructive ? nil : .defaultAction)
                .disabled(!isEnabled || isBusy)
        }
    }
}

/// A grouped form that is only as tall as what is in it, so the sheet fits it exactly.
private struct SheetForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, -20)
            .padding(.vertical, -12)
    }
}

private extension View {
    /// A note under a form section, along its leading edge as System Settings has them.
    func sheetFootnote() -> some View {
        self
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - New space

struct NewSpaceSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var isPublic = false
    @State private var isBusy = false
    @State private var failure: String?
    @FocusState private var nameIsFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "New Space",
                       detail: "A space gathers rooms in one place, so the people in it can find them and join.")
            SheetForm {
                Section {
                    TextField("Name", text: $name, prompt: Text("Required"))
                        .focused($nameIsFocused)
                    TextField("Topic", text: $topic, prompt: Text("Optional"))
                }
                Section {
                    Picker("Who can join", selection: $isPublic) {
                        Text("Only people invited").tag(false)
                        Text("Anyone").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(isPublic ? "Anyone can find this space and join it."
                                  : "People join when you invite them. You can share its rooms with its members.")
                        .sheetFootnote()
                }
            }
            SheetButtons(action: "Create", isEnabled: !trimmedName.isEmpty, isBusy: isBusy,
                         failure: failure, perform: create)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameIsFocused = true }
    }

    private func create() {
        guard !trimmedName.isEmpty, !isBusy else { return }
        isBusy = true
        failure = nil
        Task {
            defer { isBusy = false }
            do {
                let spaceID = try await account.createSpace(name: trimmedName, topic: topic, isPublic: isPublic)
                dismiss()
                account.selectedSpaceID = spaceID
                account.selectedRoomID = nil
                account.browsingSpaceID = spaceID
            } catch {
                failure = error.actionMessage
            }
        }
    }
}

// MARK: - New room

struct NewRoomSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var spaceID: String?
    @State private var access: AccountSession.RoomAccess
    /// Off unless switched on: new rooms start unencrypted, as new chats do.
    @State private var isEncrypted = false
    /// A room made on an earlier try that couldn't then be put in its space.
    @State private var createdRoomID: String?
    @State private var isBusy = false
    @State private var failure: String?
    @FocusState private var nameIsFocused: Bool

    init(account: AccountSession, spaceID: String?) {
        self.account = account
        let space = spaceID.flatMap { account.editableSpaceIDs.contains($0) ? $0 : nil }
        _spaceID = State(initialValue: space)
        _access = State(initialValue: space.map { .spaceMembers($0) } ?? .invited)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The spaces a room can be made in: those this account may add rooms to, by name.
    private var spaces: [(id: String, name: String)] {
        account.editableSpaceIDs
            .map { (id: $0, name: account.spaceName($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var accessNote: String {
        switch access {
        case .spaceMembers: "Anyone in \(account.spaceName(spaceID ?? "")) can find this room and join it. Others need an invitation."
        case .invited: "People join when they’re invited."
        case .anyone: "Anyone can find this room and join it."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "New Room")
            SheetForm {
                Section {
                    TextField("Name", text: $name, prompt: Text("Required"))
                        .focused($nameIsFocused)
                    TextField("Topic", text: $topic, prompt: Text("Optional"))
                    if !spaces.isEmpty {
                        Picker("Space", selection: $spaceID) {
                            Text("None").tag(String?.none)
                            Divider()
                            ForEach(spaces, id: \.id) { space in
                                Text(space.name).tag(Optional(space.id))
                            }
                        }
                    }
                }
                Section {
                    Picker("Who can join", selection: $access) {
                        if let spaceID {
                            Text("Members of \(account.spaceName(spaceID))").tag(AccountSession.RoomAccess.spaceMembers(spaceID))
                        }
                        Text("Only people invited").tag(AccountSession.RoomAccess.invited)
                        Text("Anyone").tag(AccountSession.RoomAccess.anyone)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(accessNote)
                        .sheetFootnote()
                }
                Section {
                    Toggle("End-to-end encryption", isOn: $isEncrypted)
                } footer: {
                    Text(isEncrypted ? "Only the people in the room can read its messages. This can’t be turned off later."
                                     : "The server can read the room’s messages. Encryption can be turned on later.")
                        .sheetFootnote()
                }
            }
            SheetButtons(action: createdRoomID == nil ? "Create" : "Try Again", isEnabled: !trimmedName.isEmpty,
                         isBusy: isBusy, failure: failure, perform: create)
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { nameIsFocused = true }
        .onChange(of: spaceID) { _, space in
            // Who can join follows the space: its members by default, and never a space it's not in.
            if let space {
                if access != .anyone { access = .spaceMembers(space) }
            } else if case .spaceMembers = access {
                access = .invited
            }
        }
    }

    private func create() {
        guard !trimmedName.isEmpty, !isBusy else { return }
        isBusy = true
        failure = nil
        Task {
            defer { isBusy = false }
            do {
                let roomID: String
                if let created = createdRoomID {
                    // Made last time; only putting it in the space is left.
                    if let spaceID { try await account.addNewRoom(created, toSpace: spaceID) }
                    roomID = created
                } else {
                    roomID = try await account.createRoom(name: trimmedName, topic: topic, access: access,
                                                          encrypted: isEncrypted, inSpace: spaceID)
                }
                dismiss()
                // Show the room in the list: under the space it went into, or with every room.
                if account.selectedSpaceID != nil {
                    account.selectedSpaceID = spaceID.flatMap(account.topLevelSpace(containing:))
                }
                account.selectedRoomID = roomID
            } catch let error as RoomNotAddedToSpace {
                createdRoomID = error.roomID
                failure = "The room was made, but couldn’t be put in \(account.spaceName(spaceID ?? "")): \(error.actionMessage)"
            } catch {
                failure = error.actionMessage
            }
        }
    }
}

// MARK: - Adding rooms to a space

struct AddRoomsSheet: View {
    let account: AccountSession
    let spaceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: Set<String> = []
    @State private var isBusy = false
    @State private var failure: String?

    /// The account's chats, rooms and spaces not yet in this one, by name, in the room list's
    /// order: people, then rooms. A space this one is in can't go inside it.
    private var candidates: (people: [RoomSummary], rooms: [RoomSummary], spaces: [RoomSummary]) {
        let inSpace = account.roomIDs(inSpace: spaceID)
        let needle = query.trimmingCharacters(in: .whitespaces)
        let all = account.allRooms
            .filter { !$0.isInvite && $0.id != spaceID && !inSpace.contains($0.id) }
            .filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let people = all.filter { !$0.isSpace && $0.isDirect }
        let rooms = all.filter { !$0.isSpace && !$0.isDirect }
        let spaces = all.filter { $0.isSpace && !account.roomIDs(inSpace: $0.id).contains(spaceID) }
        return (people, rooms, spaces)
    }

    var body: some View {
        let candidates = candidates
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                SheetTitle(title: "Add Rooms to \(account.spaceName(spaceID))",
                           detail: "They stay where they are for everyone already in them, and members of the space can find them here too. A direct chat stays private to the people in it.")
                SearchField(text: $query, prompt: "Find a room or person")
            }
            .padding(16)
            Divider()
            Group {
                if candidates.people.isEmpty && candidates.rooms.isEmpty && candidates.spaces.isEmpty {
                    if query.isEmpty {
                        ContentUnavailableView("Nothing to Add", systemImage: "square.stack",
                                               description: Text("Every room you’re in is already in this space."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                } else {
                    List {
                        if !candidates.people.isEmpty {
                            Section("People") {
                                ForEach(candidates.people) { row($0) }
                            }
                        }
                        if !candidates.rooms.isEmpty {
                            Section("Rooms") {
                                ForEach(candidates.rooms) { row($0) }
                            }
                        }
                        if !candidates.spaces.isEmpty {
                            Section("Spaces") {
                                ForEach(candidates.spaces) { row($0) }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxHeight: .infinity)
            Divider()
            SheetButtons(action: chosen.count > 1 ? "Add \(chosen.count) Rooms" : "Add",
                         isEnabled: !chosen.isEmpty, isBusy: isBusy, failure: failure, perform: add)
                .padding(16)
        }
        .frame(width: 440, height: 520)
    }

    private func row(_ room: RoomSummary) -> some View {
        let isOn = Binding(get: { chosen.contains(room.id) },
                           set: { if $0 { chosen.insert(room.id) } else { chosen.remove(room.id) } })
        return Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                AvatarView(media: account.media, url: room.avatarURL, name: room.name, seed: room.avatarSeed,
                           size: 26, isSquare: room.isSpace)
                    .accessibilityHidden(true)
                Text(room.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 2)
        .listRowSeparator(.hidden)
    }

    private func add() {
        guard !chosen.isEmpty, !isBusy else { return }
        isBusy = true
        failure = nil
        // In list order, so they appear in the space as they were chosen from.
        let all = candidates
        let ordered = (all.people + all.rooms + all.spaces).map(\.id).filter(chosen.contains)
        Task {
            defer { isBusy = false }
            do {
                try await account.addRooms(ordered, toSpace: spaceID)
                dismiss()
            } catch {
                failure = error.actionMessage
            }
        }
    }
}

// MARK: - Leaving a space

struct LeaveSpaceSheet: View {
    let account: AccountSession
    let spaceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var handle: LeaveSpaceHandle?
    /// The space's rooms the account is in, innermost first, without the space itself.
    @State private var rooms: [LeaveSpaceRoom] = []
    @State private var isLastOwner = false
    @State private var chosen: Set<String> = []
    @State private var isBusy = false
    @State private var failure: String?

    private var name: String { account.spaceName(spaceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetTitle(title: "Leave \(name)?",
                       detail: rooms.isEmpty ? "It will no longer be one of your spaces."
                                             : "It will no longer be one of your spaces. Its rooms you’re in stay in your room list unless you leave them too.")
            if isLastOwner {
                Label("You’re the only owner of \(name). Once you leave, nobody can change it or add rooms to it.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if handle == nil, failure == nil {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
            } else if !rooms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Also leave:")
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Button(chosen.count == rooms.count ? "Select None" : "Select All") {
                            chosen = chosen.count == rooms.count ? [] : Set(rooms.map(\.spaceRoom.roomId))
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(rooms, id: \.spaceRoom.roomId) { room in
                                row(room)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 220)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator) }
                }
            }
            SheetButtons(action: chosen.isEmpty ? "Leave Space"
                                                : "Leave Space and \(chosen.count) Room\(chosen.count == 1 ? "" : "s")",
                         role: .destructive, isEnabled: handle != nil, isBusy: isBusy,
                         failure: failure, perform: leave)
        }
        .padding(20)
        .frame(width: 440)
        .task { await load() }
    }

    private func row(_ room: LeaveSpaceRoom) -> some View {
        let id = room.spaceRoom.roomId
        let isOn = Binding(get: { chosen.contains(id) },
                           set: { if $0 { chosen.insert(id) } else { chosen.remove(id) } })
        return Toggle(isOn: isOn) {
            HStack(spacing: 10) {
                AvatarView(media: account.media, url: room.spaceRoom.avatarUrl, name: room.spaceRoom.shownName,
                           seed: id, size: 24, isSquare: room.spaceRoom.roomType == .space)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(room.spaceRoom.shownName)
                        .lineLimit(1)
                    if room.isLastOwner {
                        Text("You’re its only owner")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.leading, 4)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func load() async {
        do {
            guard let handle = try await account.leaveSpaceHandle(spaceID) else { return }
            let all = handle.rooms()
            isLastOwner = all.first { $0.spaceRoom.roomId == spaceID }?.isLastOwner ?? false
            rooms = all.filter { $0.spaceRoom.roomId != spaceID && $0.spaceRoom.state == .joined }
            self.handle = handle
        } catch {
            failure = error.actionMessage
        }
    }

    private func leave() {
        guard let handle, !isBusy else { return }
        isBusy = true
        failure = nil
        Task {
            defer { isBusy = false }
            do {
                try await account.leave(space: spaceID, with: handle, alsoLeaving: chosen)
                dismiss()
            } catch {
                failure = error.actionMessage
            }
        }
    }
}
