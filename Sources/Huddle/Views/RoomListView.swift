import MatrixRustSDK
import SwiftUI
import Perception

struct RoomListView: View {
    @Perception.Bindable var account: AccountSession
    /// Naming a new section, and the room to put in it, if it was made for one.
    @State private var newSection: NewSection?
    @State private var sectionName = ""
    @State private var renaming: RoomSection?
    @State private var deleting: RoomSection?
    @State private var failure: Failure?
    /// The row the pointer is on, which shows a wash.
    @State private var hover = RoomListHover()

    private struct NewSection {
        var roomID: String?
    }

    private struct Failure {
        let title: String
        let message: String
    }

    var body: some View { WithPerceptionTracking {
        dialogs(on: list)
    } }

    private var list: some View {
        ScrollViewReader { proxy in WithPerceptionTracking {
            List(selection: $account.selectedRoomID) { WithPerceptionTracking {
                ForEach(account.sections) { section in WithPerceptionTracking {
                    RoomListSection(account: account, section: section, actions: actions)
                } }
            } }
            // A room chosen some other way (Next Room, a notification) is brought into view. One
            // chosen from a search's Elsewhere takes the list to the space it's in (or Home).
            .onChanged(of: account.selectedRoomID) { _, roomID in
                guard let roomID else { return }
                if !account.searchText.isEmpty { account.showInList(roomID) }
                proxy.scrollTo(roomID)
            }
            .environment(\.roomListHover, hover)
            .background(RoomListPointerArea(hover: hover))
            // Rooms changing places under a still pointer: the wash goes to the row now there.
            .onChanged(of: account.sections.flatMap { $0.rooms.map(\.id) }) { hover.rowsMoved() }
        } }
        .listStyle(.sidebar)
        .searchable(text: $account.searchText, placement: .sidebar, prompt: "Search rooms")
        .overlay {
            if account.sections.isEmpty {
                if !account.searchText.isEmpty {
                    SearchEmptyState(text: account.searchText)
                } else if let space = account.selectedSpaceID, account.hasLoadedRooms {
                    SpaceEmptyList(account: account, spaceID: space)
                } else if account.hasLoadedRooms {
                    EmptyState("No Rooms Yet",
                                           systemImage: "tray",
                                           description: Text("Invitations and rooms you join will appear here."))
                } else if account.syncState == .running || account.syncState == .idle {
                    ProgressView()
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let space = account.selectedSpaceID {
                SpaceListHeader(account: account, spaceID: space)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                let verification = account.verificationFlow
                if verification.step == .incoming, !verification.isShown, let request = verification.requestSummary {
                    // A request that came in while something else was open.
                    Banner(icon: "checkmark.shield", text: request, action: "Review") { account.sheet = .verify }
                } else if account.verification == .unverified {
                    Banner(icon: "lock.trianglebadge.exclamationmark",
                           text: "This Mac isn’t verified",
                           action: "Verify") { account.sheet = .verify }
                } else if account.suggestsRecoveryKey, !account.recoveryNudgeDismissed {
                    Banner(icon: "key.horizontal",
                           text: "No recovery key yet",
                           action: "Set Up",
                           dismiss: { account.recoveryNudgeDismissed = true }) { account.sheet = .recoveryKey }
                }
                if let status {
                    Banner(icon: "exclamationmark.triangle", text: status, action: nil) {}
                }
                // Calls going on, whichever account's and wherever you are.
                ForEach(CallCenter.shared.calls, id: \.identity) { call in WithPerceptionTracking {
                    CallStrip(call: call)
                } }
            }
        }
        .navigationTitle(account.displayName ?? account.userID)
        .onChanged(of: account.asksForNewSection) { _, asks in
            guard asks else { return }
            account.asksForNewSection = false
            actions.newSection(nil)
        }
    }

    /// Naming, renaming and deleting sections, and what went wrong changing anything.
    private func dialogs(on content: some View) -> some View {
        content
            .alert("New Section", isPresented: Binding(get: { newSection != nil }, set: { if !$0 { newSection = nil } })) { WithPerceptionTracking {
                TextField("Name", text: $sectionName)
                Button("Create") { createSection() }
                    .disabled(sectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } } message: {
                Text(newSection?.roomID == nil ? "Name the section. Put rooms in it from their Move To menu, or drag them there."
                     : "Name the section. The room goes in it.")
            }
            .alert("Rename Section", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                   presenting: renaming) { section in WithPerceptionTracking {
                TextField("Name", text: $sectionName)
                Button("Rename") { run { try await account.renameSection(section.id, to: sectionName) } }
                    .disabled(sectionName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } }
            .confirmationDialog("Delete the “\(deleting?.title ?? "")” section?",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                                presenting: deleting) { section in WithPerceptionTracking {
                Button("Delete Section", role: .destructive) { run { try await account.deleteSection(section.id) } }
            } } message: { _ in
                Text("Its rooms go back to People and Rooms.")
            }
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in WithPerceptionTracking {
                Button("OK") {}
            } } message: { failure in
                Text(failure.message)
            }
    }

    /// What the sections and their rooms ask the list to do.
    private var actions: RoomListSection.Actions {
        .init(move: { roomID, place in run { try await account.move(roomID, to: place) } },
              newSection: { roomID in
                  sectionName = ""
                  newSection = NewSection(roomID: roomID)
              },
              rename: { section in
                  sectionName = section.title
                  renaming = section
              },
              moveSection: { section, offset in
                  guard let orderTag = section.orderTag else { return }
                  run { try await account.moveSection(orderTag, by: offset) }
              },
              delete: { deleting = $0 },
              setNotifications: { roomID, mode in
                  run(failing: "Couldn’t Change Notifications") { try await account.setNotificationMode(mode, for: roomID) }
              })
    }

    private func createSection() {
        let name = sectionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomID = newSection?.roomID
        guard !name.isEmpty else { return }
        run {
            let id = try await account.createSection(named: name)
            if let roomID { try await account.move(roomID, to: .custom(id)) }
        }
    }

    private func run(failing title: String = "Couldn’t Change the Sections", _ work: @escaping () async throws -> Void) {
        Task {
            do { try await work() } catch { failure = Failure(title: title, message: error.actionMessage) }
        }
    }

    private var status: String? {
        if account.needsReauth { return "Session expired. Sign out and back in." }
        if let error = account.startError { return error }
        switch account.syncState {
        case .offline: return "Offline. Reconnecting…"
        case .error, .terminated: return "Connection lost. Reconnecting…"
        default: return nil
        }
    }
}

/// One section of the room list: a header that folds it away (with a badge for what needs
/// attention while folded) and its rooms. Rooms can be dragged onto a section, or onto the
/// rooms in it, to put them there.
private struct RoomListSection: View {
    struct Actions {
        let move: (String, SectionPlace) -> Void
        /// For a room (to put in it) or none.
        let newSection: (String?) -> Void
        let rename: (RoomSection) -> Void
        let moveSection: (RoomSection, Int) -> Void
        let delete: (RoomSection) -> Void
        /// A room's own notification setting, or nil for the default.
        let setNotifications: (String, RoomNotificationMode?) -> Void
    }

    let account: AccountSession
    let section: RoomSection
    let actions: Actions

    /// Where a room dropped here goes; nil for invitations and Elsewhere, and for a room whose
    /// usual section this isn't (a direct chat dropped on Rooms).
    private func place(for room: RoomSummary) -> SectionPlace? {
        switch section.kind {
        case .invites, .elsewhere: nil
        case .favourites: .favourites
        case .custom: .custom(section.id)
        case .lowPriority: .lowPriority
        case .people: room.isDirect ? .usual : nil
        case .rooms: room.isDirect ? nil : .usual
        }
    }

    private var isExpanded: Binding<Bool> {
        Binding(get: { !account.searchText.isEmpty || !account.collapsedSections.contains(section.id) },
                set: { expanded in
                    // Its rooms slide in and out, as a Finder sidebar's do.
                    withAnimation(.snappy(duration: 0.25)) {
                        if expanded { account.collapsedSections.remove(section.id) } else { account.collapsedSections.insert(section.id) }
                    }
                })
    }

    var body: some View { WithPerceptionTracking {
        FoldingSection(isExpanded: isExpanded) {
            ForEach(section.rooms) { room in WithPerceptionTracking {
                RoomListRow(account: account, room: room, actions: actions)
            } }
            .dropDestination(for: String.self) { roomIDs, _ in drop(roomIDs) }
            if section.rooms.isEmpty {
                Text("Drag rooms here, or use a room’s Move To menu.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
                    .dropDestination(for: String.self) { roomIDs, _ in drop(roomIDs) }
            }
        } header: {
            header
        }
    } }

    private var header: some View {
        HStack(spacing: 6) {
            Text(section.title)
            Spacer(minLength: 4)
            if !isExpanded.wrappedValue {
                // Lined up with the rooms' badges, clear of the show/hide button on hover.
                Group {
                    let attention = section.attention
                    if attention.count > 0 {
                        Text("\(min(attention.count, 99))")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 16, minHeight: 15)
                            .background(attention.urgent ? Color.red : Color.accentColor, in: Capsule())
                            .accessibilityLabel("\(attention.count) with notifications")
                    } else if attention.hasUnread {
                        Circle()
                            .fill(attention.markedUnread ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("Unread")
                    }
                }
                .frame(minWidth: 20)
                .padding(.trailing, 14)
            }
        }
        .contentShape(Rectangle())
        .background(SectionHeaderKeeper())
        .dropDestination(for: String.self) { roomIDs, _ in drop(roomIDs) }
        .contextMenu { WithPerceptionTracking { headerMenu } }
        .accessibilityElement(children: .combine)
        .accessibilityActions { headerMenu }
    }

    @ViewBuilder private var headerMenu: some View {
        if let orderTag = section.orderTag {
            if section.kind == .custom {
                Button("Rename…") { actions.rename(section) }
            }
            Button("Move Up") { actions.moveSection(section, -1) }
                .disabled(!account.canMoveSection(orderTag, by: -1))
            Button("Move Down") { actions.moveSection(section, 1) }
                .disabled(!account.canMoveSection(orderTag, by: 1))
            Divider()
        }
        if section.kind != .invites && section.kind != .elsewhere {
            Button("Mark All as Read") { account.markAllRead(in: section) }
                .disabled(!section.rooms.contains(where: AccountSession.isUnread))
            Divider()
            Button("New Section…") { actions.newSection(nil) }
        }
        if section.kind == .custom {
            Button("Delete Section…", role: .destructive) { actions.delete(section) }
        }
    }

    /// Puts dropped rooms in this section. Only rooms of this account count.
    private func drop(_ roomIDs: [String]) -> Bool {
        var moved = false
        for roomID in roomIDs {
            guard let room = account.allRooms.first(where: { $0.id == roomID }), !room.isInvite,
                  let place = place(for: room), account.place(of: room) != place else { continue }
            actions.move(roomID, place)
            moved = true
        }
        return moved
    }
}

/// Keeps each section header the sidebar shows alive a while after its section goes.
///
/// AppKit's sidebar remembers which section header the pointer is on, for its Show/Hide button,
/// without holding on to it. SwiftUI lets a section's header go as soon as the section leaves the
/// list, so a section that goes while the pointer rests on its header (the last invitation
/// answered, a search narrowing the list, a space switched to) leaves the sidebar remembering
/// something that no longer exists, and the app crashes the next time the sidebar looks at it.
/// Kept alive, the header is simply no longer in the list when the sidebar next looks, and it
/// forgets it. Only headers that have been on screen can be under the pointer, so those are the
/// ones kept: the last few dozen, far more than come and go before the sidebar next looks.
private struct SectionHeaderKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }

    func updateNSView(_ marker: Marker, context: Context) {
        marker.keepHeaderSoon()
    }

    final class Marker: NSView {
        private static var kept: [AnyObject] = []
        private static let keptAtMost = 64

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { keepHeaderSoon() }
        }

        /// Once the sidebar has put the header's row in place.
        func keepHeaderSoon() {
            DispatchQueue.main.async { [weak self] in self?.keepHeader() }
        }

        private func keepHeader() {
            var view = superview
            while let current = view, !(current is NSOutlineView) { view = current.superview }
            guard let sidebar = view as? NSOutlineView else { return }
            let row = sidebar.row(for: self)
            guard row >= 0, let header = sidebar.item(atRow: row) else { return }
            let object = header as AnyObject
            guard !Self.kept.contains(where: { $0 === object }) else { return }
            Self.kept.append(object)
            if Self.kept.count > Self.keptAtMost { Self.kept.removeFirst(Self.kept.count - Self.keptAtMost) }
        }
    }
}

/// A room in the list, with its menu: read state, where it's kept, and its space.
private struct RoomListRow: View {
    let account: AccountSession
    let room: RoomSummary
    let actions: RoomListSection.Actions
    @Environment(\.roomListHover) private var hover

