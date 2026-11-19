import MatrixRustSDK
import SwiftUI

// MARK: - Rail

/// Down the left of the sidebar: every room ("All Rooms"), then the account's spaces, the
/// spaces it has been invited to, and a way to make a new one. Shown only for an account
/// with spaces or an invitation to one; for the rest, the room list has the sidebar to itself.
struct SpaceRail: View {
    let account: AccountSession

    /// Whether the account has anything for the rail to show.
    static func isShown(for account: AccountSession) -> Bool {
        !account.spaces.isEmpty || !account.invitedSpaces.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    RailSpaceButton(account: account, kind: .home)
                    ForEach(account.spaces, id: \.roomId) { space in
                        RailSpaceButton(account: account, kind: .space(space))
                    }
                    ForEach(account.invitedSpaces) { invite in
                        RailSpaceButton(account: account, kind: .invite(invite))
                    }
                }
                .padding(.vertical, 3)
            }
            // At the foot of the rail, as Mac sidebars keep their add buttons: a tile among the
            // spaces looked like one more space.
            NewSpaceButton { account.sheet = .newSpace }
                .padding(.vertical, 4)
        }
        .frame(width: 54)
    }
}

/// A plain plus, with a light background while pointed at.
private struct NewSpaceButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 15))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 30, height: 26)
                .background(Color.primary.opacity(isHovering ? 0.08 : 0),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help("New space")
        .accessibilityLabel("New Space")
    }
}

private struct RailSpaceButton: View {
    let account: AccountSession
    let kind: Kind

    enum Kind {
        case home
        case space(SpaceRoom)
        case invite(RoomSummary)
    }

    /// The corner radius of a space's 34-point square, as `AvatarView` draws it.
    static let corner: CGFloat = 34 * 0.27
    /// The selected space's ring, and the gap between it and the space's square.
    private static let ringWidth: CGFloat = 2.5
    private static let ringGap: CGFloat = 2

    /// An invitation open in the main area is the one selected, whatever the list shows.
    private var isBrowsingInvite: Bool {
        guard let id = account.browsingSpaceID else { return false }
        return account.invitedSpaces.contains { $0.id == id }
    }

    private var isSelected: Bool {
        // Just chosen: shown at once, while the room list and the main area catch up.
        if let choice = account.railChoice {
            switch (kind, choice) {
            case (.home, .home): return true
            case (.space(let space), .space(let id)): return space.roomId == id
            case (.invite(let invite), .invite(let id)): return invite.id == id
            default: return false
            }
        }
        return switch kind {
        case .home: account.selectedSpaceID == nil && !isBrowsingInvite
        case .space(let space): account.selectedSpaceID == space.roomId && !isBrowsingInvite
        case .invite(let invite): account.browsingSpaceID == invite.id
        }
    }

