import MatrixRustSDK
import SwiftUI

struct RoomView: View {
    let account: AccountSession
    let roomID: String
    /// What the panel beside the timeline shows, if it is open.
    private var panel: ThreadPanel.Content? {
        get { account.sidePanels[roomID] }
        nonmutating set { account.sidePanels[roomID] = newValue }
    }

    /// The thread panel's width as the user last dragged it; 0 until they have.
    @AppStorage("threadPanelWidth") private var preferredPanelWidth: Double = 0
    /// The width when a drag of the divider began.
    @State private var dragStartWidth: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// What the panel shows on screen: follows `panel`, but holds on while the panel slides away.
    @State private var shownPanel: ThreadPanel.Content?
    /// Whether the room gives the panel its width. Moved a moment after the panel is put in
    /// place, so that it slides as a view already there: a view sliding in as it is added
    /// leaves its scrolling parts (which AppKit draws) where they will end up, and the
    /// conversation narrowing beside it is drawn over a panel that hasn't moved.
    @State private var isPanelOut = false
    /// Whether the conversation is laid out with room for the panel beside it. Changed just
    /// before the panel moves, and not animated, so its messages re-wrap once, at the start,
    /// rather than at every width the conversation passes through as the panel slides.
    @State private var roomForPanel = false
    /// A view around an older message, standing in for the live timeline while it is open.
    @State private var focused: RoomTimeline?
    /// Which pinned message the banner shows.
    @State private var pinIndex = 0
    /// Changed when the panel comes back with something else on it before it had quite gone,
    /// so that it starts afresh rather than moving over from what it showed.
    @State private var panelGeneration = 0

    init(account: AccountSession, roomID: String) {
        self.account = account
        self.roomID = roomID
        // Left up its history, the room opens where it was: readied before anything is drawn,
        // in a view of its own around that message if it needs one.
        _focused = State(initialValue: account.returnView(for: roomID))
    }

    private var summary: RoomSummary? {
        account.rooms.first { $0.id == roomID }
    }

