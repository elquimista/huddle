import MatrixRustSDK
import SwiftUI

/// Starting a chat with one person or several. People are found by name or Matrix ID and
/// gathered in the To field; then going takes the user to the chat already had with them
/// (one person, or a group of exactly those people), or makes one: unencrypted unless asked
/// to be encrypted, and for a group, named or not. With nothing typed, the people
/// already chatted with come first.
///
/// The same picker invites people to a room: then those already in it can't be chosen.
struct NewMessageSheet: View {
    /// What the sheet is for.
    enum Purpose: Equatable {
        case message
        case invite(roomID: String)
    }

    let account: AccountSession
    var purpose: Purpose = .message
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// The people in the To field, in the order they were added.
    @State private var chosen: [Person] = []
    @State private var groupName = ""
    @State private var found: [Person] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    /// For a typed Matrix ID: true once the server has said nobody has it.
    @State private var typedIDNotFound = false
    /// The row Return adds, moved with the arrow keys.
    @State private var highlighted: String?
    @State private var isStarting = false
    @State private var failure: String?
    /// A group chat already had with exactly the people chosen, found as they are chosen.
    @State private var existingGroupID: String?
    /// True when the user wants a new group even though one with these people exists.
    @State private var startsNewGroup = false
    /// Off unless ticked: new chats start unencrypted.
    @State private var isEncrypted = false
    /// Changed to put the cursor back in the To field.
    @State private var focusRequest = 0
    /// When inviting: who is in the room already, or invited.
    @State private var memberships: [String: MembershipState] = [:]

    /// Someone to message, and the chat already had with them, if any.
    struct Person: Identifiable, Equatable {
        var id: String { userID }
        let userID: String
        let name: String
        let avatarURL: String?
        var roomID: String?
        /// Why they can't be chosen: a typed Matrix ID the server says nobody has (some
        /// servers accept an invitation to anyone at all), or, when inviting, someone in the
        /// room already. Shown, so it's clear why.
        var unavailable: String?
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The room people are being invited to, if they are.
    private var inviteRoomID: String? {
        if case .invite(let roomID) = purpose { roomID } else { nil }
    }

    private var title: String {
        guard let inviteRoomID else { return "New Message" }
        guard let name = account.allRooms.first(where: { $0.id == inviteRoomID })?.name else { return "Invite People" }
        return "Invite to “\(name)”"
    }

    /// Marks someone already in the room people are being invited to.
    private func marked(_ person: Person) -> Person {
        guard inviteRoomID != nil, let membership = memberships[person.userID] else { return person }
        var person = person
        person.unavailable = membership == .invite ? "Invited already" : "In this room already"
        return person
    }

    /// People with a direct chat already, most recent first.
    private var recent: [Person] {
        var seen = Set<String>()
        return account.allRooms.compactMap { room -> Person? in
            guard room.isDirect, !room.isInvite, let userID = room.directUserID,
                  seen.insert(userID).inserted else { return nil }
            return Person(userID: userID, name: room.name, avatarURL: room.avatarURL, roomID: room.id)
        }
    }

    /// What the list shows, leaving out those already chosen: those already chatted with who
    /// match, then the server's matches, then (for a full Matrix ID nobody else matched)
    /// that ID itself.
    private var people: [Person] {
        let chosenIDs = Set(chosen.map(\.userID))
        guard !trimmed.isEmpty else {
            // Those in the room already are left out, rather than shown and not choosable.
            return Array(recent.filter { !chosenIDs.contains($0.userID) && memberships[$0.userID] == nil }.prefix(30))
        }
        let matchingRecent = recent.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.userID.localizedCaseInsensitiveContains(trimmed)
        }
        var seen = Set(matchingRecent.map(\.userID))
        var result = matchingRecent
        for var person in found where seen.insert(person.userID).inserted {
            person.roomID = recent.first { $0.userID == person.userID }?.roomID
            result.append(person)
        }
        if let typed = typedUserID, !seen.contains(typed) {
            result.append(Person(userID: typed, name: typed, avatarURL: nil,
                                 unavailable: typedIDNotFound ? "Nobody on this server has this Matrix ID" : nil))
        }
        return result.filter { !chosenIDs.contains($0.userID) }.map(marked)
    }

