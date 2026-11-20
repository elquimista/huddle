import SwiftUI
import Perception

/// Go ▸ Go to Room… (⌘K): any room by name, from any account and space. Before anything is
/// typed, the rooms visited lately. The arrow keys choose, Return goes there; Escape, or a
/// click elsewhere, puts it away.
struct GoToRoomPanel: View {
    @Environment(AccountStore.self) private var store
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private static let mostShown = 8

    struct Match: Identifiable {
        let account: AccountSession
        let room: RoomSummary
        var id: String { "\(account.id)|\(room.id)" }
    }

    var body: some View { WithPerceptionTracking {
        let matches = self.matches
        ZStack(alignment: .top) {
            // Anywhere else in the window: put it away.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                    TextField("Go to room", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .focused($isFocused)
                        .onSubmit { open(matches, at: selection) }
                        .onKeyDown(.downArrow, focused: isFocused) { _ in move(1, in: matches) }
                        .onKeyDown(.upArrow, focused: isFocused) { _ in move(-1, in: matches) }
                        .onExitCommand { close() }
                        .accessibilityLabel("Go to room")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                if !matches.isEmpty {
                    Divider()
                    VStack(spacing: 1) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, match in WithPerceptionTracking {
                            GoToRoomRow(match: match, isSelected: index == selection,
                                        showsAccount: store.accounts.count > 1)
                                .contentShape(Rectangle())
                                .onTapGesture { open(matches, at: index) }
                        } }
                    }
                    .padding(6)
                } else if !query.isEmpty {
                    Divider()
                    Text("No Rooms")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
            }
            .frame(width: 480)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator) }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(.top, 72)
        }
        .onAppear { DispatchQueue.main.async { isFocused = true } }
        .onChanged(of: query) { selection = 0 }
    } }

    /// Before anything is typed, the rooms visited lately (not the one showing); after, those
    /// whose name starts with it, then those with a word that does, then any that have it.
    private var matches: [Match] {
        var all: [Match] = []
        for account in store.accounts {
            for room in account.allRooms where !room.isSpace && !room.isInvite {
                all.append(Match(account: account, room: room))
            }
        }
        // Visited lately first, then the rooms most recently active.
        let recent = RoomHistory.shared.recent
        let order = Dictionary(recent.enumerated().map { ("\($1.accountID)|\($1.roomID)", $0) },
                               uniquingKeysWith: { first, _ in first })
        func byRecency(_ a: Match, _ b: Match) -> Bool {
            switch (order[a.id], order[b.id]) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return (a.room.timestamp ?? .distantPast) > (b.room.timestamp ?? .distantPast)
            }
        }
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else {
            let showing = store.selected.flatMap { account in account.selectedRoomID.map { "\(account.id)|\($0)" } }
            return Array(all.filter { $0.id != showing }.sorted(by: byRecency).prefix(Self.mostShown))
        }
        func rank(_ match: Match) -> Int? {
            let name = match.room.name.lowercased()
            if name.hasPrefix(text) { return 0 }
            if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(text) }) { return 1 }
            if name.contains(text) { return 2 }
            if let person = match.room.directUserID?.lowercased(), person.contains(text) { return 3 }
            return nil
        }
        let ranked = all.compactMap { match in rank(match).map { (match, $0) } }
        return Array(ranked.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : byRecency($0.0, $1.0) }.map(\.0).prefix(Self.mostShown))
    }

    private func move(_ step: Int, in matches: [Match]) -> KeyResult {
        guard !matches.isEmpty else { return .handled }
        selection = (selection + step + matches.count) % matches.count
        return .handled
    }

    private func open(_ matches: [Match], at index: Int) {
        guard matches.indices.contains(index) else { return }
        let match = matches[index]
        close()
        match.account.wantsComposerFocus = true
        Notifier.shared.show(accountID: match.account.id, roomID: match.room.id, thread: nil)
    }

    private func close() {
        store.isGoingToRoom = false
    }
}

/// A room in Go to Room's list: its picture and name, whether it has anything new, and its
/// account where there are several.
private struct GoToRoomRow: View {
    let match: GoToRoomPanel.Match
    let isSelected: Bool
    let showsAccount: Bool

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            AvatarView(media: match.account.media, url: match.room.avatarURL, name: match.room.name,
                       seed: match.room.avatarSeed, size: 24)
            Text(match.room.name)
                .lineLimit(1)
            if AccountSession.isUnread(match.room) {
                Circle()
                    .fill(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(Color.accentColor))
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Unread")
            }
            Spacer(minLength: 8)
            if showsAccount {
                Text(match.account.displayName ?? match.account.userID)
                    .font(.callout)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    } }
}