    var body: some View {
        Group {
            if let room = account.room(id: roomID), room.membership() == .invited || summary?.isInvite == true {
                InviteView(account: account, roomID: roomID, name: title)
            } else if let timeline = account.timeline(for: roomID) {
                // Read here rather than in the toolbar's content, whose changes aren't followed.
                let isInCall = CallCenter.shared.isInCall(account: account, roomID: roomID)
                GeometryReader { geometry in
                    let layout = PanelLayout(width: geometry.size.width, preferred: CGFloat(preferredPanelWidth))
                    ZStack(alignment: .trailing) {
                        HStack(spacing: 0) {
                            TimelineView(timeline: focused ?? timeline, media: account.media,
                                         onOpenThread: { root in panel = .thread(root) },
                                         room: RoomContext(live: timeline, pins: bannerPins(timeline), pinIndex: $pinIndex,
                                                           showPinned: { panel = .pinned },
                                                           focus: { focus(on: $0) },
                                                           returnToLive: returnToLive,
                                                           isMarkedUnread: summary?.isMarkedUnread == true,
                                                           markRead: { account.setRoom(roomID, unread: false) },
                                                           showInfo: { panel = .info },
                                                           showThreads: { panel = .threadList }))
                            // A fresh view for each timeline it shows: where it is scrolled to
                            // belongs to that timeline.
                            .id(focused.map(ObjectIdentifier.init))
                            .transition(.opacity)
                            .environment(\.timelineWidth, roomForPanel && layout.sideBySide
                                         ? layout.width - layout.panelWidth : layout.width)
                            // Takes what is left, and never more: overflowing, it would be cut off.
                            .frame(maxWidth: .infinity)
                            .clipped()
                            if layout.sideBySide {
                                panelSlot(width: layout.panelWidth, layout: layout)
                            }
                        }
                        // Too narrow for both: the panel slides over the conversation instead
                        // of squeezing it, and the conversation dims a shade beneath it.
                        if isPanelOut, !layout.sideBySide {
                            Color.black.opacity(0.1)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                        if !layout.sideBySide {
                            panelSlot(width: layout.overlayWidth, layout: layout)
                        }
                    }
                }
                .onAppear {
                    shownPanel = panel
                    isPanelOut = panel != nil
                    roomForPanel = panel != nil
                }
                .onChange(of: timeline.pinnedEventIDs.isEmpty) { _, none in
                    if none { account.dropBannerPins(for: roomID) }
                }
                .onChange(of: panel) { _, new in panelChanged(to: new) }
                // People's colours as this room has them, everywhere inside it (NameColors).
                .environment(\.nameColorRoom, roomID)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        // A voice call: in a direct chat it rings the other person; in a room it
                        // starts one, or joins the one going on.
                        let calls = CallCenter.shared
                        let hasCall = summary?.hasCall == true
                        // With two people and no call going on, the older kind of call can be
                        // had whatever the room's settings for Element Call's say.
                        let canCall = timeline.permissions.canJoinCalls || (summary?.isOneToOne == true && !hasCall)
                        Button {
                            if isInCall {
                                calls.hangUp(account: account, roomID: roomID)
                            } else {
                                calls.call(account: account, roomID: roomID, title: title)
                            }
                        } label: {
                            // In the call: the button ends it, as End Call at the foot of the
                            // room list does.
                            if isInCall {
                                Label {
                                    Text("End Call")
                                } icon: {
                                    Image(systemName: "phone.down.fill")
                                        .foregroundStyle(.red)
                                }
                            } else {
                                Label(hasCall ? "Join Call" : "Call", systemImage: hasCall ? "phone.fill" : "phone")
                            }
                        }
                        .disabled(!isInCall && !canCall)
                        .help(isInCall ? "End the call"
                              : !canCall ? "This room’s settings don’t let you take part in calls"
                              : hasCall ? "Join the call going on here"
                              : summary?.isDirect == true ? "Voice call" : "Start a voice call in this room")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            if panel == .search {
                                panel = nil
                            } else {
                                account.showSearch(scope: .room)
                            }
                        } label: {
                            Label("Search", systemImage: "magnifyingglass")
                        }
                        .help("Search messages (⌘F)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            panel = panel == .info ? nil : .info
                        } label: {
                            Label("Info", systemImage: "info.circle")
                        }
                        .help("Details, members and settings (⌘I)")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        let newThreads = max(timeline.unreadThreadRoots.count, timeline.newThreads.count)
                        Button {
                            panel = panel == .threadList ? nil : .threadList
                        } label: {
                            Label {
                                Text("Threads")
                            } icon: {
                                // A dot while a thread has replies you haven't seen.
                                Image(systemName: "bubble.left.and.text.bubble.right")
                                    .overlay(alignment: .topTrailing) {
                                        if newThreads > 0 {
                                            Circle()
                                                .fill(Color.accentColor)
                                                .frame(width: 7, height: 7)
                                                .offset(x: 3, y: -2)
                                        }
                                    }
                            }
                        }
                        .help(newThreads == 0 ? "Threads in this room"
                              : newThreads == 1 ? "Threads in this room: new replies in 1"
                              : "Threads in this room: new replies in \(newThreads)")
                        .accessibilityValue(newThreads == 0 ? "" : "New replies")
                    }
                }
            } else {
                ContentUnavailableView("Room Unavailable", systemImage: "questionmark.bubble")
            }
        }
        .environment(\.accountSession, account)
        .onAppear {
            // The room's now, to stop when done (`focused` took it as the room was made).
            if let view = account.takeReturnView(for: roomID), view !== focused { view.stop() }
        }
        .onDisappear {
            focused?.stop()
            focused = nil
            account.roomWasLeft(roomID)
        }
        .navigationTitle(title)
        // In a direct chat, whether the other person is around; in a room, its topic.
        .navigationSubtitle(subtitle)
    }

    /// The panel's place at the room's trailing edge. Closed, it is no width at all, and the
    /// panel, pinned to its leading edge, waits beyond the window's edge; opening gives it its
    /// width, so the panel rides in, and beside the conversation, the conversation gives way
    /// in step.
    private func panelSlot(width: CGFloat, layout: PanelLayout) -> some View {
        ZStack(alignment: .leading) {
            if let shownPanel {
                threadPanel(shownPanel, width: width)
                    // Over the conversation only, and fading with the slide, so none of it
                    // lingers at the window's edge while the panel waits out of sight.
                    .shadow(color: .black.opacity(!layout.sideBySide && isPanelOut ? 0.22 : 0), radius: 16, x: -6)
                    .overlay(alignment: .leading) { resizeHandle(layout) }
            }
        }
        .frame(width: isPanelOut ? width : 0, alignment: .leading)
    }

    /// Slides the panel in or out as it opens or closes; Reduce Motion leaves out the sliding,
    /// and the panel's content fades in by itself.
    ///
    /// The conversation takes its new width first, all at once; the panel starts moving on the
    /// next turn, once the conversation has settled. Opening, the panel is put in place out of
    /// sight in that first turn too, so that it slides as a view already there.
    private func panelChanged(to new: ThreadPanel.Content?) {
        if let new {
            let wasShown = shownPanel != nil
            if wasShown, !isPanelOut, shownPanel != new { panelGeneration += 1 }
            shownPanel = new
            guard !isPanelOut else { return }
            roomForPanel = true
            if reduceMotion {
                isPanelOut = true
                return
            }
            DispatchQueue.main.async {
                guard panel != nil, !isPanelOut else { return }
                withAnimation(Motion.panelIn) { isPanelOut = true }
            }
        } else {
            roomForPanel = false
            if reduceMotion {
                isPanelOut = false
                shownPanel = nil
                return
            }
            DispatchQueue.main.async {
                guard panel == nil else { return }
                // Gone once it is out of sight, without waiting for the spring's last fraction.
                withAnimation(Motion.panelOut) {
                    isPanelOut = false
                } completion: {
                    if panel == nil { shownPanel = nil }
                }
            }
        }
    }

    /// The room's pinned messages for the banner, while it has any. Kept by the account with
    /// the room's timeline, so they are ready the moment the room is shown again.
    private func bannerPins(_ timeline: RoomTimeline) -> RoomTimeline? {
        timeline.pinnedEventIDs.isEmpty ? nil : account.bannerPins(for: roomID)
    }

    /// Shows a message far back in the room in a view of its own, around it.
    private func focus(on eventID: String) {
        guard let timeline = account.focusedTimeline(roomID: roomID, eventID: eventID) else { return }
        let previous = focused
        withAnimation(.easeOut(duration: 0.15)) { focused = timeline }
        previous?.stop()
    }

    private func returnToLive() {
        let previous = focused
        withAnimation(.easeOut(duration: 0.15)) { focused = nil }
        previous?.stop()
    }

    private func threadPanel(_ content: ThreadPanel.Content, width: CGFloat) -> some View {
        ThreadPanel(account: account, roomID: roomID, roomName: title, content: content) {
            self.panel = $0
        }
        .id(panelGeneration)
        .environment(\.timelineWidth, width)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        // Nothing in the panel may spill over the conversation beside it.
        .clipped()
    }

    /// The panel's left edge: a hairline that can be dragged to make the panel wider or
    /// narrower. Double-clicking it goes back to the automatic width.
    private func resizeHandle(_ layout: PanelLayout) -> some View {
        PanelResizeHandle(
            onDrag: { translation in
                let start = dragStartWidth ?? layout.shownWidth
                dragStartWidth = start
                preferredPanelWidth = Double(layout.clamped(start - translation))
            },
            onEnd: { dragStartWidth = nil },
            onReset: { preferredPanelWidth = 0 })
    }

    /// Whether the room is encrypted isn't said here: the lock at the start of the message
    /// field says so where it matters, as what's typed is sent, and Room Info says more.
    private var subtitle: String {
        [presenceLine, topicLine].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// A room's topic, as Slack and Element show it under a room's name: what it's for, where
    /// it can be seen. A direct chat has the person's whereabouts there instead.
    private var topicLine: String {
        guard summary?.directUserID == nil else { return "" }
        return summary?.topic ?? ""
    }

    private var presenceLine: String {
        guard let user = summary?.directUserID else { return "" }
        return account.presence.people[user]?.description ?? ""
    }

    private var title: String {
        summary?.name ?? account.room(id: roomID)?.displayName() ?? "Room"
    }
}