    var body: some View {
        // The selected space has a ring around it, a gap apart, in the text colour: it stands out
        // against a space's picture whatever its colours, as the accent colour would not on one
        // of the same colour. It shows at once, with no animation, while the room list and the
        // conversation are drawn just after.
        icon
            .padding(3)
            .overlay {
                if isSelected {
                    // Out past the 3-point margin around the square.
                    let outset = Self.ringGap + Self.ringWidth - 3
                    RoundedRectangle(cornerRadius: Self.corner + Self.ringGap + Self.ringWidth, style: .continuous)
                        .strokeBorder(.primary, lineWidth: Self.ringWidth)
                        .padding(-outset)
                }
            }
            // After the ring, so a badge on the corner cuts a gap in it too.
            .modifier(Badged(badge: badge, isHome: isHome))
            .contentShape(RoundedRectangle(cornerRadius: Self.corner + 3, style: .continuous))
            .padding(RailBadge.overhang)
            .onTapGesture(perform: select)
            .help(help)
            .contextMenu { menu }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, select)
    }

    @ViewBuilder private var icon: some View {
        switch kind {
        case .home:
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: Self.corner, style: .continuous))
        case .space(let space):
            AvatarView(media: account.media, url: space.avatarUrl, name: space.displayName,
                       seed: space.roomId, size: 34, isSquare: true)
        case .invite(let invite):
            // Faded until joined, and marked by its red dot.
            AvatarView(media: account.media, url: invite.avatarURL, name: invite.name,
                       seed: invite.id, size: 34, isSquare: true)
                .opacity(0.5)
        }
    }

    private var isHome: Bool {
        if case .home = kind { true } else { false }
    }

    /// The badge, for a space or an invitation. All Rooms never has one, and is left out of the
    /// badge's compositing group, which would flatten its tile's sidebar translucency and draw it
    /// darker than the New Space tile below.
    private struct Badged: ViewModifier {
        let badge: RailBadge?
        let isHome: Bool

        func body(content: Content) -> some View {
            if isHome { content } else { content.railBadge(badge) }
        }
    }

    /// As the account's own badge: rooms with notifications, red when any of them needs
    /// attention now; a grey dot when there is only something unread. An invitation has a red dot.
    private var badge: RailBadge? {
        switch kind {
        case .home:
            return nil
        case .invite:
            return .dot(.red, size: 10)
        case .space(let space):
            let state = account.attention(inSpace: space.roomId)
            if let count = RailBadge.count(urgent: state.urgent, other: state.count) { return count }
            return state.hasUnread ? .dot(Color(nsColor: .tertiaryLabelColor)) : nil
        }
    }

    private var help: String {
        switch kind {
        case .home: "All rooms, in every space and none"
        case .space(let space): space.displayName
        case .invite(let invite): "Invitation to \(invite.name)"
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .home: return "All Rooms"
        case .invite(let invite): return "Invitation to \(invite.name)"
        case .space(let space):
            let count = account.attention(inSpace: space.roomId).count
            return count > 0 ? "\(space.displayName), \(count) with new messages" : space.displayName
        }
    }

    private func select() {
        switch kind {
        case .home: account.choose(inRail: .home)
        case .space(let space): account.choose(inRail: .space(space.roomId))
        case .invite(let invite): account.choose(inRail: .invite(invite.id))
        }
    }

    @ViewBuilder private var menu: some View {
        switch kind {
        case .home:
            Button("Mark All as Read") { account.markAllRead() }
                .disabled(!account.hasUnreadRooms)
        case .space(let space):
            Button("Browse Rooms") { account.browse(space: space.roomId) }
            if account.editableSpaceIDs.contains(space.roomId) {
                Button("New Room…") { account.sheet = .newRoom(inSpace: space.roomId) }
                Button("Add Existing Rooms…") { account.sheet = .addRooms(toSpace: space.roomId) }
            }
            // Yours alone, so whoever may change the space.
            Button("New Section…") { account.askForNewSection(inSpace: space.roomId) }
            Divider()
            Button("Mark All as Read") { account.markAllRead(inSpace: space.roomId) }
                .disabled(!account.hasUnreadRooms(inSpace: space.roomId))
            Divider()
            Button("Leave Space…") { account.sheet = .leaveSpace(space.roomId) }
        case .invite(let invite):
            Button("Accept Invitation") { FailureAlert.run("Couldn’t Join the Space") { try await account.acceptSpaceInvite(invite.id) } }
            Button("Decline Invitation") { FailureAlert.run("Couldn’t Decline the Invitation") { try await account.declineSpaceInvite(invite.id) } }
        }
    }
}

// MARK: - Room list header

/// Above the room list while it is narrowed to a space: whose rooms these are, a way to
/// browse all of them (joined or not), and what can be done in it.
struct SpaceListHeader: View {
    let account: AccountSession
    let spaceID: String
    @State private var isHovering = false