    /// Whether what's typed matches only people already in the To field.
    private var matchesAreAllChosen: Bool {
        let chosenIDs = Set(chosen.map(\.userID))
        let matching = recent.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) || $0.userID.localizedCaseInsensitiveContains(trimmed)
        } + found
        return !matching.isEmpty && matching.allSatisfy { chosenIDs.contains($0.userID) }
    }

    /// The query, when it is a whole Matrix ID ("@name:server.org").
    private var typedUserID: String? {
        guard trimmed.hasPrefix("@"), trimmed.contains(":"), !trimmed.contains(where: \.isWhitespace),
              trimmed != account.userID else { return nil }
        return trimmed
    }

    /// Whether going takes the user to a chat they already have, rather than making one.
    private var goesToExisting: Bool {
        guard inviteRoomID == nil else { return false }
        return switch chosen.count {
        case 0: false
        case 1: chosen[0].roomID != nil
        default: existingGroupID != nil && !startsNewGroup
        }
    }

    private var actionTitle: String {
        if inviteRoomID != nil { return chosen.count > 1 ? "Invite \(chosen.count) People" : "Invite" }
        if goesToExisting { return "Go to Chat" }
        return chosen.count > 1 ? "Start Group Chat" : "Start Chat"
    }

    private var existingGroupName: String? {
        existingGroupID.flatMap { id in account.allRooms.first { $0.id == id }?.name }
    }

    /// The height of a row in the To field: a chip's.
    private static let rowHeight: CGFloat = 20

    var body: some View {
        let people = people
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                toField(people)
                if inviteRoomID == nil, chosen.count > 1, existingGroupID != nil, !startsNewGroup {
                    existingGroupNote
                        .transition(.opacity)
                }
                if inviteRoomID == nil, chosen.count > 1, !goesToExisting {
                    TextField("Group name", text: $groupName, prompt: Text("Group name (optional)"))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator) }
                        .onSubmit(start)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(16)
            .animation(.snappy(duration: 0.2), value: chosen.count > 1)
            .animation(.snappy(duration: 0.2), value: goesToExisting)
            Divider()
            list(people)
                .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                // Only for a chat about to be made: an existing one's can't be changed.
                if inviteRoomID == nil, !chosen.isEmpty, !goesToExisting, failure == nil {
                    Toggle("End-to-end encryption", isOn: $isEncrypted)
                        .toggleStyle(.checkbox)
                        .help(isEncrypted
                              ? "Only the people in the chat can read its messages. This can’t be turned off later."
                              : "Your server will be able to read this chat’s messages. Encryption can be turned on later, but not off.")
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(failure)
                } else if isStarting {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // Return in the To field (with nothing typed) does this; a default button would
                // take Return from the field even while someone is being picked.
                Button(actionTitle, action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosen.isEmpty || isStarting)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
        .onAppear { highlighted = people.first { $0.unavailable == nil }?.id }
        .task(id: trimmed) { await search(trimmed) }
        .task(id: chosen.map(\.userID)) { await findExistingGroup() }
        .task {
            if let inviteRoomID { memberships = await account.memberships(in: inviteRoomID) }
        }
        // Only someone who can be chosen is highlighted.
        .onChange(of: people.filter { $0.unavailable == nil }.map(\.id)) { _, ids in
            if !ids.contains(highlighted ?? "") { highlighted = ids.first }
        }
    }

    // MARK: The To field

    /// The people chosen, as chips, and the field to find more, wrapping onto more lines as
    /// it fills.
    private func toField(_ people: [Person]) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // As tall as a row of chips, so the label lines up with the first of them.
            Text("To:")
                .foregroundStyle(.secondary)
                .frame(height: Self.rowHeight)
            FlowLayout(spacing: 4) {
                ForEach(chosen) { person in
                    PersonChip(account: account, person: person) { remove(person) }
                }
                CommandTextField(text: $query, placeholder: chosen.isEmpty ? "Name or Matrix ID" : "",
                                 focusRequest: focusRequest,
                                 onSubmit: { submit(people) },
                                 onMove: { move($0, in: people) },
                                 onDeleteWhenEmpty: {
                                     // Backspace in an empty field takes off the last person.
                                     if let last = chosen.last { remove(last) }
                                 },
                                 accessibilityLabel: "To")
                    .frame(minWidth: 120, minHeight: Self.rowHeight)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 30)
        .background(.background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.separator) }
        .contentShape(Rectangle())
        .onTapGesture { focusRequest += 1 }
    }

    /// Return: adds the highlighted person while something is typed (or nobody is chosen
    /// yet); with the field empty and people chosen, goes.
    private func submit(_ people: [Person]) {
        if trimmed.isEmpty, !chosen.isEmpty {
            start()
        } else if let person = people.first(where: { $0.id == highlighted })
                    ?? people.first(where: { $0.unavailable == nil }) {
            add(person)
        }
    }

    private func add(_ person: Person) {
        guard person.unavailable == nil, !chosen.contains(where: { $0.userID == person.userID }) else { return }
        var person = person
        // Someone found in the directory may have a chat with this account all the same.
        if inviteRoomID == nil, person.roomID == nil { person.roomID = account.existingDirectChat(with: person.userID) }
        withAnimation(.snappy(duration: 0.15)) { chosen.append(person) }
        query = ""
        failure = nil
        focusRequest += 1
    }

    private func remove(_ person: Person) {
        withAnimation(.snappy(duration: 0.15)) { chosen.removeAll { $0.userID == person.userID } }
        failure = nil
        focusRequest += 1
    }

    /// "You already have a group with these people", and a way to make another anyway.
    private var existingGroupNote: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .foregroundStyle(.secondary)
            Text(existingGroupName.map { "You already have a group with them, “\($0)”." }
                 ?? "You already have a group with them.")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Start a New One") { startsNewGroup = true }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 2)
    }

    /// Looks for a group chat with exactly the people chosen, so that going takes the user
    /// back to it rather than making another.
    private func findExistingGroup() async {
        existingGroupID = nil
        startsNewGroup = false
        guard inviteRoomID == nil, chosen.count > 1 else { return }
        let ids = Set(chosen.map(\.userID))
        let found = await account.existingGroupChat(with: ids)
        guard !Task.isCancelled, Set(chosen.map(\.userID)) == ids else { return }
        existingGroupID = found
    }

    // MARK: The list

    @ViewBuilder private func list(_ people: [Person]) -> some View {
        if people.isEmpty {
            if trimmed.isEmpty {
                if chosen.isEmpty {
                    ContentUnavailableView {
                        Label(inviteRoomID == nil ? "Message Someone" : "Invite Someone",
                              systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text(inviteRoomID == nil
                             ? "Type a name, or a Matrix ID like @name:matrix.org. Add several people for a group chat."
                             : "Type a name, or a Matrix ID like @name:matrix.org. Add as many people as you like.")
                    }
                } else {
                    Color.clear
                }
            } else if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if matchesAreAllChosen {
                Color.clear
            } else {
                ContentUnavailableView {
                    Label("Nobody Found", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(searchFailed
                         ? "Your server’s directory can’t be searched right now. Type their full Matrix ID instead."
                         : "Your server only finds people you share a room with. Type their full Matrix ID, like @name:matrix.org.")
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if trimmed.isEmpty {
                            Text("Recent")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 4)
                        }
                        ForEach(people) { person in
                            PersonRow(account: account, person: person, isHighlighted: person.id == highlighted) {
                                add(person)
                            }
                            .id(person.id)
                        }
                        if isSearching {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func move(_ offset: Int, in people: [Person]) -> Bool {
        let people = people.filter { $0.unavailable == nil }
        guard !people.isEmpty else { return false }
        let current = people.firstIndex { $0.id == highlighted } ?? -1
        let next = min(max(current + offset, 0), people.count - 1)
        highlighted = people[next].id
        return true
    }

    /// Asks the server's directory a moment after the last keystroke. A whole Matrix ID is
    /// looked up too, for its name and picture, and to know if nobody has it.
    private func search(_ term: String) async {
        found = []
        searchFailed = false
        typedIDNotFound = false
        guard !term.isEmpty else {
            isSearching = false
            return
        }
        isSearching = true
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        var people: [Person] = []
        do {
            people = try await account.searchPeople(term).map {
                Person(userID: $0.userId, name: ShownName.clean($0.displayName) ?? $0.userId, avatarURL: $0.avatarUrl)
            }
        } catch {
            searchFailed = true
        }
        if let typed = typedUserID, !people.contains(where: { $0.userID == typed }) {
            if let profile = try? await account.profile(of: typed) {
                people.insert(Person(userID: typed, name: ShownName.clean(profile.displayName) ?? typed,
                                     avatarURL: profile.avatarUrl), at: 0)
            } else if await account.userExists(typed) == false {
                // Only the server saying so counts: some refuse to show the profiles of
                // people who share no room, who exist all the same.
                typedIDNotFound = true
            }
        }
        guard !Task.isCancelled else { return }
        found = people
        isSearching = false
    }

    // MARK: Going

    /// One person: the chat with them, made if there isn't one. Several: a new group chat.
    /// Or, when inviting, the invitations.
    private func start() {
        guard !chosen.isEmpty, !isStarting else { return }
        if let inviteRoomID { return invite(to: inviteRoomID) }
        if goesToExisting, let roomID = chosen.count == 1 ? chosen[0].roomID : existingGroupID {
            dismiss()
            account.showRoom(roomID, atNewest: true)
            return
        }
        isStarting = true
        failure = nil
        let people = chosen
        Task {
            defer { isStarting = false }
            if let nobody = await firstNonexistent(people) {
                failure = "Nobody on this server is \(nobody)."
                return
            }
            do {
                let roomID = people.count == 1
                    ? try await account.directChat(with: people[0].userID, encrypted: isEncrypted)
                    : try await account.groupChat(with: people.map(\.userID), name: groupName, encrypted: isEncrypted)
                dismiss()
                account.showRoom(roomID, atNewest: true)
            } catch {
                failure = "Couldn’t start the chat: \(error.actionMessage)"
            }
        }
    }

    /// Invites everyone chosen. Any who couldn't be invited stay in the To field, with why.
    private func invite(to roomID: String) {
        isStarting = true
        failure = nil
        let people = chosen
        Task {
            defer { isStarting = false }
            if let nobody = await firstNonexistent(people) {
                failure = "Nobody on this server is \(nobody)."
                return
            }
            let failures = await account.invite(people.map(\.userID), to: roomID)
            guard let first = failures.first else { return dismiss() }
            let failed = Set(failures.map(\.userID))
            withAnimation(.snappy(duration: 0.15)) { chosen.removeAll { !failed.contains($0.userID) } }
            let name = people.first { $0.userID == first.userID }?.name ?? first.userID
            failure = failures.count == 1
                ? "Couldn’t invite \(name): \(first.error.actionMessage)"
                : "Couldn’t invite \(failures.count) people: \(first.error.actionMessage)"
        }
    }

    /// The first typed Matrix ID that nobody has. Only IDs the search hadn't vouched for are
    /// checked, before inviting them, as some servers accept an invitation to anyone at all.
    private func firstNonexistent(_ people: [Person]) async -> String? {
        for person in people where person.name == person.userID && person.roomID == nil {
            if await account.userExists(person.userID) == false { return person.userID }
        }
        return nil
    }
}

/// Someone in the To field: their picture and name, and a button to take them off.
private struct PersonChip: View {
    let account: AccountSession
    let person: NewMessageSheet.Person
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            AvatarView(media: account.media, url: person.avatarURL, name: person.name, seed: person.userID, size: 16)
                .accessibilityHidden(true)
            Text(person.name)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove \(person.name)")
            .accessibilityLabel("Remove \(person.name)")
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 20)
        .background(Color.accentColor.opacity(0.15), in: Capsule())
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .help(person.userID)
    }
}

/// Someone to message: their picture, name and Matrix ID.
private struct PersonRow: View {
    let account: AccountSession
    let person: NewMessageSheet.Person
    let isHighlighted: Bool
    let add: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: add) {
            HStack(spacing: 10) {
                AvatarView(media: account.media, url: person.avatarURL, name: person.name, seed: person.userID, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .lineLimit(1)
                        .foregroundStyle(person.unavailable == nil ? .primary : .secondary)
                    if let unavailable = person.unavailable {
                        Text(unavailable)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if person.name != person.userID {
                        Text(person.userID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(person.unavailable != nil)
        .onHoverInFrontWindow { isHovering = $0 }
        .help(person.unavailable == nil ? "Add \(person.name)" : "")
        .accessibilityLabel([person.name, person.name == person.userID ? nil : person.userID, person.unavailable]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var background: some ShapeStyle {
        if isHighlighted { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isHovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }
}

/// Lays its views out in rows, left to right, starting a new row when one is full; the
/// last view (the To field's text field) takes what is left of its row.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        let rows = arrange(subviews, in: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for (index, size) in row.items {
                let isLast = index == subviews.count - 1
                let width = isLast ? bounds.maxX - x : size.width
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows = [Row()]
        var x: CGFloat = 0
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row())
                x = 0
            }
            rows[rows.count - 1].items.append((index, size))
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
    }
}