private struct InviteView: View {
    let account: AccountSession
    let roomID: String
    let name: String
    @State private var isBusy = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.open")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("You’re invited to \(name)")
                .font(.title3.weight(.semibold))
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Decline") { run { try await account.leave(roomID: roomID) } }
                Button("Join") { run { try await account.acceptInvite(roomID: roomID) } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        isBusy = true
        Task {
            defer { isBusy = false }
            do { try await work() } catch { self.error = error.actionMessage }
        }
    }
}

/// How the thread panel shares the room's width with the conversation.
private struct PanelLayout {
    let width: CGFloat
    /// The width the user dragged the panel to, or 0 for automatic.
    let preferred: CGFloat

    /// The conversation needs this much to be readable beside the panel.
    private static let conversationMinimum: CGFloat = 400
    /// Narrower than this, a message with a picture or a voice message gets cramped.
    static let panelMinimum: CGFloat = 340

    /// The user's width if they have chosen one, otherwise two fifths of the room; within limits.
    var panelWidth: CGFloat {
        let wanted = preferred > 0 ? preferred : min(440, (width * 0.4).rounded())
        return max(Self.panelMinimum, min(wanted, width - 1 - Self.conversationMinimum))
    }

    var sideBySide: Bool { width - Self.panelMinimum - 1 >= Self.conversationMinimum }