    private var space: SpaceRoom? { account.spaces.first { $0.roomId == spaceID } }
    private var isBrowsing: Bool { account.browsingSpaceID == spaceID }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                account.browse(space: spaceID)
            } label: {
                HStack(spacing: 8) {
                    AvatarView(media: account.media, url: space?.avatarUrl, name: account.spaceName(spaceID),
                               seed: spaceID, size: 22, isSquare: true)
                    Text(account.spaceName(spaceID))
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isBrowsing ? AnyShapeStyle(.quaternary) : AnyShapeStyle(isHovering ? Color.primary.opacity(0.05) : .clear))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHoverInFrontWindow { isHovering = $0 }
            .help("Browse every room in this space")
            .accessibilityHint("Shows every room in this space, including ones you haven’t joined")
            Menu {
                Button("Browse Rooms") { account.browse(space: spaceID) }
                if account.editableSpaceIDs.contains(spaceID) {
                    Button("New Room…") { account.sheet = .newRoom(inSpace: spaceID) }
                    Button("Add Existing Rooms…") { account.sheet = .addRooms(toSpace: spaceID) }
                }
                // Yours alone, so whoever may change the space.
                Button("New Section…") { account.askForNewSection(inSpace: spaceID) }
                Divider()
                Button("Mark All as Read") { account.markAllRead(inSpace: spaceID) }
                    .disabled(!account.hasUnreadRooms(inSpace: spaceID))
                Divider()
                Button("Leave Space…") { account.sheet = .leaveSpace(spaceID) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More for this space")
            .accessibilityLabel("More for \(account.spaceName(spaceID))")
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - Browsing a space

/// One level of a space's hierarchy as the server describes it: its rooms and the spaces
/// within it, joined or not.
@MainActor @Observable
final class SpaceDirectory {
    let spaceID: String
    private(set) var space: SpaceRoom?
    private(set) var rooms: [SpaceRoom] = []
    private(set) var isLoading = true
    private(set) var hasMore = true
    private(set) var error: String?

    @ObservationIgnored private var list: SpaceRoomList?
    @ObservationIgnored private var handles: [TaskHandle] = []
    @ObservationIgnored private let service: SpaceService?

    init(account: AccountSession, spaceID: String) {
        self.spaceID = spaceID
        service = account.spaceService
        Task { await load() }
    }

    /// Fetches the first page of the space's rooms and only then shows them, so loading
    /// again (after rooms are added, say) swaps the list in place instead of emptying it.
    private func load() async {
        guard let service else {
            isLoading = false
            return
        }
        do {
            let list = try await service.spaceRoomList(spaceId: spaceID)
            try await list.paginate()
            handles.forEach { $0.cancel() }
            handles = []
            self.list = list
            space = list.space() ?? space
            error = nil
            // Starts with everything loaded so far, then follows changes.
            handles.append(await list.subscribeToRoomUpdate(listener: SpaceRoomsListener { [weak self] updates in
                Task { @MainActor in
                    guard let self else { return }
                    var rooms = self.rooms
                    for update in updates { rooms.apply(update.diff) }
                    self.rooms = rooms
                }
            }))
            handles.append(list.subscribeToPaginationStateUpdates(listener: SpacePaginationListener { [weak self] state in
                Task { @MainActor in self?.paginationChanged(to: state) }
            }))
            paginationChanged(to: list.paginationState())
        } catch {
            if rooms.isEmpty { self.error = error.actionMessage }
            isLoading = false
        }
    }

    private func paginationChanged(to state: SpaceRoomListPaginationState) {
        switch state {
        case .loading:
            isLoading = true
        case .idle(let endReached):
            isLoading = false
            hasMore = !endReached
        }
    }

    func loadMore() async {
        guard hasMore, !isLoading, let list else { return }
        try? await list.paginate()
    }

    /// Asks the server again, to pick up rooms added or removed here.
    func reload() async {
        await load()
    }

    func stop() {
        handles.forEach { $0.cancel() }
        handles = []
    }
}

/// The main area while browsing a space: what the space is, and every room and space in it,
/// with a way into each. Spaces within it open in place, with a path back.
struct SpaceBrowserView: View {
    let account: AccountSession
    let spaceID: String
    /// The spaces opened within this one, innermost last.
    @State private var path: [String] = []

    private var currentID: String { path.last ?? spaceID }

    var body: some View {
        VStack(spacing: 0) {
            if !path.isEmpty { breadcrumb }
            SpaceLevelView(account: account, spaceID: currentID, isTopLevel: path.isEmpty) { inner in
                withAnimation(.snappy(duration: 0.25)) { path.append(inner) }
            }
            .id(currentID)
            .transition(.opacity)
        }
        .navigationTitle(account.spaceName(spaceID))
    }

    /// "Work › Mobile", each part a way back to it.
    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { _ = path.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back")
            ForEach(Array(([spaceID] + path).enumerated()), id: \.offset) { index, id in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                Button(account.spaceName(id)) {
                    withAnimation(.snappy(duration: 0.25)) { path = Array(path.prefix(index)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(index == path.count ? .primary : .secondary)
                .fontWeight(index == path.count ? .semibold : .regular)
                .disabled(index == path.count)
            }
            Spacer()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
    }
}

/// One space's page: its header, and the rooms and spaces in it.
private struct SpaceLevelView: View {
    let account: AccountSession
    let spaceID: String
    let isTopLevel: Bool
    let openSpace: (String) -> Void
    @State private var directory: SpaceDirectory?
    @State private var joining: Set<String> = []
    @State private var failure: String?
    @State private var inviter: Inviter?

    private struct Inviter {
        let userID: String
        let name: String
        let avatarURL: String?
    }

    private var invite: RoomSummary? {
        account.allRooms.first { $0.id == spaceID && $0.isInvite }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 18)
                Divider().padding(.horizontal, 24)
                if let directory { contents(directory) }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if directory == nil { directory = SpaceDirectory(account: account, spaceID: spaceID) }
        }
        .task(id: invite?.id) {
            guard invite != nil, let member = try? await account.room(id: spaceID)?.inviter() else { return }
            inviter = Inviter(userID: member.userId, name: member.displayName ?? member.userId,
                              avatarURL: member.avatarUrl)
        }
        .onDisappear {
            directory?.stop()
            directory = nil
        }
        // Rooms joined, added or taken out, here or on another device.
        .onChange(of: account.roomIDs(inSpace: spaceID)) {
            Task { await directory?.reload() }
        }
    }

    // MARK: Header

    private var header: some View {
        let space = directory?.space
        let name = space?.displayName ?? account.spaceName(spaceID)
        return HStack(alignment: .top, spacing: 16) {
            AvatarView(media: account.media, url: space?.avatarUrl ?? invite?.avatarURL, name: name,
                       seed: spaceID, size: 64, isSquare: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(name)
                    .font(.title2.weight(.semibold))
                    .textSelection(.enabled)
                if let topic = space?.topic, !topic.isEmpty {
                    Text(topic)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let inviter, invite != nil {
                    HStack(spacing: 6) {
                        AvatarView(media: account.media, url: inviter.avatarURL, name: inviter.name,
                                   seed: inviter.userID, size: 18)
                        Text("\(Text(inviter.name).fontWeight(.semibold)) invited you")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help(inviter.userID)
                } else if let space, let summary = summary(of: space) {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                actions
                    .padding(.top, 6)
                if let failure {
                    Text(failure)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var actions: some View {
        if invite != nil {
            HStack(spacing: 8) {
                Button("Accept Invitation") {
                    act {
                        try await account.acceptSpaceInvite(spaceID)
                        await directory?.reload()
                    }
                }
                .buttonStyle(.borderedProminent)
                Button("Decline") { act { try await account.declineSpaceInvite(spaceID) } }
            }
        } else if directory?.space?.state != .joined, !isTopLevel, let space = directory?.space {
            Button("Join Space") { join(space) }
                .buttonStyle(.borderedProminent)
                .disabled(joining.contains(space.roomId))
        } else {
            HStack(spacing: 8) {
                if account.editableSpaceIDs.contains(spaceID) {
                    Button("New Room…") { account.sheet = .newRoom(inSpace: spaceID) }
                    Button("Add Existing Rooms…") { account.sheet = .addRooms(toSpace: spaceID) }
                }
                if isTopLevel {
                    Button("Leave Space…") { account.sheet = .leaveSpace(spaceID) }
                }
            }
        }
    }

    /// "3 members · 4 rooms · Public", leaving out what isn't known (as for a space only
    /// invited to, whose members the server doesn't share).
    private func summary(of space: SpaceRoom) -> String? {
        var parts: [String] = []
        let members = space.numJoinedMembers
        if members > 0 { parts.append(members == 1 ? "1 member" : "\(members) members") }
        // Counted from the list once it is all here: the space's own count can include rooms
        // since taken out of it.
        let loaded = directory?.rooms.filter { $0.roomId != spaceID }.count ?? 0
        let rooms = directory?.hasMore == false ? loaded : max(Int(space.childrenCount), loaded)
        if rooms > 0 { parts.append(rooms == 1 ? "1 room" : "\(rooms) rooms") }
        if space.joinRule == .public { parts.append("Public") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: Contents

    @ViewBuilder private func contents(_ directory: SpaceDirectory) -> some View {
        let rooms = directory.rooms.filter { $0.roomId != spaceID }
        if rooms.isEmpty {
            if directory.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(40)
            } else if let error = directory.error {
                ContentUnavailableView("Can’t Show This Space", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
                    .padding(.top, 30)
            } else {
                ContentUnavailableView("No Rooms Yet", systemImage: "square.stack",
                                       description: Text(account.editableSpaceIDs.contains(spaceID)
                                                         ? "Create a room here, or add rooms you’re already in."
                                                         : "Nobody has added a room to this space yet."))
                    .padding(.top, 30)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rooms, id: \.roomId) { room in
                    SpaceRoomRow(account: account, room: room, isJoining: joining.contains(room.roomId),
                                 isPreview: invite != nil, open: { open(room) }, join: { join(room) })
                        .onAppear {
                            if room.roomId == rooms.last?.roomId { Task { await directory.loadMore() } }
                        }
                    Divider().padding(.leading, 76).padding(.trailing, 24)
                }
                if directory.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                }
            }
            .padding(.top, 6)
        }
    }

    private func open(_ room: SpaceRoom) {
        if room.roomType == .space {
            openSpace(room.roomId)
        } else if room.state == .joined {
            account.selectedRoomID = room.roomId
        }
    }

    private func join(_ room: SpaceRoom) {
        joining.insert(room.roomId)
        failure = nil
        Task {
            defer { joining.remove(room.roomId) }
            do {
                try await account.join(roomID: room.roomId, via: room.via)
                if room.roomId == spaceID {
                    await directory?.reload()
                } else if room.roomType != .space {
                    account.selectedRoomID = room.roomId
                }
            } catch {
                failure = "Couldn’t join \(room.displayName): \(error.actionMessage)"
            }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        failure = nil
        Task {
            do { try await work() } catch { failure = error.actionMessage }
        }
    }
}

/// A room or space in a space: what it is, how many are in it, and joining or going into it.
private struct SpaceRoomRow: View {
    let account: AccountSession
    let room: SpaceRoom
    let isJoining: Bool
    /// In a space only invited to: shown, but not to be joined or opened until it is accepted.
    let isPreview: Bool
    let open: () -> Void
    let join: () -> Void
    @State private var isHovering = false

    private var isSpace: Bool { room.roomType == .space }
    private var isJoined: Bool { room.state == .joined }
    private var opens: Bool { !isPreview && (isJoined || isSpace) }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            AvatarView(media: account.media, url: room.avatarUrl, name: room.displayName,
                       seed: room.roomId, size: 38, isSquare: isSpace)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(room.displayName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if isSpace {
                        Text("Space")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                if let topic = room.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 12)
            if !isPreview { trailing }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isHovering && opens ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture { if opens { open() } }
        .onHoverInFrontWindow { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPreview ? [] : .isButton)
        .accessibilityAction(.default) {
            if opens { open() } else if !isPreview, !isJoined { join() }
        }
        .accessibilityActions {
            if !isPreview, !isJoined, !isJoining {
                Button(room.state == .invited ? "Accept" : "Join", action: join)
            }
        }
    }

    private var details: String {
        var parts: [String] = []
        if room.numJoinedMembers > 0 {
            parts.append(room.numJoinedMembers == 1 ? "1 member" : "\(room.numJoinedMembers) members")
        }
        if isSpace, room.childrenCount > 0 {
            parts.append(room.childrenCount == 1 ? "1 room" : "\(room.childrenCount) rooms")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if isJoining {
            ProgressView().controlSize(.small)
        } else if isJoined {
            if isSpace {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Joined")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if room.state == .invited {
            Button("Accept", action: join)
        } else {
            HStack(spacing: 10) {
                Button("Join", action: join)
                if isSpace {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