    var body: some View { WithPerceptionTracking {
        let isSelected = account.selectedRoomID == room.id
        let isPointedAt = hover?.row(room.id).isPointedAt == true || DevHooks.hoveredNames.contains(room.name)
        RoomRow(room: room, media: account.media, reaction: account.reactionPreviews[room.id],
                threadReply: account.threadReplyDates[room.id],
                ringing: room.lastCallInvite.flatMap {
                    CallCenter.shared.ringingPreview(account: account, roomID: room.id, invite: $0)
                },
                presence: room.directUserID.flatMap { account.presence.people[$0] },
                // Seen only where this account shares its own typing, as in the conversation,
                // and not in a muted room, which is meant to be quiet.
                typists: account.sharesTyping && !room.isMuted && !room.isInvite ? account.typists(in: room.id) : nil,
                // Not on the open room's row: its composer shows it.
                draft: isSelected ? nil : account.draftPreviews[room.id],
                isSelected: isSelected)
            // Pointed at, a faint wash where the selection would be: which row a click opens.
            .background {
                if isPointedAt && !isSelected {
                    RoundedRectangle(cornerRadius: RoomHoverWash.corner, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .padding(RoomHoverWash.outset)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isPointedAt)
            // Where the row is, as far as the wash reaches, for the list to tell which row the
            // pointer is on (RoomListHover).
            .background { RoomHoverProbe(id: room.id, hover: hover).padding(RoomHoverWash.outset) }
            .tag(room.id)
            .listRowDraggable(room.id) {
                Label(room.name, systemImage: "bubble.left")
                    .padding(6)
            }
            // Its own view, made only as the menu opens: built here, it would run its unread
            // checks across every room each time any row is drawn.
            .contextMenu { WithPerceptionTracking { RoomRowMenu(account: account, room: room, actions: actions) } }
            .accessibilityActions { placeActions }
            .onAppear { account.roomBecameVisible(room.id) }
            .onDisappear { account.roomBecameHidden(room.id) }
    } }

    /// Everywhere the room can be put, in the list's order.
    private var destinations: [(title: String, place: SectionPlace)] {
        Self.destinations(for: room, in: account)
    }

    static func destinations(for room: RoomSummary, in account: AccountSession) -> [(title: String, place: SectionPlace)] {
        [("Favourites", .favourites)]
            + account.customSections.map { ($0.name, .custom($0.id)) }
            + [("Low Priority", .lowPriority), (account.usualSectionTitle(of: room), .usual)]
    }

    /// The menu's moves, for VoiceOver (and tests).
    @ViewBuilder private var placeActions: some View {
        if !room.isInvite {
            let place = account.place(of: room)
            ForEach(destinations.filter { $0.place != place }, id: \.title) { destination in WithPerceptionTracking {
                Button("Move to \(destination.title)") { actions.move(room.id, destination.place) }
            } }
            Button("Move to New Section") { actions.newSection(room.id) }
            Button(room.isMuted ? "Unmute" : "Mute") { actions.setNotifications(room.id, room.isMuted ? nil : .mute) }
        }
    }
}

/// The hover wash's shape: the sidebar's selection highlight, which reaches past a row's content
/// by the list's own margins.
private enum RoomHoverWash {
    static let corner: CGFloat = 5
    static let outset = EdgeInsets(top: -4, leading: -6, bottom: -4, trailing: -6)
}

/// A room's right-click menu: read state, notifications, where it's kept, and its space.
private struct RoomRowMenu: View {
    let account: AccountSession
    let room: RoomSummary
    let actions: RoomListSection.Actions

    var body: some View { WithPerceptionTracking {
        if room.isInvite {
            // An invitation's own choices, rather than an empty menu.
            Button("Accept Invitation") {
                FailureAlert.run("Couldn’t Join “\(room.name)”") { try await account.acceptInvite(roomID: room.id) }
            }
            Button("Decline Invitation") {
                FailureAlert.run("Couldn’t Decline the Invitation") { try await account.leave(roomID: room.id) }
            }
        } else {
            if account.isUnread(room.id) {
                Button("Mark as Read") { account.setRoom(room.id, unread: false) }
            } else {
                Button("Mark as Unread") { account.setRoom(room.id, unread: true) }
            }
            NotificationModeMenu(mode: room.notificationMode, defaultMode: account.defaultNotificationMode(for: room)) {
                actions.setNotifications(room.id, $0)
            }
            Divider()
            // As Element's room menu has them, ticked where the room is. A room is in one
            // section at a time, so ticking one takes it out of the other; unticking puts it
            // back in People or Rooms.
            let place = account.place(of: room)
            Toggle("Favourite", isOn: Binding(get: { place == .favourites },
                                              set: { actions.move(room.id, $0 ? .favourites : .usual) }))
            Toggle("Low Priority", isOn: Binding(get: { place == .lowPriority },
                                                 set: { actions.move(room.id, $0 ? .lowPriority : .usual) }))
            Menu("Move To") { WithPerceptionTracking {
                ForEach(RoomListRow.destinations(for: room, in: account), id: \.title) { destination in WithPerceptionTracking {
                    Toggle(destination.title, isOn: Binding(get: { place == destination.place },
                                                            set: { _ in actions.move(room.id, destination.place) }))
                } }
                Divider()
                Button("New Section…") { actions.newSection(room.id) }
            } }
            Divider()
            if let space = account.selectedSpaceID {
                Button("Mark All as Read") { account.markAllRead(inSpace: space) }
                    .disabled(!account.hasUnreadRooms(inSpace: space))
                if account.editableSpaceIDs.contains(space), account.isDirectChild(room.id, of: space) {
                    Divider()
                    Button("Remove from \(account.spaceName(space))") {
                        FailureAlert.run("Couldn’t Remove the Room") { try await account.removeRoom(room.id, fromSpace: space) }
                    }
                }
            } else {
                Button("Mark All as Read") { account.markAllRead(inSpace: nil) }
                    .disabled(!account.hasUnreadRooms(inSpace: nil))
            }
        }
    } }

}

/// The room list of a space with nothing in it to show: a space with no rooms yet, or
/// whose rooms the account hasn't joined.
private struct SpaceEmptyList: View {
    let account: AccountSession
    let spaceID: String

    var body: some View { WithPerceptionTracking {
        let isEmpty = (account.spaces.first { $0.roomId == spaceID }?.childrenCount ?? 0) == 0
        let canEdit = account.editableSpaceIDs.contains(spaceID)
        let name = account.spaceName(spaceID)
        EmptyState {
            Label(isEmpty ? "No Rooms Yet" : "No Rooms Joined", systemImage: "square.stack")
        } description: {
            if isEmpty {
                Text(canEdit ? "Make a room in \(name), or add one you’re in." : "Nobody has added a room to \(name) yet.")
            } else {
                Text("You haven’t joined any of the rooms in \(name) yet.")
            }
        } actions: {
            if isEmpty {
                if canEdit {
                    Button("New Room…") { account.sheet = .newRoom(inSpace: spaceID) }
                }
            } else if account.browsingSpaceID != spaceID {
                Button("Browse Rooms") { account.browse(space: spaceID) }
            }
        }
    } }
}

private struct RoomRow: View {
    let room: RoomSummary
    let media: MediaLoader
    var reaction: ReactionPreview?
    /// The date of the room's newest reply in a thread, when known.
    var threadReply: Date?
    /// Said in place of the newest message, a call's invite, while the call rings:
    /// "You’re calling", as its line in the conversation says.
    var ringing: String?
    /// The other person's, in a direct chat.
    var presence: PresenceInfo?
    /// Who is typing in the room.
    var typists: RoomTypists?
    /// A message being written in the room and not yet sent.
    var draft: DraftPreview?
    /// The open room's row, drawn in the accent colour when the list has the focus.
    var isSelected = false

    /// The reaction, when it is more recent than the room's newest message.
    private var latestReaction: ReactionPreview? {
        guard let reaction, !room.isInvite, reaction.date > (room.timestamp ?? .distantPast) else { return nil }
        return reaction
    }

    private var preview: String {
        if room.isInvite { return room.lastMessage ?? "Invitation" }
        // The newest message is that reply: say it's in a thread.
        let inThread = threadReply != nil && threadReply == room.timestamp ? room.lastMessageInThread : nil
        return latestReaction?.text ?? inThread ?? ringing ?? room.lastMessage ?? " "
    }

    /// Who is typing, said in place of the newest message while they are: "typing…" in a direct
    /// chat, whose name is theirs, and "Alice is typing…" in a room.
    private var typing: String? {
        guard let names = typists?.names, !names.isEmpty else { return nil }
        if room.directUserID != nil, names.count == 1 { return "typing…" }
        return TypingRow.sentence(for: names.map { Typist(userID: $0, name: $0, avatarURL: nil) }) + "…"
    }

    /// The draft, said in place of the newest message, unless that message is news: then it's
    /// what they wrote that shows, and the draft comes back once the room has been read.
    private var draftLine: Text? {
        guard let draft else { return nil }
        let isNews = room.notifications > 0 || room.mentions > 0 || (room.hasNewMessages && !room.isMuted)
        guard !isNews else { return nil }
        var label = AttributedString(draft.inThread ? "Draft in thread: " : "Draft: ")
        label.foregroundColor = .red
        return Text(label + AttributedString(draft.text))
    }

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            AvatarView(media: media, url: room.avatarURL, name: room.name, seed: room.avatarSeed, size: 36)
                .presenceDot(presence, avatarSize: 36)
                .help(presence?.description ?? "")
                .accessibilityValue(presence?.description ?? "")
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(room.name)
                        .fontWeight(room.showsUnread || room.isHighlighted ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if room.hasCall {
                        // A call going on in the room.
                        Image(systemName: "phone.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                            .help("A call is going on")
                            .accessibilityLabel("Call going on")
                    }
                    if let timestamp = latestReaction?.date ?? room.timestamp {
                        Text(timestamp.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(alignment: .center) {
                    if let typing {
                        // In colour, as it's news; on the open room's row, as the row's own text
                        // is, since that row may be in the accent colour itself.
                        Text(typing)
                            .font(.callout)
                            .foregroundStyle(isSelected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                            .lineLimit(1)
                    } else if let draftLine {
                        draftLine
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(preview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if room.isMuted {
                        Image(systemName: "bell.slash.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: Self.badgeWidth)
                            .help("Muted")
                            .accessibilityLabel("Muted")
                    }
                    badge
                }
            }
        }
        .padding(.vertical, 3)
    } }

    @ViewBuilder private var badge: some View {
        if room.isInvite {
            pill(Text("Invite"), color: .red, padding: 6)
        } else if room.mentions > 0 {
            pill(Text("@"), color: .red)
        } else if room.notifications > 0 {
            pill(Text("\(min(room.notifications, 99))"), color: room.isUrgent ? .red : .accentColor)
        } else if room.showsUnread {
            // Marked unread on purpose is a reminder, in colour; new messages in a quiet room
            // only a grey dot.
            Circle()
                .fill(room.isMarkedUnread ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 8, height: 8)
                .frame(width: Self.badgeWidth)
                .accessibilityLabel(room.isMarkedUnread ? "Marked unread" : "Unread")
        }
    }

    /// Every badge is at least this wide, so they line up down the list's right edge.
    private static let badgeWidth: CGFloat = 20

    private func pill(_ text: Text, color: Color, padding: CGFloat = 4) -> some View {
        text
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, padding)
            .frame(minWidth: Self.badgeWidth, minHeight: 18)
            .background(color, in: Capsule())
    }
}

private struct Banner: View {
    let icon: String
    let text: String
    let action: String?
    /// Closes it for good, if it can be.
    var dismiss: (() -> Void)?
    let perform: () -> Void

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action {
                Button(action, action: perform)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Don’t suggest this again")
                .accessibilityLabel("Close")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
    } }
}

extension Date {
    var roomListLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(self) {
            return "Yesterday"
        }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 7 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        return formatted(date: .numeric, time: .omitted)
    }
}