    /// Laid over the conversation, leaving a strip of it showing.
    var overlayWidth: CGFloat {
        let wanted = preferred > 0 ? preferred : 360
        return max(min(Self.panelMinimum, width - 56), min(wanted, width - 56))
    }

    var shownWidth: CGFloat { sideBySide ? panelWidth : overlayWidth }

    /// A dragged width, kept within what this layout allows.
    func clamped(_ value: CGFloat) -> CGFloat {
        sideBySide ? max(Self.panelMinimum, min(value, width - 1 - Self.conversationMinimum))
                   : max(min(Self.panelMinimum, width - 56), min(value, width - 56))
    }
}

/// A one-point divider with a wider strip around it that takes the drag, and shows the
/// resizing cursor while the pointer is over it.
private struct PanelResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        isHovering = hovering
                        updateCursor()
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if !isDragging {
                                    isDragging = true
                                    updateCursor()
                                }
                                onDrag(value.translation.width)
                            }
                            .onEnded { _ in
                                isDragging = false
                                updateCursor()
                                onEnd()
                            }
                    )
                    .onTapGesture(count: 2, perform: onReset)
            }
            .onDisappear {
                if cursorShown { NSCursor.pop() }
                cursorShown = false
            }
            .help("Drag to resize. Double-click for the standard width.")
            .accessibilityElement()
            .accessibilityLabel("Thread panel divider")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Standard width", onReset)
    }

    @State private var cursorShown = false

    /// The resizing cursor while over the strip or dragging it; pushed and popped in pairs so
    /// the cursor underneath comes back as it was.
    private func updateCursor() {
        let wanted = isHovering || isDragging
        guard wanted != cursorShown else { return }
        cursorShown = wanted
        if wanted { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}
