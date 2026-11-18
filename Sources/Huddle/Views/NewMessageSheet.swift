import MatrixRustSDK
import SwiftUI

/// Starting a direct chat: find someone by name or Matrix ID, and go to the chat with them,
/// made for the occasion if there isn't one yet. With nothing typed, the people already
/// chatted with come first.
struct NewMessageSheet: View {
    let account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var found: [Person] = []
    @State private var isSearching = false
    @State private var searchFailed = false
    /// The row Return opens, moved with the arrow keys.
    @State private var highlighted: String?
    @State private var starting: String?
    @State private var failure: String?
    @FocusState private var fieldIsFocused: Bool

    /// Someone to message, and the chat already had with them, if any.
    struct Person: Identifiable, Equatable {
        var id: String { userID }
        let userID: String
        let name: String
        let avatarURL: String?
        var roomID: String?
        /// A typed Matrix ID the server says nobody has. Shown, so it's clear why, but not
        /// to be messaged: some servers accept an invitation to anyone at all.
        var doesNotExist = false
    }

    /// For a typed Matrix ID: true once the server has said nobody has it.
    @State private var typedIDNotFound = false

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// People with a direct chat already, most recent first.
    private var recent: [Person] {
        var seen = Set<String>()
        return account.allRooms.compactMap { room -> Person? in
            guard room.isDirect, !room.isInvite, let userID = room.directUserID,
                  seen.insert(userID).inserted else { return nil }
            return Person(userID: userID, name: room.name, avatarURL: room.avatarURL, roomID: room.id)
        }
    }

    /// What the list shows: those already chatted with who match, then the server's
    /// matches, then (for a full Matrix ID nobody else matched) that ID itself.
    private var people: [Person] {
        guard !trimmed.isEmpty else { return Array(recent.prefix(30)) }
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
            result.append(Person(userID: typed, name: typed, avatarURL: nil, doesNotExist: typedIDNotFound))
        }
        return result
    }

    /// The query, when it is a whole Matrix ID ("@name:server.org").
    private var typedUserID: String? {
        guard trimmed.hasPrefix("@"), trimmed.contains(":"), !trimmed.contains(where: \.isWhitespace),
              trimmed != account.userID else { return nil }
        return trimmed
    }

    var body: some View {
        let people = people
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text("New Message")
                    .font(.headline)
                SearchField(text: $query, prompt: "Name or Matrix ID")
                    .focused($fieldIsFocused)
                    .onSubmit { if let person = people.first(where: { $0.id == highlighted }) ?? people.first { start(person) } }
                    .onKeyPress(.downArrow) { move(1, in: people) }
                    .onKeyPress(.upArrow) { move(-1, in: people) }
            }
            .padding(16)
            Divider()
            list(people)
                .frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(failure)
                }
                Spacer(minLength: 8)
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 440, height: 520)
        .onAppear {
            fieldIsFocused = true
            highlighted = people.first?.id
        }
        .task(id: trimmed) { await search(trimmed) }
        .onChange(of: people.first?.id) { _, first in
            if !people.contains(where: { $0.id == highlighted }) { highlighted = first }
        }
    }

    @ViewBuilder private func list(_ people: [Person]) -> some View {
        if people.isEmpty {
            if trimmed.isEmpty {
                ContentUnavailableView {
                    Label("Message Someone", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Type a name, or a Matrix ID like @name:matrix.org.")
                }
            } else if isSearching {
                ProgressView()
                    .controlSize(.small)
            } else {
                ContentUnavailableView {
                    Label("Nobody Found", systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(searchFailed
                         ? "Your server's directory can't be searched right now. Type their full Matrix ID instead."
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
                            PersonRow(account: account, person: person, isHighlighted: person.id == highlighted,
                                      isStarting: starting == person.userID) {
                                start(person)
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

    private func move(_ offset: Int, in people: [Person]) -> KeyPress.Result {
        guard !people.isEmpty else { return .ignored }
        let current = people.firstIndex { $0.id == highlighted } ?? -1
        let next = min(max(current + offset, 0), people.count - 1)
        highlighted = people[next].id
        return .handled
    }

    /// Asks the server's directory a moment after the last keystroke. A whole Matrix ID is
    /// looked up too, for its name and picture.
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
                Person(userID: $0.userId, name: $0.displayName ?? $0.userId, avatarURL: $0.avatarUrl)
            }
        } catch {
            searchFailed = true
        }
        if let typed = typedUserID, !people.contains(where: { $0.userID == typed }) {
            if let profile = try? await account.profile(of: typed) {
                people.insert(Person(userID: typed, name: profile.displayName ?? typed, avatarURL: profile.avatarUrl), at: 0)
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

    private func start(_ person: Person) {
        guard starting == nil, !person.doesNotExist else { return }
        if let roomID = person.roomID {
            dismiss()
            account.showRoom(roomID)
            return
        }
        starting = person.userID
        failure = nil
        Task {
            defer { starting = nil }
            // A typed ID the search hasn't vouched for yet: check it's someone's before
            // inviting them, as some servers accept an invitation to anyone at all.
            if !found.contains(where: { $0.userID == person.userID }), recent.allSatisfy({ $0.userID != person.userID }),
               await account.userExists(person.userID) == false {
                typedIDNotFound = true
                return
            }
            do {
                let roomID = try await account.directChat(with: person.userID)
                dismiss()
                account.showRoom(roomID)
            } catch {
                failure = "Couldn't start a chat with \(person.name): \(error.actionMessage)"
            }
        }
    }
}

/// Someone to message: their picture, name and Matrix ID.
private struct PersonRow: View {
    let account: AccountSession
    let person: NewMessageSheet.Person
    let isHighlighted: Bool
    let isStarting: Bool
    let open: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AvatarView(media: account.media, url: person.avatarURL, name: person.name, seed: person.userID, size: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(person.name)
                        .lineLimit(1)
                        .foregroundStyle(person.doesNotExist ? .secondary : .primary)
                    if person.doesNotExist {
                        Text("Nobody on this server has this Matrix ID")
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
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(person.doesNotExist)
        .onHover { isHovering = $0 }
        .help(person.doesNotExist ? "" : person.roomID == nil ? "Start a chat with \(person.name)" : "Go to your chat with \(person.name)")
        .accessibilityLabel(person.name == person.userID ? person.name : "\(person.name), \(person.userID)")
    }

    private var background: some ShapeStyle {
        if isHighlighted { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isHovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }
}
