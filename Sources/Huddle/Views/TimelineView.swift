import MatrixRustSDK
import SwiftUI

/// A scrolling list of messages with a composer: a room's timeline, or one thread's.
struct TimelineView: View {
    let timeline: RoomTimeline
    let media: MediaLoader
    var placeholder = "Message"
    /// Opens a message's thread. Nil inside a thread, where there is nothing further to open.
    var onOpenThread: ((String) -> Void)?
    /// The room around the conversation, for the room's own timeline (live, or a stretch around
    /// an older message); nil in a thread.
    var room: RoomContext?

    init(timeline: RoomTimeline, media: MediaLoader, placeholder: String = "Message",
         onOpenThread: ((String) -> Void)? = nil, room: RoomContext? = nil) {
        self.timeline = timeline
        self.media = media
        self.placeholder = placeholder
        self.onOpenThread = onOpenThread
        self.room = room
        // A view around an older message isn't at the newest one, from the very start.
        _followsNewest = State(initialValue: timeline.focusedEvent == nil)
        // Only the newest rows of a long timeline are drawn, from the very first frame.
        let rows = timeline.rows
        if timeline.focusedEvent == nil, rows.count > Self.rowsAtFirst {
            _firstShownID = State(initialValue: rows[rows.count - Self.rowsAtFirst].id)
        }
    }
    @State private var draft = ""
    /// The message being replied to, while writing a reply.
    @State private var replyTarget: ReplyPreview?
    /// The row just jumped to from a reply's quote, lit up for a moment.
    @State private var highlightedRow: String?
    /// While the view scrolls to a row just chosen (a pinned message, a reply's original): no
    /// earlier rows are drawn meanwhile.
    @State private var showingRowUntil = Date.distantPast
    /// The message being looked for after clicking a quote, while older history loads.
    @State private var searchingFor: String?
    /// Images waiting in the composer to be sent.
    @State private var stagedImages: [StagedImage] = []
    /// Other files waiting in the composer to be sent, read from disk as they upload.
    @State private var stagedFiles: [StagedFile] = []
    /// Something about attaching or opening an image that the user should know.
    @State private var imageNotice: String?
    @State private var isDropTarget = false
    @State private var pasteInterceptor = PasteInterceptor()
    @State private var typeToCompose = TypeToCompose()
    /// Where the rows on screen are; kept out of SwiftUI's state so scrolling doesn't redraw.
    @State private var place = ReadingPlace()
    /// Lets a reader's avatar move from one message to another instead of vanishing and
    /// reappearing.
    @Namespace private var receipts
    private static let mostAttachmentsAtOnce = 10
    /// Mentions picked from the suggestions for the message being written.
    @State private var composedMentions: [ComposedMention] = []
    @State private var suggestionIndex = 0
    /// Suggestions the user closed with Escape ("@name" or ":name", as `activeQuery` has them);
    /// they stay closed until the user types on.
    @State private var dismissedQuery: String?
    /// The message being edited in the composer, while one is.
    @State private var editTarget: EditTarget?
    /// What was in the composer when editing began, put back when it ends.
    @State private var stashedDraft = StashedDraft()
    /// Text just put back in the composer, rather than typed: it doesn't say you're typing.
    @State private var restoredDraft: String?
    /// Whether the newest message was being followed when editing began, to go back to it after.
    @State private var followedBeforeEdit = false
    /// Set when editing ends to bring the conversation back to its newest message.
    @State private var returnsToNewest = false
    /// The message the user has asked to delete, while they confirm.
    @State private var pendingDeletion: MessageRow?
    /// The message being forwarded, while the room picker is open.
    @State private var forwarding: ForwardRequest?
    /// Whether the pinned banner slides in or out when it comes or goes: not while the room is
    /// still opening.
    @State private var bannerAnimates = false
    /// Focused timeline: whether the message it was opened for has been shown.
    @State private var hasShownFocus = false
    /// Focused timeline: until when that message stays in the middle as earlier messages load
    /// above it, unless the reader scrolls first.
    @State private var centersFocusUntil: Date?
    /// Paging back through a thread for a message, while it goes on.
    @State private var searchTask: Task<Void, Never>?
    @Environment(\.accountSession) private var account
    @AppStorage(MessageLayout.key) private var chosenLayout = MessageLayout.modern
    @Environment(\.forcedMessageLayout) private var forcedLayout
    @AppStorage(EmojiSize.key) private var emojiSize = EmojiSize.large
    /// Which message shows its hover actions.
    @State private var hoverState = MessageHoverState()
    @Environment(\.controlActiveState) private var windowState
    /// The names' width while it is being dragged; saved for the room when the drag ends.
    @State private var draggedNameWidth: CGFloat?
    @FocusState private var composerFocused: Bool
    /// The recording bar, or the recording waiting to be sent, while there's a voice message.
    @FocusState private var voiceFocused: Bool
    @State private var asksToDeleteVoice = false
    @State private var isHoveringSend = false

    /// Whether the newest message is on screen.
    @State private var isAtBottom = true
    /// All the way at the end, not only near it (`isAtBottom` allows a few points' slack, so
    /// that the reader nudging the view doesn't stop it following the newest message).
    @State private var isAtEnd = true
    /// The intent to stay on the newest message. Unlike `isAtBottom` it survives a batch of
    /// messages, a reload or a resize pushing the newest one out of view, so the view can follow.
    /// Only the user scrolling away ends it.
    @State private var followsNewest = true
    @State private var input = ScrollInputTracker()
    /// Notices the view scrolling itself over and over, for the log.
    @State private var jumps = JumpCounter()
    /// Whether the top of the loaded history is on screen, which is when to fetch more.
    @State private var historyEdgeVisible = false
    /// The same, without the slack: really in view, so the room doesn't reach the top of it.
    @State private var historyEdgeInView = false
    private static let bottomID = "timeline-bottom"
    @Environment(\.timelineWidth) private var timelineWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How the ways back to the newest messages come and go.
    private var jumpTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.7, anchor: .bottomTrailing).combined(with: .opacity)
    }

    /// Whether the conversation is in front of the user: its window the one in front, and no
    /// picture open over it. Messages arriving otherwise (the app in the background, Settings
    /// in front, a picture being looked at, a sheet over the room) stay unread until it is.
    private var isInFrontOfUser: Bool {
        (windowState == .key || DevHooks.assumesActive) && ImageViewerState.shared.item == nil
    }

    private struct ReadTrigger: Equatable {
        let lastRow: String?
        let isAtBottom: Bool
        let isInFrontOfUser: Bool
    }

    private struct HistoryTrigger: Equatable {
        let edgeVisible: Bool
        let finishedRequests: Int
        var shown = 0
        var edgeInView = false
    }

    /// While following the newest message, a room that doesn't reach the top of the view is
    /// filled until it does, up to this many rows; scrolling up to the top asks for more.
    private static let mostRowsToFill = 80

    /// The first row drawn, when the newest ones are drawn and not all of those loaded. A room
    /// opens with its newest few dozen messages drawn, however many are loaded, since every
    /// row drawn adds to the time it takes to show the room; scrolling up draws more.
    @State private var firstShownID: String?
    private static let rowsAtFirst = 30

    /// The IRC layout's names column: as dragged just now, or as saved for the room.
    private var nameWidth: CGFloat {
        draggedNameWidth ?? IRCNameWidths.shared.width(for: timeline.roomID)
    }

    /// Wide enough for the longest name in the conversation, for a double-click on the edge.
    private func fittedNameWidth() -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let widest = timeline.rows.compactMap(\.message).map(\.senderName).reduce(CGFloat(0)) { widest, name in
            max(widest, (name as NSString).size(withAttributes: [.font: font]).width)
        }
        return IRCNameColumn.clamped(widest > 0 ? ceil(widest) + 2 : IRCNameColumn.defaultWidth)
    }

    /// The rows drawn: from `firstShownID` on, or all of them.
    private var shownRows: ArraySlice<TimelineRow> {
        guard let firstShownID, let start = timeline.rows.firstIndex(where: { $0.id == firstShownID }) else {
            return timeline.rows[...]
        }
        return timeline.rows[start...]
    }

    /// Whether earlier rows are loaded but not drawn.
    private var hasUndrawnRows: Bool { shownRows.startIndex > timeline.rows.startIndex }

    /// Draws the next few dozen earlier rows, keeping the message being read where it is.
    private func drawEarlierRows(_ proxy: ScrollViewProxy) {
        let start = shownRows.startIndex
        guard start > timeline.rows.startIndex else { return }
        let newStart = max(timeline.rows.startIndex, start - Self.rowsAtFirst)
        firstShownID = newStart == timeline.rows.startIndex ? nil : timeline.rows[newStart].id
        // Following the newest message, the view goes back to it whatever is drawn above.
        if !followsNewest { holdReadingPlace(proxy, rowsKeepTheirSize: true) }
    }

    /// Makes sure a row is drawn, drawing it and a few dozen before it if it was among the
    /// undrawn: enough that the top of what's drawn isn't in view once the row is, which would
    /// draw more above it as the view gets there, and move it.
    /// Returns whether anything changed, in which case it is on screen only after the next layout.
    private func drawRow(_ rowID: String) -> Bool {
        guard let index = timeline.rows.firstIndex(where: { $0.id == rowID }),
              index < shownRows.startIndex else { return false }
        let newStart = max(timeline.rows.startIndex, index - Self.rowsAtFirst)
        firstShownID = newStart == timeline.rows.startIndex ? nil : timeline.rows[newStart].id
        return true
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy on purpose. A lazy stack only estimates the height of rows it hasn't
                // drawn, so scrolling to the newest message lands in the wrong place, gets
                // corrected a frame later (flicker), and sometimes leaves the view blank.
                VStack(alignment: .leading, spacing: 0) {
                    if timeline.hasMoreHistory || hasUndrawnRows, !timeline.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { historyEdgeVisible = $0 }
                            .onGeometryChange(for: Bool.self, of: Self.isInView) { historyEdgeInView = $0 }
                    }
                    ForEach(shownRows) { row in
                        TimelineRowView(row: row, timeline: timeline, media: media,
                                        actions: MessageActions(openThread: onOpenThread,
                                                                reply: { startReply(to: $0) },
                                                                showOriginal: { showOriginal($0, proxy) },
                                                                openImage: { image, shown in
                                                                    ImageViewerState.shared.open(image, media: media, placeholder: shown)
                                                                },
                                                                edit: { startEdit($0) },
                                                                delete: { askToDelete($0) },
                                                                forward: { startForward($0) }),
                                        isHighlighted: row.id == highlightedRow,
                                        editingItem: editTarget?.itemID,
                                        searchingFor: searchingFor,
                                        receipts: receipts)
                            .equatable()
                            .id(row.id)
                            .onGeometryChange(for: CGRect?.self) { proxy in
                                guard let visible = proxy.bounds(of: .scrollView) else { return nil }
                                let frame = proxy.frame(in: .local)
                                return visible.intersects(frame) ? frame.offsetBy(dx: 0, dy: -visible.minY) : nil
                            } action: { frame in
                                place.rows[row.id] = frame
                                if row.id == place.anchor?.id { readingRowMoved(proxy) }
                            }
                        if row.id == threadRootRowID {
                            RepliesDivider(count: replyCount)
                        }
                    }
                    // Under the newest message, like the next one on its way. Only for someone
                    // who shares their own typing, as in most messaging apps.
                    if account?.sharesTyping ?? true, !timeline.typists.isEmpty {
                        TypingRow(typists: timeline.typists, isOneToOne: timeline.isOneToOne)
                            .padding(.top, 6)
                    }
                    // The very last thing in the scroll view, with nothing below it: scrolling to it
                    // is scrolling to the end. The gap under the newest message sits above it.
                    Color.clear
                        .frame(height: 8)
                    Color.clear
                        .frame(height: 1)
                        .background { ScrollViewProbe(place: place) }
                        .id(Self.bottomID)
                        .onGeometryChange(for: EndPlace.self, of: Self.endPlace) { end in
                            let visible = end != .away
                            isAtBottom = visible
                            isAtEnd = end == .atEnd
                            if visible {
                                // Not while the messages re-wrap around a held reading place:
                                // rows above it shrinking can bring the end into view for a
                                // moment, but the reader hasn't gone there. (Once it has
                                // settled, `messagesWillRewrap` follows again if it is still in view.)
                                if place.heldRow == nil, timeline.focusedEvent == nil { followsNewest = true }
                                // Near the end but short of it, with the reader not scrolling: a
                                // jump that landed short as rows changed height. All the way, or
                                // the newest message sits on the composer's edge until something
                                // else moves.
                                if end == .nearEnd, followsNewest, !input.isRecent, place.heldRow == nil {
                                    DispatchQueue.main.async {
                                        if followsNewest, !isAtEnd { jump(proxy, to: Self.bottomID, anchor: .bottom) }
                                    }
                                }
                            } else if input.leftRecently {
                                // The user scrolled away. (Not while scrolling down: rows growing
                                // under it then pushed the end away, and the view follows on.)
                                if followsNewest {
                                    TimelineLog.log.notice("Stopped following the newest message: reader's \(input.lastKind, privacy: .public) input, \(shownRows.count) rows drawn")
                                }
                                followsNewest = false
                            } else if followsNewest {
                                // The content moved under the view; go back to the end.
                                DispatchQueue.main.async {
                                    if followsNewest { jump(proxy, to: Self.bottomID, anchor: .bottom) }
                                }
                                settleOnNewest(proxy)
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .overlay(alignment: .topLeading) {
                    if forcedLayout ?? chosenLayout == .irc {
                        NameColumnHandle(width: nameWidth, dragged: $draggedNameWidth,
                                         fitted: fittedNameWidth) { width in
                            IRCNameWidths.shared.setWidth(width, for: timeline.roomID)
                            // The messages re-wrap for the new width: keep the one being read in place.
                            messagesWillRewrap(proxy)
                        }
                        .offset(x: 16 + IRCNameColumn.leading + nameWidth + 4 - NameColumnHandle.width / 2)
                    }
                }
                .environment(\.messageLayout, forcedLayout ?? chosenLayout)
                .environment(\.emojiSize, emojiSize)
                .environment(\.ircNameWidth, nameWidth)
                .environment(\.messageHover, hoverState)
                // A popover of the window's own (an emoji picker) leaves it active, not inactive.
                .onChange(of: windowState, initial: true) { _, state in
                    hoverState.isWindowActive = state != .inactive || DevHooks.assumesActive
                }
                // Laid out at the width the timeline is heading for, not at each width it passes
                // through on the way: as the thread panel opens or closes, the messages re-wrap
                // once, at the start, instead of again and again as the conversation narrows,
                // each time jolting everything above the newest message.
                .modifier(LaidOutAtWidth(width: messagesWidth))
                // Rows keep changing height after they first appear: messages decrypt, reactions
                // and thread summaries arrive, more batches load. Whenever the content's height
                // changes while following the newest message, go back to the end.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }) { _ in
                    if followsNewest {
                        jump(proxy, to: Self.bottomID, anchor: .bottom)
                        settleOnNewest(proxy)
                    } else if place.heldRow != nil {
                        restoreReadingPlace(proxy)
                    } else {
                        place.contentChanged = Date()
                        keepReadingPlace(proxy)
                    }
                }
            }
            // A room opens at its newest message. A thread starts at its root message, so a short
            // one sits under the header; a long one is then scrolled to its newest reply.
            .defaultScrollAnchor(timeline.threadRoot == nil && timeline.focusedEvent == nil ? .bottom : .top)
            .modifier(NewestMessageHold(isOn: followsNewest))
            // Under the banners, over the part of the conversation in view: with a panel beside
            // it, the conversation runs on under the panel.
            .overlay(alignment: .topLeading) {
                newThreadReplies.frame(width: messagesWidth)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    if let room, room.isMarkedUnread {
                        MarkedUnreadBar(markRead: room.markRead)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    pinnedBanner(proxy)
                }
                .animation(.snappy(duration: 0.25), value: room?.isMarkedUnread)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                    let changed = height != place.topInset
                    place.topInset = height
                    // A banner arriving (the room's pins load a moment after it opens; the
                    // marked-unread bar) makes the view shorter: back to the very end, once
                    // it has settled.
                    guard changed, followsNewest else { return }
                    for delay in [0.0, 0.3] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            if followsNewest { jump(proxy, to: Self.bottomID, anchor: .bottom) }
                        }
                    }
                }
            }
            // Slides in when a message is pinned while the room is open; just there when the room
            // opens with pins already.
            .animation(bannerAnimates ? .snappy(duration: 0.25) : nil, value: pinnedMessages.isEmpty)
            // The message being edited stays in sight: Up arrow can reach one scrolled away, and
            // the editing bar, as the composer grows, can push one at the edge out of view.
            .onChange(of: editTarget?.itemID) { _, itemID in
                guard let itemID else { return }
                // Once the composer has grown.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard editTarget?.itemID == itemID,
                          let row = timeline.rows.first(where: { $0.message?.itemID == itemID }),
                          !place.isFullyVisible(row.id) else { return }
                    if row.id == timeline.rows.last(where: \.isMessage)?.id {
                        // The newest message: the end of the conversation shows it.
                        scrollToBottom(proxy)
                    } else {
                        followsNewest = false
                        viewWillMove(for: 0.4)
                        withAnimation(.snappy(duration: 0.3)) { proxy.scrollTo(row.id, anchor: .bottom) }
                    }
                }
            }
            // Done editing, having started at the newest message: back there, once the composer
            // has shrunk again.
            .onChange(of: returnsToNewest) { _, returns in
                guard returns else { return }
                returnsToNewest = false
                scrollToBottom(proxy)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if followsNewest { jump(proxy, to: Self.bottomID, anchor: .bottom) }
                }
            }
            // Asked for from elsewhere (the pinned messages in the side panel): through the room's
            // live timeline, so it reaches whichever view of the room is on screen.
            // Also when this view has only just appeared, sent back here to show one.
            .onChange(of: (room?.live ?? timeline).requestedJump, initial: true) { _, eventID in
                guard let eventID else { return }
                (room?.live ?? timeline).requestedJump = nil
                // After the view has settled on its newest message.
                DispatchQueue.main.async { jump(to: eventID, proxy) }
            }
            .onChange(of: timeline.rows.last?.id) { previousLast, _ in
                // The first content, or a new message while following the newest.
                guard timeline.focusedEvent == nil else { return }
                if previousLast == nil {
                    // Messages that arrive after the room is on screen are drawn only the newest
                    // few dozen at first too, as those already loaded are (see `init`).
                    let rows = timeline.rows
                    if firstShownID == nil, rows.count > Self.rowsAtFirst {
                        firstShownID = rows[rows.count - Self.rowsAtFirst].id
                    }
                    TimelineLog.log.notice("First \(rows.count) rows arrived, \(shownRows.count) drawn")
                }
                if previousLast == nil || followsNewest {
                    scrollToBottom(proxy)
                    // The first rows arriving all at once is when the view can land short.
                    if previousLast == nil { settleOnNewest(proxy) }
                }
            }
            // A view around an older message opens on that message, lit up.
            .onChange(of: timeline.rows.count, initial: true) {
                guard let focus = timeline.focusedEvent, !hasShownFocus,
                      let row = timeline.rows.first(where: { $0.eventID == focus }) else { return }
                hasShownFocus = true
                centersFocusUntil = Date().addingTimeInterval(2)
                DispatchQueue.main.async { show(row.id, proxy, animated: false) }
            }
            .task {
                try? await Task.sleep(for: .seconds(1))
                bannerAnimates = true
            }
            .onAppear {
                // Opened again after being marked unread: read as usual from here.
                if timeline.isLive { timeline.holdsUnread = false }
                if timeline.threadRoot == nil { PerfLog.markDrawn("room on screen, \(shownRows.count) of \(timeline.rows.count) rows drawn") }
                TimelineLog.log.notice("Opened a \(timeline.threadRoot == nil ? "room" : "thread", privacy: .public) with \(timeline.rows.count) rows loaded")
                if timeline.focusedEvent != nil {
                    followsNewest = false
                } else if !timeline.rows.isEmpty {
                    scrollToBottom(proxy)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { place.viewport = $0 }
            .onChange(of: messagesWidth) { old, new in
                if old != nil, old != new { messagesWillRewrap(proxy) }
            }
            .onChange(of: timeline.prependCount) {
                defer {
                    if AppEnvironment.isDev, timeline.threadRoot == nil {
                        print("DEV_TIMELINE_PREPEND rows=\(timeline.rows.count) drawn=\(shownRows.count) following=\(followsNewest) atTop=\(historyEdgeVisible)")
                        fflush(stdout)
                    }
                    // Not asked for here (the view isn't at its top): something else loaded the
                    // room's history (an indexing pass, the SDK's own), which can slow the room.
                    if !historyEdgeVisible, timeline.threadRoot == nil, timeline.focusedEvent == nil {
                        TimelineLog.log.notice("Older messages arrived above the open room unasked: \(timeline.rows.count, privacy: .public) rows loaded, \(shownRows.count, privacy: .public) drawn, following newest \(followsNewest, privacy: .public)")
                    }
                }
                // Older messages were added above. Unless the view is at its top, where they were
                // asked for, they came on their own (the SDK fetches history in the background,
                // for search) and aren't drawn until scrolled to, so the room doesn't grow and
                // slow down for them. Only the rows that just arrived; those drawn stay drawn.
                if timeline.focusedEvent == nil, firstShownID == nil, followsNewest || !historyEdgeVisible,
                   let previousFirst = timeline.prependAnchorID {
                    firstShownID = previousFirst
                }
                // While following the newest message, stay there; otherwise stay on the message
                // being read, wherever it is in the view.
                if followsNewest {
                    scrollToBottom(proxy)
                } else if let until = centersFocusUntil, Date() < until, !input.isRecent,
                          let focus = timeline.focusedEvent,
                          let row = timeline.rows.first(where: { $0.eventID == focus }) {
                    // Still settling on the message it was opened for: keep that in the middle.
                    DispatchQueue.main.async { jump(proxy, to: row.id, anchor: .center) }
                } else {
                    holdReadingPlace(proxy, rowsKeepTheirSize: true)
                }
            }
            // Fetches history while its top edge is on screen, again after each request finishes.
            .task(id: HistoryTrigger(edgeVisible: historyEdgeVisible, finishedRequests: timeline.historyRequests,
                                     shown: shownRows.count, edgeInView: historyEdgeInView)) {
                guard historyEdgeVisible else { return }
                // What was just drawn or loaded takes its place first. Asked again before the
                // layout caught up, the edge would still look in view, and a room opening with a
                // few messages loaded would draw a hundred or more, scrolling itself all the while.
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                // Filling a room that doesn't reach the top of the view: only while the edge is
                // really in view, and only so far. The reader scrolling up to it asks for more,
                // a little before it's reached.
                if followsNewest, timeline.focusedEvent == nil {
                    guard historyEdgeInView, shownRows.count < Self.mostRowsToFill else { return }
                }
                // Not while the view is on its way to a message just chosen: rows drawn above
                // it then would move it from under the view as it gets there.
                let wait = showingRowUntil.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    guard !Task.isCancelled, historyEdgeVisible else { return }
                }
                if hasUndrawnRows {
                    // Already loaded: drawn at once, no need to ask the server.
                    drawEarlierRows(proxy)
                } else if timeline.hasMoreHistory {
                    await timeline.loadOlder()
                }
            }
            // A view around an older message fills in newer ones as its end comes into sight.
            .task(id: HistoryTrigger(edgeVisible: isAtBottom, finishedRequests: timeline.newerRequests)) {
                if timeline.focusedEvent != nil, isAtBottom, timeline.hasMoreNewer { await timeline.loadNewer() }
            }
            .overlay(alignment: .bottomTrailing) {
                // Each fades in growing a little (only fading, with Reduce Motion), and out again.
                ZStack(alignment: .bottomTrailing) {
                if timeline.focusedEvent != nil, let room {
                    // Looking at an older stretch of the room: the way back to now.
                    Button(action: room.returnToLive) {
                        Label("Jump to Latest", systemImage: "arrow.down")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .overlay { Capsule().strokeBorder(.separator) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Back to the newest messages")
                    .transition(jumpTransition)
                } else if !isAtBottom, !followsNewest, !timeline.rows.isEmpty {
                    Button {
                        scrollToBottom(proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(.separator) }
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Jump to latest")
                    .accessibilityLabel("Jump to Latest")
                    .transition(jumpTransition)
                }
                }
                .animation(.snappy(duration: 0.2), value: timeline.focusedEvent != nil)
                .animation(.snappy(duration: 0.2), value: !isAtBottom && !followsNewest)
            }
            .overlay {
                if timeline.isLoading { ProgressView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    // Someone's identity changed: said over the composer, before anything is sent.
                    if let warning = identityWarning {
                        IdentityWarningBar(warning: warning, account: account)
                            .id(warning.userID)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    composer(proxy)
                }
                .animation(.snappy(duration: 0.2), value: identityWarning?.userID)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { place.bottomInset = $0 }
            }
        }
        // Runs when a new message arrives and when the newest one scrolls into view.
        .task(id: ReadTrigger(lastRow: timeline.rows.last?.id, isAtBottom: isAtBottom, isInFrontOfUser: isInFrontOfUser)) {
            if isAtBottom, isInFrontOfUser, !timeline.rows.isEmpty { await timeline.markAsRead() }
        }
        .onAppear {
            restoreDraft()
            // Ready to type in. Not when the room was reached with the arrow keys, though: the
            // keyboard stays in the room list so the arrows keep moving through it (typing
            // still lands here, by way of `typeToCompose`).
            let chosenToWriteIn = account?.wantsComposerFocus == true && timeline.threadRoot == nil
            if chosenToWriteIn { account?.wantsComposerFocus = false }
            if NSApp.currentEvent?.type != .keyDown || chosenToWriteIn {
                composerFocused = true
                // Clicking a row in the list leaves the keyboard with the list for a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { composerFocused = true }
                // A draft put back is carried on with, not typed over: a field taking the keyboard
                // selects all it holds.
                if !draft.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { cursorToEnd() }
                }
            }
            if timeline.threadRoot == nil {
                typeToCompose.focus = { composerFocused = true }
                typeToCompose.start()
            }
            input.onInput = { viewWillMove(for: 0.15) }
            input.start()
            pasteInterceptor.onImages = { stage($0) }
            pasteInterceptor.onFiles = { attach($0) }
            pasteInterceptor.start()
            _ = media.uploadLimit       // learn the server's size limit before it is needed
            if timeline.threadRoot == nil, DevHooks.stagesFiles(inRoomNamed: timeline.room.displayName()) {
                DevHooks.didStageImages = true
                attach(DevHooks.stagedImagePaths.map { URL(fileURLWithPath: $0) })
            }
        }
        .onChange(of: composerFocused, initial: true) { pasteInterceptor.isActive = composerFocused }
        .alert(pendingDeletion?.isOwn == false ? "Remove this message?" : "Delete this message?",
               isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
               presenting: pendingDeletion) { message in
            Button(message.isOwn ? "Delete" : "Remove", role: .destructive) {
                if editTarget?.itemID == message.itemID { finishEdit() }
                Task { await timeline.delete(message.itemID) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("It will be removed for everyone in the room. This can’t be undone.")
        }
        .sheet(item: $forwarding) { request in
            if let account {
                ForwardSheet(account: account, request: request)
            }
        }
        .background { WindowReader { typeToCompose.window = $0 } }
        .background { InputArea(tracker: input) }
        // Images dragged anywhere over the conversation land in the composer.
        .onDrop(of: ImageDrop.types, isTargeted: $isDropTarget) { providers in
            Task {
                let dropped = await ImageDrop.sources(from: providers)
                stage(dropped.images)
                attach(dropped.files)
            }
            return true
        }
        .overlay {
            if isDropTarget { DropTargetOverlay() }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        .onDisappear {
            keepDraft()
            searchTask?.cancel()
            input.stop()
            pasteInterceptor.stop()
            typeToCompose.stop()
            AudioPlayback.shared.stop(owner: timeline)
            VideoPlayback.shared.stop(owner: timeline)
            // A recording going on here stops and waits here, for coming back to, and the room
            // list says it's waiting.
            let key = draftKey
            let account = account
            Task {
                await VoiceRecorder.shared.stop(key)
                account?.voiceRecordingChanged(forDraftKey: key)
            }
            timeline.setTyping(false)
            let timeline = timeline
            Task { await timeline.leave() }
        }
    }

    /// Whether a view inside the scroll view is within, or just outside, the visible area.
    /// Where the end of the conversation is: in view, within a few points of it (the reader's
    /// nudge, or a jump that landed short), or out of sight.
    private enum EndPlace: Equatable { case atEnd, nearEnd, away }

    private static func endPlace(_ geometry: GeometryProxy) -> EndPlace {
        guard let visible = geometry.bounds(of: .scrollView) else { return .away }
        let marker = geometry.frame(in: .local)
        if visible.maxY >= marker.maxY - 0.5, visible.intersects(marker.insetBy(dx: 0, dy: -0.5)) { return .atEnd }
        return isOnScreen(geometry) ? .nearEnd : .away
    }

    private static func isInView(_ geometry: GeometryProxy) -> Bool {
        guard let visible = geometry.bounds(of: .scrollView) else { return false }
        return visible.intersects(geometry.frame(in: .local))
    }

    private static func isOnScreen(_ geometry: GeometryProxy) -> Bool {
        guard let visible = geometry.bounds(of: .scrollView) else { return false }
        return visible.insetBy(dx: 0, dy: -24).intersects(geometry.frame(in: .local))
    }

    /// In a thread, the root message's row: replies are set off below it.
    private var threadRootRowID: String? {
        // The root itself, not whichever message loaded first: replies can arrive before it.
        guard let root = timeline.threadRoot else { return nil }
        return timeline.rows.first(where: { $0.eventID == root })?.id
    }

    private var replyCount: Int {
        max(timeline.rows.filter(\.isMessage).count - 1, 0)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        followsNewest = true
        jump(proxy, to: Self.bottomID, anchor: .bottom)
    }

    /// Scrolls at once, even in the middle of an animation (the thread panel sliding): a
    /// scroll that animates trails the content it is meant to hold in place, and the
    /// conversation bobs.
    private func jump(_ proxy: ScrollViewProxy, to id: some Hashable, anchor: UnitPoint) {
        jumps.count(rowsDrawn: shownRows.count, follows: followsNewest, atBottom: isAtBottom)
        viewWillMove(for: 0.4)
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(id, anchor: anchor) }
    }

    /// The width messages are laid out at: the timeline's whole width, less a scroll bar that
    /// takes room of its own, from the moment the timeline is given it.
    private var messagesWidth: CGFloat? {
        guard timelineWidth > 0 else { return nil }
        let scroller = NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        return max(0, timelineWidth - scroller)
    }

    /// Makes sure the end is in view once things have settled, while following the newest
    /// message. A jump to it can land short when rows change height in that same moment (one
    /// arriving as another decrypts or gains a note), and nothing would try again until
    /// something else moved: the newest message would sit half under the composer until the
    /// reader scrolled. Each call puts the check off again, so it runs once, after the last change;
    /// a jump of its own that lands short too gets one more look.
    private func settleOnNewest(_ proxy: ScrollViewProxy, retry: Bool = false) {
        place.settleCheck?.cancel()
        let check = DispatchWorkItem {
            guard followsNewest, place.heldRow == nil, timeline.focusedEvent == nil else { return }
            guard isAtEnd else {
                TimelineLog.log.notice("The newest message was out of view while following it, \(shownRows.count, privacy: .public) rows drawn: going back to it\(retry ? " again" : "", privacy: .public)")
                jump(proxy, to: Self.bottomID, anchor: .bottom)
                if !retry { settleOnNewest(proxy, retry: true) }
                return
            }
            // SwiftUI has the end in view; AppKit's view, under it, may not (ReadingPlace.scrollView).
            // A jump of SwiftUI's would change nothing, it being there already: move AppKit's.
            if let short = place.scrollViewShortOfEnd, short > 2 {
                TimelineLog.log.notice("The scroll view was \(Int(short), privacy: .public) points short of the end while following it, \(shownRows.count, privacy: .public) rows drawn: moved it there")
                place.scrollViewToEnd()
            }
        }
        place.settleCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: check)
    }

    /// The messages are about to re-wrap for a new width: the thread panel opening or closing,
    /// or the window resized. If the newest message was in view, it stays there. If the reader
    /// was further up, the message in the middle of the view goes back to exactly where it was
    /// once every row has changed height, rather than the conversation sliding away under them.
    private func messagesWillRewrap(_ proxy: ScrollViewProxy) {
        if followsNewest {
            for delay in [0.05, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if followsNewest { jump(proxy, to: Self.bottomID, anchor: .bottom) }
                }
            }
            return
        }
        holdReadingPlace(proxy)
    }

    /// Keeps the message in the middle of the view where it is through a change to the rows
    /// around it. Called before the change is laid out, while the rows' places are still the
    /// ones the reader sees.
    /// - Parameter rowsKeepTheirSize: true when rows are only being added above (history, or
    ///   rows drawn), so the held one is the same height after: it is put back in that same
    ///   update, before anything is drawn. Otherwise (the text re-wrapping) once laid out anew.
    private func holdReadingPlace(_ proxy: ScrollViewProxy, rowsKeepTheirSize: Bool = false) {
        guard let middle = place.middleRow(among: timeline.rows.map(\.id)) else { return }
        place.heldRow = middle
        place.heldSince = Date()
        if rowsKeepTheirSize, let frame = place.rows[middle.id] ?? nil {
            let span = place.viewport - place.topInset
            if span > frame.height {
                jump(proxy, to: middle.id, anchor: UnitPoint(x: 0, y: middle.top / (span - frame.height)))
            }
        }
        for delay in [0.0, 0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                restoreReadingPlace(proxy)
                if delay == 0.3 {
                    place.heldRow = nil
                    viewWillMove(for: 0)
                    // Back in place and the newest message in view after all: follow it again.
                    if isAtBottom, timeline.focusedEvent == nil { followsNewest = true }
                }
            }
        }
    }

    /// Reading older messages, the row in the middle of the view stays where it is when rows
    /// above it change height: a picture arriving without a size, a message decrypting,
    /// reactions or a thread summary loading. The view only keeps its distance from the top of
    /// the conversation, so otherwise what's being read slides down, as if the view had
    /// jumped up. The place is noted once the reader stops scrolling (and after the view's own
    /// moves), and the row put back whenever it moves for any other reason.
    private func keepReadingPlace(_ proxy: ScrollViewProxy) {
        guard !followsNewest, place.heldRow == nil, let anchor = place.anchor,
              let frame = place.rows[anchor.id] ?? nil, abs(frame.minY - anchor.top) > 0.5 else { return }
        let span = place.viewport - place.topInset
        guard span > frame.height else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(anchor.id, anchor: UnitPoint(x: 0, y: anchor.top / (span - frame.height)))
        }
    }

    /// The row being read has moved. Just after the content changed height, that's what moved
    /// it: it goes back. Otherwise the view was scrolled (its scroll bar's track clicked, say,
    /// which isn't noticed as scrolling), and where the row is now is the place.
    private func readingRowMoved(_ proxy: ScrollViewProxy) {
        if Date().timeIntervalSince(place.contentChanged) < 0.15 {
            keepReadingPlace(proxy)
        } else if let anchor = place.anchor, let frame = place.rows[anchor.id] ?? nil {
            place.anchor = (anchor.id, frame.minY)
        } else {
            place.anchor = nil
        }
    }

    /// The view is about to move (the reader scrolling, or the view itself): the reading place
    /// isn't held while it does, and is noted again once it has stopped.
    private func viewWillMove(for seconds: Double) {
        place.anchor = nil
        place.anchorWork?.cancel()
        let work = DispatchWorkItem {
            guard !followsNewest, place.heldRow == nil else { return }
            place.anchor = place.middleRow(among: timeline.rows.map(\.id))
        }
        place.anchorWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Scrolls so the held row's top is where it was before the rows around it changed. If the
    /// reader has scrolled since the place was taken, where they are now is the place: it is
    /// taken again there, and the view isn't pulled back.
    private func restoreReadingPlace(_ proxy: ScrollViewProxy) {
        guard !followsNewest, place.heldRow != nil else { return }
        if input.hasInput(since: place.heldSince) {
            if let middle = place.middleRow(among: timeline.rows.map(\.id)) {
                place.heldRow = middle
                place.heldSince = Date()
            }
            return
        }
        guard let held = place.heldRow, let frame = place.rows[held.id] ?? nil,
              abs(frame.minY - held.top) > 0.5 else { return }    // already where it was
        // Rows are measured from just below the pinned banner, and scrolling to a point of a row
        // lines it up with the point as far down the rest of the view (the composer counts in
        // that rest: it floats over the scroll view's foot).
        let span = place.viewport - place.topInset
        guard span > frame.height else { return }
        let fraction = held.top / (span - frame.height)
        jump(proxy, to: held.id, anchor: UnitPoint(x: 0, y: fraction))
    }

    /// The first of the room's identity warnings still standing: one answered here (verified,
    /// accepted, withdrawn) goes at once, without waiting for the room to hear of it, which
    /// takes until the SDK next looks at their keys.
    private var identityWarning: IdentityWarning? {
        timeline.identityWarnings.first { account?.peopleIdentities[$0.userID]?.isChange ?? true }
    }

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = timeline.error {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(error)
                        .foregroundStyle(.red)
                    Button {
                        timeline.dismissError()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                }
                .font(.caption)
                .padding(.leading, 36)
            }
            if let imageNotice {
                Text(imageNotice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 36)
            }
            if !stagedImages.isEmpty || !stagedFiles.isEmpty {
                StagedImagesRow(images: stagedImages, files: stagedFiles) { image in
                    stagedImages.removeAll { $0.id == image.id }
                } removeFile: { file in
                    stagedFiles.removeAll { $0.id == file.id }
                }
                .padding(.leading, 36)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let editTarget {
                EditComposerBar(original: editTarget.original, isCaption: editTarget.kind == .caption) { finishEdit() }
                    .padding(.leading, 46)
                    .padding(.trailing, 42)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let replyTarget {
                ReplyComposerBar(reply: replyTarget) { self.replyTarget = nil }
                    // Lined up with the text field below: its text on the left, its edge on the right.
                    .padding(.leading, 46)
                    .padding(.trailing, 42)
                    .padding(.bottom, 2)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    if hasVoiceMessage {
                        DeleteRecordingButton { deleteVoice() }
                    } else if editTarget == nil {
                        AttachButton { pickFiles() }
                    } else {
                        // Nothing to attach to an edit: the place says what the field is doing.
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28, height: 28)
                            .background(Color.accentColor.opacity(0.14), in: Circle())
                            .accessibilityHidden(true)
                    }
                }
                // Level with the middle of a one-line field, and with its last line as it grows.
                .frame(height: ComposerField.oneLine)
                if let phase = recordingPhase {
                    VoiceRecordingBar(phase: phase, elapsed: voice.elapsed, levels: voice.levels) {
                        let key = draftKey
                        Task { await voice.stop(key) }
                    }
                    .frame(height: ComposerField.line)
                    .modifier(ComposerField())
                    .modifier(VoiceKeys(focus: $voiceFocused, send: { sendVoice(proxy) }, escape: escapeVoice))
                } else if let recording = voiceRecording {
                    HStack(spacing: 0) {
                        AudioMessageView(id: VoiceRecorder.playbackID(for: recording), audio: recording.attachment,
                                         media: media, owner: timeline, isEmbedded: true)
                        Spacer(minLength: 0)
                    }
                    .frame(height: ComposerField.line)
                    .modifier(ComposerField())
                    .modifier(VoiceKeys(focus: $voiceFocused, send: { sendVoice(proxy) }, escape: escapeVoice))
                } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Whether what's typed here will be encrypted, at a glance, where it's typed.
                    EncryptionGlyph(encryption: timeline.encryption, showInfo: room?.showInfo)
                    TextField(composerPlaceholder, text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .focused($composerFocused)
                        .accessibilityHint(editTarget == nil ? "Return sends. Shift-Return starts a new line."
                                                             : "Return saves. Shift-Return starts a new line.")
                        .onSubmit { send(proxy) }
                        // While suggestions (people or emoji) are showing, the arrows move through
                        // them and Return or Tab picks one instead of sending. Shift-Return starts a new line, as
                        // in Element and most chat apps (Option-Return does too, as in any field).
                        .onKeyPress(.upArrow) { upArrow() }
                        .onKeyPress(.downArrow) { moveSuggestion(1) }
                        .onKeyPress(.return, phases: .down) { press in
                            press.modifiers.contains(.shift) ? insertLineBreak() : pickSelectedSuggestion()
                        }
                        .onKeyPress(.tab) { pickSelectedSuggestion() }
                        .onKeyPress(.escape) {
                            // Escape closes the suggestions if they are open; otherwise it cancels a reply.
                            if suggestionCount > 0 {
                                dismissedQuery = activeQuery
                                return .handled
                            }
                            if editTarget != nil {
                                finishEdit()
                                return .handled
                            }
                            guard replyTarget != nil else { return .ignored }
                            replyTarget = nil
                            return .handled
                        }
                        .onChange(of: draft) { old, new in
                            completeShortcode(from: old, to: new)
                            keepDraft()
                            suggestionIndex = 0
                            if activeQuery != dismissedQuery { dismissedQuery = nil }
                            if mentionQuery != nil { Task { await timeline.loadMembers() } }
                            noteTyping()
                        }
                }
                .modifier(ComposerField())
                }
                sendButton(proxy)
                    .frame(height: ComposerField.oneLine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.2), value: replyTarget?.eventID)
        .animation(.snappy(duration: 0.2), value: editTarget?.itemID)
        .animation(.snappy(duration: 0.2), value: stagedImages.map(\.id))
        .animation(.snappy(duration: 0.2), value: stagedFiles.map(\.id))
        .animation(.snappy(duration: 0.2), value: hasVoiceMessage)
        .onChange(of: hasVoiceMessage) {
            // The keys follow what's in the composer: Return sends the recording, Escape deletes it.
            if hasVoiceMessage { voiceFocused = true } else { composerFocused = true }
        }
        .confirmationDialog("Delete this voice message?", isPresented: $asksToDeleteVoice) {
            Button("Delete", role: .destructive) { voice.discard(draftKey) }
        } message: {
            Text("You can’t get it back.")
        }
        .alert(voice.failure?.reason.title ?? "", isPresented: Binding(
            get: { voice.failure?.key == draftKey },
            set: { if !$0 { voice.failure = nil } }
        ), presenting: voice.failure?.reason) { reason in
            if let url = reason.settingsURL {
                Button("Open System Settings") { NSWorkspace.shared.open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: { reason in
            Text(reason.message)
        }
        .background(.bar)
        // Not Divider: inside the room's HStack it would draw itself vertically.
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
        // Floats over the messages, its bottom edge on the composer's top, so nothing moves.
        .overlay(alignment: .top) {
            // A zero-height line along the composer's top edge; the list hangs upward from it.
            Color.clear.frame(height: 0).overlay(alignment: .bottom) {
                if !suggestions.isEmpty {
                    MentionSuggestions(candidates: suggestions, selected: suggestionIndex, media: media,
                                       contactName: timeline.contactName) { pick($0) }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                } else if !emojiSuggestions.isEmpty {
                    EmojiSuggestions(entries: emojiSuggestions, selected: suggestionIndex) { pick(emoji: $0) }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    /// Tells the room whether you're writing: while there's text you typed in the composer
    /// (sending clears it), and not while editing an earlier message.
    private func noteTyping() {
        defer { restoredDraft = nil }
        let isWriting = editTarget == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isWriting, draft == restoredDraft { return }
        timeline.setTyping(isWriting)
    }

    // MARK: Voice messages

    private var voice: VoiceRecorder { .shared }
    /// Whether this composer is recording, and how far it has got.
    private var recordingPhase: VoiceRecorder.Phase? { voice.phase(for: draftKey) }
    /// A recording stopped here and waiting to be sent.
    private var voiceRecording: VoiceRecording? { voice.recordings[draftKey] }
    private var hasVoiceMessage: Bool { recordingPhase != nil || voiceRecording != nil }

    /// Send, Save, or with nothing to send, Record: one button, its symbol changing in place.
    private func sendButton(_ proxy: ScrollViewProxy) -> some View {
        let records = editTarget == nil && !hasVoiceMessage && !canSend
        // The microphone is a plain glyph, not a filled circle: a grey circle is how a send
        // button that can't send looks.
        let symbol = editTarget != nil ? "checkmark.circle.fill" : records ? "mic.fill" : "arrow.up.circle.fill"
        let isReady = canSend || hasVoiceMessage
        return Button {
            if hasVoiceMessage {
                sendVoice(proxy)
            } else if records {
                startRecording()
            } else {
                send(proxy)
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: records ? 17 : 24, weight: records ? .medium : .regular))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isReady ? Color.accentColor : records && isHoveringSend ? Color.primary : Color.secondary)
        .onHoverInFrontWindow { isHoveringSend = $0 }
        .disabled(editTarget != nil && !canSend || recordingPhase == .starting || recordingPhase == .finishing)
        .help(records ? "Record a voice message (⇧⌘R)"
              : hasVoiceMessage ? "Send voice message (Return). Esc to delete it."
              : editTarget == nil ? "Send (Return). Shift-Return for a new line."
              : "Save (Return). Shift-Return for a new line, Esc to cancel.")
        .accessibilityLabel(records ? "Record voice message" : hasVoiceMessage ? "Send voice message"
                            : editTarget == nil ? "Send" : "Save")
    }

    private func startRecording() {
        let key = draftKey
        Task { await voice.start(key: key) }
    }

    /// Sends the recording (stopping it first if it's still going), as a reply if one is set up.
    private func sendVoice(_ proxy: ScrollViewProxy) {
        let key = draftKey
        let replyTo = replyTarget?.eventID
        Task {
            await voice.stop(key)
            guard let recording = voice.take(key) else { return }
            if AudioPlayback.shared.currentID == VoiceRecorder.playbackID(for: recording) { AudioPlayback.shared.stop() }
            replyTarget = nil
            timeline.send([.file(recording.staged)], caption: "", replyTo: replyTo)
            scrollToBottom(proxy)
            if timeline.focusedEvent != nil { room?.returnToLive() }
        }
    }

    /// The trash button: away with it, at once.
    private func deleteVoice() {
        if recordingPhase != nil { voice.cancel() } else { voice.discard(draftKey) }
    }

    /// Escape deletes too, but a recording worth keeping (five seconds or more) is stopped and
    /// asked about first: Escape is easily pressed by mistake.
    private func escapeVoice() {
        let key = draftKey
        let length = recordingPhase != nil ? voice.elapsed : voiceRecording?.duration ?? 0
        guard length >= 5 else {
            deleteVoice()
            return
        }
        Task {
            await voice.stop(key)
            if voice.recordings[key] != nil { asksToDeleteVoice = true }
        }
    }

    private var canSend: Bool {
        if let editTarget {
            // A caption can be emptied; a message can't.
            return editTarget.kind == .caption || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !stagedImages.isEmpty || !stagedFiles.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerPlaceholder: String {
        if let editTarget { return editTarget.kind == .caption ? "Edit caption" : "Edit message" }
        return stagedImages.isEmpty && stagedFiles.isEmpty ? placeholder : "Add a caption…"
    }

    private func send(_ proxy: ScrollViewProxy) {
        if let edit = editTarget {
            saveEdit(edit)
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pictures first, then other files, each in the order it was added.
        let attachments = stagedImages.map(RoomTimeline.StagedAttachment.image)
            + stagedFiles.map(RoomTimeline.StagedAttachment.file)
        guard !text.isEmpty || !attachments.isEmpty else { return }
        let mentions = composedMentions
        let replyTo = replyTarget?.eventID
        draft = ""
        composedMentions = []
        replyTarget = nil
        stagedImages = []
        stagedFiles = []
        imageNotice = nil
        scrollToBottom(proxy)
        if attachments.isEmpty {
            Task { await timeline.send(text, mentions: mentions, replyTo: replyTo) }
        } else {
            // With attachments, what was typed is their caption.
            timeline.send(attachments, caption: text, mentions: mentions, replyTo: replyTo)
        }
        // Sent from a view of older messages: it arrives at the end of the room, so go there.
        if timeline.focusedEvent != nil { room?.returnToLive() }
    }

    // MARK: Images

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose pictures or files to send"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { attach(panel.urls) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// Readies picked, pasted or dropped images and puts them in the composer.
    private func stage(_ sources: [ImageSource]) {
        guard !sources.isEmpty else { return }
        guard editTarget == nil else {
            imageNotice = "Finish editing to attach images."
            return
        }
        imageNotice = nil
        Task {
            // If the server's size limit isn't known yet, the server itself will say so on upload.
            let limit = media.uploadLimit
            for source in sources {
                guard stagedImages.count + stagedFiles.count < Self.mostAttachmentsAtOnce else {
                    imageNotice = "Up to \(Self.mostAttachmentsAtOnce) pictures and files can be sent at once."
                    break
                }
                // Decoding and scaling can take a moment for a large photo: not on the main thread.
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try ImagePreparer.prepare(source, uploadLimit: limit) }
                }.value
                switch result {
                case .success(let image): stagedImages.append(image)
                case .failure(let error):
                    imageNotice = (error as? ImagePreparationError)?.message ?? "That image couldn’t be read."
                }
            }
            composerFocused = true
        }
    }

    /// Readies picked, dropped or pasted files and puts them in the composer: pictures as
    /// pictures (shown in the conversation), anything else as a file. A picture Huddle can't
    /// read (an SVG, say) goes as a file too.
    private func attach(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard editTarget == nil else {
            imageNotice = "Finish editing to attach files."
            return
        }
        imageNotice = nil
        Task {
            let limit = media.uploadLimit
            for url in urls {
                guard stagedImages.count + stagedFiles.count < Self.mostAttachmentsAtOnce else {
                    imageNotice = "Up to \(Self.mostAttachmentsAtOnce) pictures and files can be sent at once."
                    break
                }
                let isPicture = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .image) == true
                if isPicture {
                    let result = await Task.detached(priority: .userInitiated) {
                        Result { try ImagePreparer.prepare(.file(url), uploadLimit: limit) }
                    }.value
                    switch result {
                    case .success(let image):
                        stagedImages.append(image)
                        continue
                    case .failure(let error):
                        if let error = error as? ImagePreparationError, case .tooLarge = error {
                            imageNotice = error.message
                            continue
                        }
                        // Not one Huddle can draw: send it as a file.
                    }
                }
                do {
                    stagedFiles.append(try await FilePreparer.prepare(url, uploadLimit: limit))
                } catch {
                    imageNotice = (error as? FilePreparationError)?.message ?? "“\(url.lastPathComponent)” couldn’t be read."
                }
            }
            composerFocused = true
        }
    }

    // MARK: Replies

    private func startReply(to message: MessageRow) {
        guard let target = ReplyPreview(replyingTo: message, contactName: timeline.contactName) else { return }
        if editTarget != nil { finishEdit() }
        replyTarget = target
        composerFocused = true
    }

    /// Goes to the message a reply answers and lights it up, loading older history if it isn't
    /// on screen yet.
    private func showOriginal(_ reply: ReplyPreview, _ proxy: ScrollViewProxy) {
        jump(to: reply.eventID, proxy)
    }

    /// Goes to a message and lights it up. In the room, one that isn't loaded opens in a view
    /// of its own, around it: loading the room's history up to a message far back would be
    /// slow, and leave every later moment in the room slow too. A thread is short enough to
    /// page back through.
    private func jump(to eventID: String, _ proxy: ScrollViewProxy) {
        if let row = timeline.rows.first(where: { $0.eventID == eventID }) {
            if drawRow(row.id) {
                DispatchQueue.main.async { show(row.id, proxy) }
            } else {
                show(row.id, proxy)
            }
            return
        }
        if let room {
            if timeline.focusedEvent != nil, room.live.rows.contains(where: { $0.eventID == eventID }) {
                // Recent enough to be in the room as it is now: back there, to it.
                room.live.requestedJump = eventID
                room.returnToLive()
            } else {
                room.focus(eventID)
            }
            return
        }
        guard searchingFor == nil else { return }
        searchingFor = eventID
        searchTask = Task {
            let rowID = await timeline.rowID(forEvent: eventID)
            searchingFor = nil
            guard !Task.isCancelled else { return }
            guard let rowID else {
                // Too far back, or not something the server will give us.
                if !DevHooks.mutesAudio { NSSound.beep() }
                return
            }
            if drawRow(rowID) {
                DispatchQueue.main.async { show(rowID, proxy) }
            } else {
                show(rowID, proxy)
            }
        }
    }

    /// Scrolls to a row and lights it up for a moment.
    private func show(_ rowID: String, _ proxy: ScrollViewProxy, animated: Bool = true) {
        // Leaving the newest message on purpose: don't follow it back, and don't let a held
        // reading place pull the view back to where it was.
        followsNewest = false
        place.heldRow = nil
        showingRowUntil = Date().addingTimeInterval(0.6)
        viewWillMove(for: 0.7)
        if animated {
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(rowID, anchor: .center)
                highlightedRow = rowID
            }
        } else {
            jump(proxy, to: rowID, anchor: .center)
            withAnimation(.easeOut(duration: 0.2)) { highlightedRow = rowID }
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if highlightedRow == rowID {
                withAnimation(.easeOut(duration: 0.6)) { highlightedRow = nil }
            }
        }
    }

    // MARK: Editing

    /// Puts a message in the composer to be changed. Whatever was being written is set aside
    /// and comes back when the edit is saved or cancelled.
    private func startEdit(_ message: MessageRow) {
        guard let kind = message.editKind,
              let original = ReplyPreview(replyingTo: message, contactName: timeline.contactName) else { return }
        if editTarget == nil {
            stashedDraft = StashedDraft(text: draft, mentions: composedMentions, reply: replyTarget, images: stagedImages,
                                        files: stagedFiles)
            followedBeforeEdit = followsNewest
        }
        let restored = kind == .text
            ? MentionComposer.draft(body: message.editableText, html: message.html, mentionsRoom: message.mentionsRoom,
                                    contactName: timeline.contactName)
            : (text: message.editableText, mentions: [])
        draft = restored.text
        composedMentions = restored.mentions
        replyTarget = nil
        stagedImages = []
        stagedFiles = []
        imageNotice = nil
        dismissedQuery = nil
        editTarget = EditTarget(itemID: message.itemID, kind: kind, text: restored.text, original: original)
        composerFocused = true
    }

    private func saveEdit(_ edit: EditTarget) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard edit.kind == .caption || !text.isEmpty else { return }
        let mentions = composedMentions
        finishEdit()
        guard text != edit.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        Task { await timeline.edit(edit.itemID, kind: edit.kind, to: text, mentions: mentions) }
    }

    /// Where this composer's unsent message is kept: the room, or the thread in it.
    private var draftKey: String {
        timeline.threadRoot.map { "\(timeline.roomID)|\($0)" } ?? timeline.roomID
    }

    /// What was being written here before going elsewhere, back in the composer.
    private func restoreDraft() {
        guard draft.isEmpty, stagedImages.isEmpty, stagedFiles.isEmpty,
              let saved = account?.draft(for: draftKey) else { return }
        restoredDraft = saved.text
        draft = saved.text
        composedMentions = saved.mentions
        replyTarget = saved.reply
        stagedImages = saved.images
        stagedFiles = saved.files
    }

    /// The cursor at the end of what's in the composer, with nothing selected.
    private func cursorToEnd() {
        guard let editor = (NSApp.keyWindow ?? MainWindow.window)?.firstResponder as? NSTextView,
              editor.isEditable, editor.string == draft else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// Keeps what is being written here (while editing, what was set aside for it).
    private func keepDraft() {
        guard let account else { return }
        let current = editTarget != nil ? stashedDraft
            : StashedDraft(text: draft, mentions: composedMentions, reply: replyTarget,
                           images: stagedImages, files: stagedFiles)
        account.keepDraft(current, for: draftKey)
    }

    /// Leaves editing and puts back what was being written before.
    private func finishEdit() {
        let stash = stashedDraft
        stashedDraft = StashedDraft()
        editTarget = nil
        if followedBeforeEdit { returnsToNewest = true }
        followedBeforeEdit = false
        draft = stash.text
        restoredDraft = stash.text
        composedMentions = stash.mentions
        replyTarget = stash.reply
        stagedImages = stash.images
        stagedFiles = stash.files
    }

    /// Up arrow: moves through suggestions; in an empty composer, edits your last message.
    private func upArrow() -> KeyPress.Result {
        if suggestionCount > 0 { return moveSuggestion(-1) }
        guard draft.isEmpty, editTarget == nil, stagedImages.isEmpty, stagedFiles.isEmpty,
              let message = timeline.rows.reversed().lazy.compactMap(\.message)
                .first(where: { $0.isOwn && ($0.editKind == .text || $0.editKind == .emote) })
        else { return .ignored }
        startEdit(message)
        return .handled
    }

    // MARK: Deleting and forwarding

    private func askToDelete(_ message: MessageRow) {
        if message.sendState != nil {
            // Never reached anyone: nothing to confirm.
            Task { await timeline.discard(message.itemID) }
        } else {
            pendingDeletion = message
        }
    }

    private func startForward(_ message: MessageRow) {
        guard let preview = ReplyPreview(replyingTo: message, contactName: timeline.contactName),
              let content = timeline.forwardableContent(for: message.itemID) else {
            if !DevHooks.mutesAudio { NSSound.beep() }
            return
        }
        forwarding = ForwardRequest(preview: preview, content: content)
    }

    // MARK: New thread replies

    /// Replies to threads you haven't seen. A reply to an old thread shows only under its root
    /// message, which may be far back or not loaded at all; this says there is one, and opens
    /// it (or the list of threads, for several).
    @ViewBuilder private var newThreadReplies: some View {
        if let room, timeline.threadRoot == nil {
            let threads = room.live.newThreads
            ZStack {
                if !threads.isEmpty {
                    NewThreadRepliesPill(threads: threads) {
                        if threads.count == 1, let open = onOpenThread {
                            open(threads[0].id)
                        } else {
                            room.showThreads?()
                        }
                    }
                    .padding(.top, 10)
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: threads.isEmpty)
        }
    }

    // MARK: Pinned messages

    /// The pinned messages that have loaded, most recently pinned first.
    private var pinnedMessages: [MessageRow] {
        guard let pins = room?.pins else { return [] }
        var byID: [String: MessageRow] = [:]
        for case let message? in pins.rows.map(\.message) {
            if let id = message.eventID { byID[id] = message }
        }
        return pins.pinnedEventIDs.reversed().compactMap { byID[$0] }
    }

    @ViewBuilder private func pinnedBanner(_ proxy: ScrollViewProxy) -> some View {
        let messages = pinnedMessages
        if let room, !messages.isEmpty {
            let index = min(room.pinIndex.wrappedValue, messages.count - 1)
            PinnedBanner(messages: messages, index: index, contactName: timeline.contactName, showAll: room.showPinned) {
                guard let eventID = messages[index].eventID else { return }
                // The next click goes on to the one pinned before it.
                withAnimation(.snappy(duration: 0.3)) { room.pinIndex.wrappedValue = (index + 1) % messages.count }
                jump(to: eventID, proxy)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Mentions

    /// What follows an "@" at the end of the draft, while a mention is being typed.
    private var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex, !draft[draft.index(before: at)].isWhitespace { return nil }
        let query = draft[draft.index(after: at)...]
        return query.contains(where: \.isWhitespace) ? nil : String(query)
    }

    private var suggestions: [MentionCandidate] {
        guard let query = mentionQuery, "@" + query != dismissedQuery else { return [] }
        let needle = query.lowercased()
        var starts: [MentionCandidate] = []
        var contains: [MentionCandidate] = []
        for member in timeline.members + [.room] {
            // By their own name, their user ID, or the user's name for them (ContactNames.swift).
            let names = [member.name, member.id.matrixLocalpart, timeline.contactName(member.id)]
                .compactMap { $0?.lowercased() }
            if needle.isEmpty || names.contains(where: { $0.hasPrefix(needle) }) {
                starts.append(member)
            } else if names.contains(where: { $0.contains(needle) }) {
                contains.append(member)
            }
        }
        return Array((starts + contains).prefix(6))
    }

    private func moveSuggestion(_ step: Int) -> KeyPress.Result {
        let count = suggestionCount
        guard count > 0 else { return .ignored }
        suggestionIndex = (suggestionIndex + step + count) % count
        return .handled
    }

    /// A line break where the cursor is, put in by the field's own editor as Option-Return's is,
    /// so the field grows and the text stays where it was typed.
    private func insertLineBreak() -> KeyPress.Result {
        // The window the key went to: the key window, while Huddle is the app in front.
        let window = NSApp.currentEvent?.window ?? NSApp.keyWindow
        guard let editor = window?.firstResponder as? NSTextView else { return .ignored }
        editor.insertNewlineIgnoringFieldEditor(nil)
        return .handled
    }

    private func pickSelectedSuggestion() -> KeyPress.Result {
        let people = suggestions
        if !people.isEmpty {
            pick(people[min(suggestionIndex, people.count - 1)])
            return .handled
        }
        let emoji = emojiSuggestions
        guard !emoji.isEmpty else { return .ignored }
        pick(emoji: emoji[min(suggestionIndex, emoji.count - 1)])
        return .handled
    }

    private func pick(_ candidate: MentionCandidate) {
        guard let at = draft.lastIndex(of: "@") else { return }
        let mention = ComposedMention(candidate, contactName: candidate.isRoom ? nil : timeline.contactName(candidate.id))
        draft.replaceSubrange(at..., with: mention.label + " ")
        if !composedMentions.contains(mention) { composedMentions.append(mention) }
        composerFocused = true
    }

    // MARK: Emoji by name

    /// What follows a ":" at the end of the draft while an emoji is being typed by name (":thu"):
    /// two characters at least, the colon at the start or after something other than a letter or
    /// digit, so a time ("10:30") or a link ("https://") isn't taken for one.
    private var emojiQuery: String? {
        guard let colon = draft.lastIndex(of: ":"), Self.opensShortcode(draft, at: colon) else { return nil }
        let query = draft[draft.index(after: colon)...]
        guard query.count >= 2, query.allSatisfy(Self.isShortcodeCharacter) else { return nil }
        return String(query)
    }

    private static func isShortcodeCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "+" || character == "-"
    }

    /// Whether the colon at `colon` can start a shortcode: at the start, or after anything but a
    /// letter or digit (a space, punctuation, another emoji).
    private static func opensShortcode(_ text: some StringProtocol, at colon: String.Index) -> Bool {
        guard colon > text.startIndex else { return true }
        let before = text[text.index(before: colon)]
        return !(before.isLetter || before.isNumber)
    }

    /// The suggestions being typed for, as `dismissedQuery` keeps them: "@name" or ":name".
    private var activeQuery: String? {
        mentionQuery.map { "@" + $0 } ?? emojiQuery.map { ":" + $0 }
    }

    private var emojiSuggestions: [EmojiCatalog.Entry] {
        guard mentionQuery == nil, let query = emojiQuery, ":" + query != dismissedQuery else { return [] }
        return EmojiCatalog.search(query, limit: 6)
    }

    /// How many suggestions are showing: people for an "@", or emoji for a ":".
    private var suggestionCount: Int {
        let people = suggestions.count
        return people > 0 ? people : emojiSuggestions.count
    }

    private func pick(emoji entry: EmojiCatalog.Entry) {
        guard let colon = draft.lastIndex(of: ":") else { return }
        draft.replaceSubrange(colon..., with: entry.emoji)
        EmojiCatalog.noteUse(of: entry.emoji)
        composerFocused = true
    }

    /// A shortcode closed with its colon as it's typed (":tada:", ":fire:") becomes its emoji,
    /// as in Slack. Only as the closing colon is typed at the end: a message being edited, or
    /// text pasted, keeps what it says.
    private func completeShortcode(from old: String, to new: String) {
        guard new.count == old.count + 1, new.hasPrefix(old), new.hasSuffix(":") else { return }
        let body = new.dropLast()
        guard let colon = body.lastIndex(of: ":"), Self.opensShortcode(body, at: colon) else { return }
        let code = body[body.index(after: colon)...]
        guard !code.isEmpty, code.allSatisfy(Self.isShortcodeCharacter),
              let emoji = EmojiCatalog.emoji(forShortcode: String(code)) else { return }
        draft = String(body[..<colon]) + emoji
        EmojiCatalog.noteUse(of: emoji)
    }
}

private struct RepliesDivider: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(count == 0 ? "No replies yet" : count == 1 ? "1 reply" : "\(count) replies")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack { Divider() }
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }
}

private struct TimelineRowView: View, Equatable {
    /// Drawn again only when what it shows has changed. The closures in `actions` are made anew
    /// each time the timeline is drawn (on every keystroke in the composer, for one) but always
    /// do the same, and closures can't be compared: counted, they would redraw every message on
    /// every keystroke. Settings and names reach the message directly, and still redraw it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.isHighlighted == rhs.isHighlighted && lhs.editingItem == rhs.editingItem
            && lhs.searchingFor == rhs.searchingFor && lhs.receipts == rhs.receipts
            && lhs.timeline === rhs.timeline && lhs.media === rhs.media
            && (lhs.actions.openThread == nil) == (rhs.actions.openThread == nil)
    }

    let row: TimelineRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let actions: MessageActions
    let isHighlighted: Bool
    /// The message being edited in the composer, if any.
    let editingItem: EventOrTransactionId?
    let searchingFor: String?
    let receipts: Namespace.ID

    var body: some View {
        switch row.kind {
        case .message(let message):
            MessageView(rowID: row.id, message: message, timeline: timeline, media: media, actions: actions,
                        isHighlighted: isHighlighted, isBeingEdited: editingItem == message.itemID,
                        searchingFor: searchingFor, receipts: receipts)
        case .notice(let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        case .dateDivider(let date):
            Text(date.dayLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 14)
                .padding(.bottom, 6)
        case .readMarker:
            HStack(spacing: 8) {
                VStack { Divider() }
                Text("New")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct MessageView: View {
    /// The timeline row it is, which names it to the conversation's hover state.
    let rowID: String
    let message: MessageRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let actions: MessageActions
    /// Lit up briefly after being jumped to from a reply.
    let isHighlighted: Bool
    /// Tinted while its text is in the composer being edited.
    let isBeingEdited: Bool
    let searchingFor: String?
    let receipts: Namespace.ID

    /// Opens this message's thread, when it can have one from here.
    private var openThread: (() -> Void)? {
        guard let onOpenThread = actions.openThread, let eventID = message.eventID else { return nil }
        return { onOpenThread(eventID) }
    }

    /// A picture or file, which shows how its upload is going rather than fading while it goes.
    private var isImage: Bool {
        switch message.body {
        case .image, .file: return true
        default: return false
        }
    }

    /// Starts a reply to this message. Nil for one that hasn't been sent yet or was deleted.
    private var reply: (() -> Void)? {
        guard message.eventID != nil, message.body != .redacted else { return nil }
        return { actions.reply(message) }
    }
    /// Which message shows its actions: this one, while the pointer is on it or its action bar.
    @Environment(\.messageHover) private var hover
    @State private var showsPicker = false
    /// The emoji picker of the add-reaction chip after the reactions.
    @State private var showsReactionPicker = false
    /// True while the "More" menu is open, which keeps the actions up under it.
    @State private var isMenuOpen = false
    /// The bubble layout: where the bubble and what hangs under it sit in the row, how wide the
    /// row is, and how wide the hover actions are, to put the actions beside the bubble.
    @State private var bubbleFrame = CGRect.zero
    @State private var bubbleRowWidth: CGFloat = 0
    @State private var bubbleActionsWidth: CGFloat = 86
    @State private var receiptsWidth: CGFloat = 0
    private static let bubbleRowSpace = "bubbleRow"
    @Environment(\.messageLayout) private var layout
    @Environment(\.emojiSize) private var emojiSize
    @Environment(\.ircNameWidth) private var nameWidth
    @Environment(\.timelineWidth) private var timelineWidth
    @Environment(\.bubblesOnContentBackground) private var onContentBackground

    /// What is left for the message itself once the margins, the read-receipt gutter and the
    /// avatar (or, in the IRC layout, the time and name columns) have taken theirs.
    private var contentWidth: CGFloat {
        guard timelineWidth > 0 else { return .infinity }
        // Bubbles keep their read receipts beside them, not in a gutter.
        let available = timelineWidth - 32 - (layout == .bubbles ? 0 : ReceiptView.gutter)
        switch layout {
        case .modern:
            return max(120, available - 32 - 10)
        case .irc:
            return max(120, available - IRCNameColumn.leading - nameWidth - 8)
        case .bubbles:
            // A bubble takes at most four fifths of the width, and no more than reads well.
            let avatar = bubbleShowsSender ? Bubble.avatarSize + Bubble.avatarGap : 0
            let bubble = min((available - avatar) * 0.8, 620)
            return max(120, bubble - Bubble.tailWidth - Bubble.textInset.leading - Bubble.textInset.trailing)
        }
    }

    /// The bubble layout: others' messages carry their avatar and name, in rooms of more than two.
    private var bubbleShowsSender: Bool { !message.isOwn && !timeline.isOneToOne }

    /// The action bar stays up while an emoji picker of this message's is open, even with the
    /// pointer elsewhere.
    private var showsActions: Bool {
        // Not under the image viewer: the pointer that opened it is still over this message,
        // and no "left" arrives once the viewer is in the way.
        (hover.row(rowID).isActive || showsPicker || showsReactionPicker || isMenuOpen || isDevHovered)
            && message.sendState == nil
            && ImageViewerState.shared.item == nil
    }

    private var isDevHovered: Bool {
        guard let wanted = DevHooks.hoverText, case .text(let text) = message.body else { return false }
        return text == wanted.trimmingCharacters(in: ["!"])
    }

    var body: some View {
        Group {
            switch layout {
            case .modern: modernRow
            case .bubbles: bubbleRow
            case .irc: ircRow
            }
        }
        .environment(\.messageContentWidth, contentWidth)
        // A gutter on the right for read receipts, so they never sit on top of the text. Bubbles
        // keep theirs beside each bubble instead, so yours reach the margin as others' do.
        .padding(.trailing, layout == .bubbles ? 0 : ReceiptView.gutter)
        .padding(.top, topPadding)
        .padding(.bottom, layout == .bubbles ? 1 : 3)
        .opacity(message.sendState != nil && message.sendState != .failed && !isImage ? 0.55 : 1)
        // The whole row is the message, gaps and all. Set here, before the action bar goes on,
        // so the half of the bar that sits over the message above is this message's too: there
        // the pointer is still on this message, and the bar's buttons take clicks.
        .contentShape(Rectangle())
        .background {
            if isBeingEdited {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.1))
                    .padding(.horizontal, -8)
                    .padding(.top, layout == .modern && message.showsHeader ? 4 : 0)
                    .transition(.opacity)
            }
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(.horizontal, -8)
                    .padding(.top, layout == .modern && message.showsHeader ? 4 : 0)
                    .transition(.opacity)
            }
            // Ties the floating actions to the message they act on. Not in the bubble layout,
            // where they sit beside the bubble itself.
            if showsActions, layout != .bubbles {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .padding(.horizontal, -8)
                    // The row's own padding is the breathing room around the text. A row that
                    // starts a group has extra space above its avatar, so trim that side.
                    .padding(.top, layout == .modern && message.showsHeader ? 4 : 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if layout != .bubbles {
                ReceiptView(message: message, media: media, space: receipts)
                    .padding(.bottom, 3)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Bubbles have theirs beside the bubble.
            if showsActions, layout != .bubbles {
                actionBar
                    // Rides the top edge of the row, to the left of the receipts column so it
                    // covers neither this message's read receipts nor the previous one's.
                    .offset(x: -ReceiptView.gutter, y: actionBarOffset)
            }
        }
        .onAppear {
            if isDevHovered, DevHooks.hoverText?.hasSuffix("!") == true { showsPicker = true }
        }
        .onDisappear { hover.forget(rowID) }
        .onHover { hover.pointer(isOver: $0, message: rowID) }
        .modifier(MessageActionsMenus(sections: menuSections(includingReplies: true)))
        .animation(.easeOut(duration: 0.15), value: isBeingEdited)
    }

    /// How tall the hover bar is: its buttons and the padding around them.
    private static let actionBarHeight: CGFloat = 32

    /// The hover bar's foot sits just inside the row, above its first line (the name, where a
    /// run of one person's messages starts, or else the text): on the message before rather
    /// than over the one it's for, and still overlapping the row, so the pointer can go from
    /// one to the other.
    private var actionBarOffset: CGFloat { topPadding + 1 - Self.actionBarHeight }

    /// Space above the message: more where a run of one person's messages starts.
    private var topPadding: CGFloat {
        switch layout {
        case .modern: message.showsHeader ? 9 : 3
        case .bubbles: message.showsHeader ? 8 : 1
        case .irc: 3
        }
    }

    // MARK: Menus

    /// Everything that can be done to this message, in groups: answering it, changing it,
    /// passing it on, and deleting it. The hover bar has its own buttons for answering, so its
    /// "More" menu leaves those out.
    private func menuSections(includingReplies: Bool, includingThread: Bool? = nil) -> [[MessageMenuItem]] {
        var respond: [MessageMenuItem] = []
        if includingReplies, let reply { respond.append(.init("Reply", action: reply)) }
        if includingThread ?? includingReplies, let openThread {
            respond.append(.init(message.thread == nil ? "Reply in Thread" : "Open Thread", action: openThread))
        }

        var change: [MessageMenuItem] = []
        if let kind = message.editKind {
            let title = kind != .caption ? "Edit" : message.editableText.isEmpty ? "Add Caption" : "Edit Caption"
            change.append(.init(title) { actions.edit(message) })
        }
        if timeline.permissions.canPin, !timeline.isPinnedList, let eventID = message.eventID,
           message.body != .redacted {
            change.append(.init(message.isPinned ? "Unpin" : "Pin") {
                Task { await timeline.setPinned(!message.isPinned, eventID: eventID) }
            })
        }

        var share: [MessageMenuItem] = []
        if message.canForward { share.append(.init("Forward…") { actions.forward(message) }) }
        switch message.body {
        case .text(let text), .emote(let text):
            share.append(.init("Copy Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            })
        case .image(let image) where message.sendState == nil:
            share.append(.init("Open") { actions.openImage(image, nil) })
            share.append(.init("Copy Image") {
                Task {
                    if let data = try? await media.imageFile(source: image.media.source) { ImagePasteboard.copy(data) }
                }
            })
            share.append(.init("Save Image As…") { AttachmentSaver.save(image, media: media) })
        case .audio(let audio) where message.sendState == nil && audio.localURL == nil:
            share.append(.init("Save Audio As…") { AttachmentSaver.save(audio, media: media) })
        case .file(let file) where message.sendState == nil && file.media != nil:
            share.append(.init(file.openTitle) { Task { try? await media.open(file) } })
            if file.isVideo {
                share.append(.init("Copy Video") { Task { try? await media.copy(file) } })
            }
            share.append(.init(file.isVideo ? "Save Video As…" : "Save File As…") {
                AttachmentSaver.save(file, media: media)
            })
        default:
            break
        }

        var remove: [MessageMenuItem] = []
        if canDelete { remove.append(.init(message.isOwn ? "Delete…" : "Remove…") { actions.delete(message) }) }

        return [respond, change, share, remove].filter { !$0.isEmpty }
    }

    /// Your own messages, if the room lets you; anyone's, if you are a moderator here.
    private var canDelete: Bool {
        guard message.body != .redacted, !timeline.isPinnedList else { return false }
        if message.sendState != nil { return message.isOwn }
        guard message.eventID != nil else { return false }
        return message.isOwn ? timeline.permissions.canDeleteOwn : timeline.permissions.canDeleteOthers
    }

    private var modernRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.showsHeader {
                AvatarView(media: media,
                           url: message.senderAvatarURL,
                           name: message.senderName,
                           seed: message.sender,
                           size: 32)
            } else {
                Color.clear.frame(width: 32, height: 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                if message.showsHeader {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message.senderName)
                            .fontWeight(.semibold)
                            .foregroundStyle(NameColors.shared.color(for: message.sender, inRoom: timeline.roomID))
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if message.isPinned { PinnedMark() }
                    }
                }
                content
            }
            Spacer(minLength: 0)
        }
    }

    /// Time, sender, text on one line, with the names in a column so the text lines up.
    private var ircRow: some View {
        // Time and name share a baseline with each other, and sit at the top of the message. The
        // name is set in the body's own size, so against text its baseline matches the first
        // line; against a picture or an audio player, which have no baseline, it marks the top.
        // A message of large emoji is one line of text all the same: time and name sit on its
        // baseline, as they would beside ordinary text, rather than up at the top of the tall line.
        HStack(alignment: isLargeEmoji && message.replyTo == nil ? .firstTextBaseline : .top, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
                Text(message.senderName)
                    .fontWeight(.semibold)
                    .foregroundStyle(NameColors.shared.color(for: message.sender, inRoom: timeline.roomID))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: nameWidth, alignment: .trailing)
                    .help(message.sender)
            }
            VStack(alignment: .leading, spacing: 3) { content }
            Spacer(minLength: 0)
        }
    }

    /// The message itself with what hangs under it; for the modern and IRC layouts.
    @ViewBuilder private var content: some View {
        // In the modern layout a message that starts a group says so beside its time.
        if message.isPinned, !(layout == .modern && message.showsHeader) {
            PinnedMark()
        }
        replyQuote
        bodyView
        underneath
    }

    @ViewBuilder private var replyQuote: some View {
        if let reply = message.replyTo {
            ReplyQuoteView(reply: reply, isSearching: searchingFor == reply.eventID) {
                actions.showOriginal(reply)
            }
        }
    }

    /// What hangs under a message: a doubt about its sender, reactions, its thread, and why it
    /// wasn't sent.
    @ViewBuilder private var underneath: some View {
        if let shield = message.shield {
            ShieldNote(shield: shield)
        }
        if !message.reactions.isEmpty {
            // Another reaction, from right where the others are, as Slack has it: shown while
            // the message is hovered, so quiet messages stay uncluttered. On the open side of
            // the reactions, so they stay put as it comes and goes: after them, except under a
            // bubble of yours, whose reactions line up on the right.
            let addsFirst = layout == .bubbles && message.isOwn
            HStack(spacing: 4) {
                if addsFirst, showsActions { addReactionChip }
                ForEach(message.reactions) { reaction in
                    ReactionChipView(reaction: reaction, names: reactorNames(reaction)) {
                        Task { await timeline.toggleReaction(reaction.key, on: message.itemID) }
                    }
                }
                if !addsFirst, showsActions { addReactionChip }
            }
        }
        if let thread = message.thread, let openThread {
            ThreadChip(thread: thread, media: media, action: openThread)
        }
        if message.sendState == .failed {
            HStack(spacing: 8) {
                Label(message.sendFailure.map { "Not sent: \($0)" } ?? "Not sent", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await timeline.retry(message.itemID) } }
                    .buttonStyle(.link)
                Button("Delete") { Task { await timeline.discard(message.itemID) } }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    /// The reactions you've made to this message.
    private var ownReactions: [String] { message.reactions.filter(\.isOwn).map(\.key) }

    private var addReactionChip: some View {
        AddReactionChip { showsReactionPicker = true }
            .popover(isPresented: $showsReactionPicker, arrowEdge: .bottom) {
                // The same picker as the hover actions' add-reaction button.
                QuickReactionPicker(reacted: ownReactions) { emoji in
                    showsReactionPicker = false
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                }
            }
    }

    // MARK: Bubbles

    /// Yours on the right, others' on the left, each person's run of messages hugging together,
    /// the time said over the first after a pause.
    private var bubbleRow: some View {
        let side: HorizontalAlignment = message.isOwn ? .trailing : .leading
        return VStack(alignment: side, spacing: 3) {
            if message.startsAfterPause {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 5)
            }
            if message.showsHeader, bubbleShowsSender {
                Text(message.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NameColors.shared.color(for: message.sender, inRoom: timeline.roomID))
                    .padding(.leading, Bubble.avatarSize + Bubble.avatarGap + Bubble.tailWidth + Bubble.textInset.leading)
            }
            HStack(alignment: .bubbleFoot, spacing: Bubble.avatarGap) {
                if message.isOwn { Spacer(minLength: 56) }
                if bubbleShowsSender {
                    if message.endsRun {
                        AvatarView(media: media, url: message.senderAvatarURL, name: message.senderName,
                                   seed: message.sender, size: Bubble.avatarSize)
                    } else {
                        Color.clear.frame(width: Bubble.avatarSize, height: 1)
                    }
                }
                WidthCap(maxWidth: contentWidth + Bubble.tailWidth + Bubble.textInset.leading + Bubble.textInset.trailing) {
                    VStack(alignment: side, spacing: 3) {
                        if message.isPinned {
                            PinnedMark().padding(bubbleSide, Bubble.tailWidth + Bubble.textInset.leading)
                        }
                        bubbleBody
                            .alignmentGuide(.bubbleFoot) { $0[.bottom] }
                            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(Self.bubbleRowSpace)) }) { bubbleFrame = $0 }
                            // Read receipts and ticks beside the bubble's foot, on its open side:
                            // taking no room, they move from message to message without
                            // shifting anything.
                            .overlay(alignment: message.isOwn ? .bottomLeading : .bottomTrailing) {
                                ReceiptView(message: message, media: media, space: receipts)
                                    .fixedSize()
                                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { receiptsWidth = $0 }
                                    // Just outside the bubble's edge, either side. (From the
                                    // width: a guide set first would move the other.)
                                    .alignmentGuide(.leading) { $0.width + 6 }
                                    .alignmentGuide(.trailing) { _ in -6 }
                                    .padding(.bottom, 1)
                            }
                            .overlay(alignment: message.isOwn ? .leading : .trailing) {
                                if showsActions { bubbleActions }
                            }
                        underneath
                            .padding(bubbleSide, Bubble.tailWidth)
                    }
                }
                if !message.isOwn { Spacer(minLength: 56) }
            }
            .coordinateSpace(.named(Self.bubbleRowSpace))
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { bubbleRowWidth = $0 }
        }
    }

    /// The hover actions of the bubble layout: react, reply and more, small and round, beside
    /// the bubble on its open side and centred on it, past its read receipts. Where a wide
    /// bubble leaves no room for them there, they move in as far as they must and sit on its
    /// top edge, over the space above the text.
    private var bubbleActions: some View {
        let gap: CGFloat = 8
        // From the bubble's open edge outwards: the receipts, then the actions.
        let beyondReceipts = receiptsWidth > 0 ? gap + receiptsWidth : 0
        let room = message.isOwn ? bubbleFrame.minX : bubbleRowWidth - bubbleFrame.maxX
        let fits = room >= beyondReceipts + gap + bubbleActionsWidth
        let outwards = fits ? beyondReceipts + gap + bubbleActionsWidth : room
        return HStack(spacing: 4) {
            if message.isOwn {
                moreButton
                replyButton
                reactButton
            } else {
                reactButton
                replyButton
                moreButton
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { bubbleActionsWidth = $0 }
        .offset(x: message.isOwn ? -outwards : outwards,
                y: fits ? 0 : -(bubbleFrame.height / 2 + 13 - Bubble.textInset.top + 1))
        // Nothing until the row has been measured, rather than a moment on top of the bubble.
        .opacity(bubbleRowWidth > 0 ? 1 : 0)
        .onHover { hover.pointer(isOverBar: $0, of: rowID) }
        .onDisappear { hover.pointer(isOverBar: false, of: rowID) }
    }

    private var reactButton: some View {
        RoundActionButton(help: "Add Reaction") { showsPicker = true } label: { AddReactionIcon() }
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                QuickReactionPicker(reacted: ownReactions) { emoji in
                    showsPicker = false
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                }
            }
    }

    @ViewBuilder private var replyButton: some View {
        if let reply {
            RoundActionButton(help: "Reply", action: reply) { Image(systemName: "arrowshape.turn.up.left") }
        }
    }

    @ViewBuilder private var moreButton: some View {
        // Reply has its own button; the thread is in here.
        if !menuSections(includingReplies: false, includingThread: true).isEmpty {
            MoreActionsButton(sections: { menuSections(includingReplies: false, includingThread: true) },
                              isOpen: $isMenuOpen, isRound: true)
        }
    }

    /// The sender's side, where the tail goes.
    private var bubbleSide: Edge.Set { message.isOwn ? .trailing : .leading }

    /// The message in its bubble. Pictures, files, voice messages and big emoji stand on their
    /// own, a caption in a bubble under them.
    @ViewBuilder private var bubbleBody: some View {
        let side: HorizontalAlignment = message.isOwn ? .trailing : .leading
        switch message.body {
        case .text where isLargeEmoji:
            VStack(alignment: side, spacing: 3) {
                replyQuote
                bodyView
            }
            .padding(bubbleSide, Bubble.tailWidth)
            .help(message.date.formatted(date: .abbreviated, time: .shortened))
        case .image(let image):
            VStack(alignment: side, spacing: 3) {
                replyQuote.padding(bubbleSide, Bubble.tailWidth)
                ImageMessageView(image: image, media: media, sendState: message.sendState,
                                 uploadProgress: message.uploadProgress,
                                 localPreview: message.localPreview,
                                 open: { actions.openImage(image, $0) },
                                 cancelUpload: message.sendState == nil ? nil : {
                                     Task { await timeline.discard(message.itemID) }
                                 })
                    .padding(bubbleSide, Bubble.tailWidth)
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                if let caption = image.caption {
                    bubbled { (Text(styled(caption)) + editedLabel).textSelection(.enabled) }
                }
            }
        case .file(let file):
            VStack(alignment: side, spacing: 3) {
                replyQuote.padding(bubbleSide, Bubble.tailWidth)
                attachedFile(file)
                    .padding(bubbleSide, Bubble.tailWidth)
                    .help(message.date.formatted(date: .abbreviated, time: .shortened))
                if let caption = file.caption {
                    bubbled { (Text(styled(caption)) + editedLabel).textSelection(.enabled) }
                }
            }
        case .audio(let audio):
            VStack(alignment: side, spacing: 3) {
                replyQuote.padding(bubbleSide, Bubble.tailWidth)
                bubbled {
                    AudioMessageView(id: message.eventID ?? audio.media.source.url(), audio: audio,
                                     media: media, owner: timeline)
                    if let caption = audio.caption {
                        (Text(caption.linkified) + editedLabel).textSelection(.enabled)
                    }
                }
            }
        case .attachment:
            // Already a box of its own.
            VStack(alignment: side, spacing: 3) {
                replyQuote
                bodyView
            }
            .padding(bubbleSide, Bubble.tailWidth)
        default:
            bubbled {
                replyQuote
                bodyView
            }
        }
    }

    /// Text in a bubble of the sender's colour, its tail on the last of a run.
    private func bubbled<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) { content() }
            .padding(Bubble.textInset)
            .padding(bubbleSide, Bubble.tailWidth)
            .background {
                BubbleShape(isOwn: message.isOwn, joinsAbove: !message.showsHeader, joinsBelow: !message.endsRun)
                    .fill(message.isOwn ? Bubble.own : onContentBackground ? Bubble.othersOnContent : Bubble.others)
            }
            .help(message.date.formatted(date: .abbreviated, time: .shortened))
    }

    /// The narrowest timeline whose bar has room for six quick reactions: the bar sits left of the
    /// receipts, and six (about 300 points with the rest of the bar) in less would cover the
    /// start of the message, its sender's name and time.
    private static let sixOnBarWidth: CGFloat = 540

    /// The quick reactions on the bar: as many as Settings says, but three where six won't fit
    /// (a thread beside the conversation, say).
    private var barReactions: [String] {
        let reactions = QuickReactions.shared.onBar
        guard reactions.count > 3, timelineWidth > 0, timelineWidth < Self.sixOnBarWidth else { return reactions }
        return Array(reactions.prefix(3))
    }

    private var actionBar: some View {
        HStack(spacing: 1) {
            ForEach(barReactions, id: \.self) { emoji in
                ActionButton(help: "React with \(emoji)") {
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                } label: {
                    Text(emoji).font(.system(size: 15))
                }
                // In place of the message's own menu, as a toolbar's buttons offer to customize it.
                .contextMenu { CustomizeQuickReactionsButton() }
            }
            ActionButton(help: "Add Reaction") {
                showsPicker = true
            } label: {
                AddReactionIcon()
            }
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                // All six on top, any not on the bar among them.
                QuickReactionPicker(reacted: ownReactions) { emoji in
                    showsPicker = false
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                }
            }
            Divider().frame(height: 16).padding(.horizontal, 3)
            if let reply {
                ActionButton(help: "Reply", action: reply) {
                    Image(systemName: "arrowshape.turn.up.left")
                }
            }
            if let openThread {
                ActionButton(help: "Reply in Thread", action: openThread) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
            }
            if !menuSections(includingReplies: false).isEmpty {
                MoreActionsButton(sections: { menuSections(includingReplies: false) }, isOpen: $isMenuOpen)
            }
        }
        .padding(3)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        // On the bar, the pointer stays with this message, even over the message above.
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover.pointer(isOverBar: $0, of: rowID) }
        .onDisappear { hover.pointer(isOverBar: false, of: rowID) }
    }

    /// The people behind a reaction, by name, with "You" for this account and first.
    private func reactorNames(_ reaction: MessageRow.ReactionChip) -> [String] {
        let others = reaction.senders.filter { $0 != timeline.ownUserID }
            .map { timeline.knownName(for: $0) ?? $0.matrixLocalpart }
        return reaction.isOwn ? ["You"] + others : others
    }

    /// The message with its formatting, links and mention pills.
    private func styled(_ text: String) -> AttributedString {
        MessageFormatter.renderCached(text: text, html: message.html, mentionsRoom: message.mentionsRoom,
                                      ownUserID: timeline.ownUserID, names: timeline.nameVersion,
                                      name: timeline.knownName(for:))
    }

    /// Whether this is a message of nothing but a few emoji, drawn large.
    private var isLargeEmoji: Bool {
        guard emojiSize.pointSize != nil, case .text(let text) = message.body else { return false }
        return Emoji.isLargeOnly(text)
    }

    /// " (edited)" after a message that has been changed since it was sent.
    private var editedLabel: Text {
        Text(message.isEdited ? " (edited)" : "").font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var bodyView: some View {
        switch message.body {
        case .text(let text) where isLargeEmoji:
            // Nothing but a few emoji: drawn large, as Settings asks.
            (Text(text).font(.system(size: emojiSize.pointSize ?? 30)) + editedLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 1)
        case .text(let text):
            (Text(styled(text)) + editedLabel)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .emote(let text):
            (Text("* \(message.senderName) ") + Text(styled(text)) + editedLabel)
                .italic()
                .textSelection(.enabled)
        case .image(let image):
            VStack(alignment: .leading, spacing: 4) {
                ImageMessageView(image: image, media: media, sendState: message.sendState,
                                 uploadProgress: message.uploadProgress,
                                 localPreview: message.localPreview,
                                 open: { actions.openImage(image, $0) },
                                 cancelUpload: message.sendState == nil ? nil : {
                                     Task { await timeline.discard(message.itemID) }
                                 })
                    .padding(.vertical, 3)
                if let caption = image.caption {
                    (Text(styled(caption)) + editedLabel).textSelection(.enabled)
                }
            }
        case .file(let file):
            VStack(alignment: .leading, spacing: 4) {
                attachedFile(file)
                if let caption = file.caption {
                    (Text(styled(caption)) + editedLabel).textSelection(.enabled)
                }
            }
            .padding(.vertical, 3)
        case .audio(let audio):
            VStack(alignment: .leading, spacing: 4) {
                AudioMessageView(id: message.eventID ?? audio.media.source.url(), audio: audio,
                                 media: media, owner: timeline)
                if let caption = audio.caption {
                    (Text(caption.linkified) + editedLabel).textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        case .attachment(let icon, let name):
            Label(name, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .undecryptable(let reason):
            // Waiting for keys that may yet come, or never to be read, and why.
            Label(reason ?? "Waiting for encryption keys", systemImage: reason == nil ? "lock" : "lock.slash")
                .foregroundStyle(.secondary)
        case .redacted:
            Label("Message deleted", systemImage: "trash")
                .foregroundStyle(.secondary)
        case .unsupported(let text):
            Text(text)
                .foregroundStyle(.secondary)
        }
    }
}

/// People matching the "@…" being typed, listed above the composer.
/// Emoji for a name typed after a colon, above the composer as people are for an "@": each with
/// its name, and its shortcode where it has a well-known one.
private struct EmojiSuggestions: View {
    let entries: [EmojiCatalog.Entry]
    let selected: Int
    let onPick: (EmojiCatalog.Entry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                Button { onPick(entry) } label: {
                    HStack(spacing: 8) {
                        Text(entry.emoji)
                            .font(.system(size: 17))
                            .frame(width: 22, height: 22)
                        Text(entry.name.prefix(1).uppercased() + entry.name.dropFirst())
                            .fontWeight(.medium)
                            .lineLimit(1)
                        if let code = EmojiCatalog.shortcode(for: entry.emoji) {
                            Text(":\(code):")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == selected ? Color.accentColor.opacity(0.22) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(entry.emoji) \(entry.name)")
            }
        }
        .padding(4)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

private struct MentionSuggestions: View {
    let candidates: [MentionCandidate]
    let selected: Int
    let media: MediaLoader
    /// The user's own name for someone: shown, with their own name beside their ID, which is
    /// what the mention sends.
    var contactName: (String) -> String? = { _ in nil }
    let onPick: (MentionCandidate) -> Void

    private func title(of candidate: MentionCandidate) -> String {
        candidate.isRoom ? "@room" : contactName(candidate.id) ?? candidate.name
    }

    private func detail(of candidate: MentionCandidate) -> String {
        if candidate.isRoom { return "Notify everyone in the room" }
        guard contactName(candidate.id) != nil else { return candidate.id }
        return "\(candidate.name) · \(candidate.id)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                Button { onPick(candidate) } label: {
                    HStack(spacing: 8) {
                        if candidate.isRoom {
                            Image(systemName: "person.3.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(.quaternary, in: Circle())
                        } else {
                            AvatarView(media: media, url: candidate.avatarURL, name: title(of: candidate),
                                       seed: candidate.id, size: 22)
                        }
                        Text(title(of: candidate))
                            .fontWeight(.medium)
                        Text(detail(of: candidate))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(index == selected ? Color.accentColor.opacity(0.22) : .clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }
}

/// One reaction under a message: the emoji and how many chose it. Yours are drawn in the accent
/// colour, filled and outlined, so they stand apart from other people's at a glance. Clicking
/// adds or takes back your own.
private struct ReactionChipView: View {
    let reaction: MessageRow.ReactionChip
    /// Who reacted, "You" first if you did.
    let names: [String]
    let toggle: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(reaction.key)
                    .font(.system(size: 14))
                Text("\(reaction.count)")
                    .font(.system(size: 12, weight: reaction.isOwn ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(reaction.isOwn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
            }
            .padding(.leading, 7)
            .padding(.trailing, 8)
            .frame(height: 24)
            .background(fill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(stroke, lineWidth: reaction.isOwn ? 1.2 : 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help(summary)
        .accessibilityLabel("\(reaction.key), \(reaction.count)")
        .accessibilityValue(summary)
        .accessibilityHint(reaction.isOwn ? "Removes your reaction" : "Adds your reaction")
        .accessibilityAddTraits(reaction.isOwn ? .isSelected : [])
    }

    private var fill: Color {
        reaction.isOwn
            ? Color.accentColor.opacity(isHovering ? 0.26 : 0.17)
            : Color.primary.opacity(isHovering ? 0.11 : 0.06)
    }

    private var stroke: Color {
        reaction.isOwn ? Color.accentColor.opacity(0.85) : Color.primary.opacity(isHovering ? 0.18 : 0.1)
    }

    /// "You and Bob reacted with 👍", "Bob, Carol and 3 others reacted with 🎉".
    private var summary: String {
        let shown = names.count > 4 ? Array(names.prefix(3)) + ["\(names.count - 3) others"] : names
        let who = shown.isEmpty ? "\(reaction.count) people" : shown.formatted(.list(type: .and))
        return "\(who) reacted with \(reaction.key)"
    }
}

/// After a message's reactions, while it is hovered: a chip like theirs that adds another.
private struct AddReactionChip: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            AddReactionIcon()
                .foregroundStyle(.secondary)
                // Centred by eye: the plus stands out past the face's top right.
                .offset(x: -1, y: 1)
                .frame(width: 36, height: 24)
                .background(Color.primary.opacity(isHovering ? 0.11 : 0.06), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.1), lineWidth: 0.5)
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help("Add Reaction")
        .accessibilityLabel("Add Reaction")
    }
}

/// A smiling face with a plus at its top right: the icon chat apps use for adding a reaction.
/// SF Symbols has none, so it is drawn the way SF Symbols draws its badges, the plus standing in
/// a gap cut out of the face, which stays a gap over any background.
struct AddReactionIcon: View {
    /// The cut-out disc the plus stands in, and where its centre sits off the face's top right.
    private static let badge: CGFloat = 9
    private static let shift: CGFloat = 3

    /// SF Symbols' smiling face as it is drawn in light mode, an outline, to be tinted like the
    /// bar's other icons. In dark mode the symbol comes filled in, a grey disc beside the
    /// outlined arrow and bubbles.
    private static let face: NSImage = {
        guard let symbol = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        else { return NSImage() }
        let outline = NSImage(size: symbol.size, flipped: false) { rect in
            NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { symbol.draw(in: rect) }
            return true
        }
        outline.isTemplate = true
        return outline
    }()

    var body: some View {
        Image(nsImage: Self.face)
            .mask {
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                    Circle()
                        .frame(width: Self.badge, height: Self.badge)
                        .offset(x: Self.shift, y: -Self.shift)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: "plus")
                    .font(.system(size: 7, weight: .bold))
                    .frame(width: Self.badge, height: Self.badge)
                    .offset(x: Self.shift, y: -Self.shift)
            }
            .accessibilityHidden(true)
    }
}

/// One button in a message's floating action bar.
struct ActionButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 26)
                .background(isHovering ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help(help)
        // Its icon says nothing to VoiceOver; what it does, as the tooltip has it, does.
        .accessibilityLabel(help)
    }
}

/// What sits at the right of a message: who has read up to it (group rooms), or how far your
/// own message has got (one grey tick while sending, two grey when sent, two coloured when read).
private struct ReceiptView: View {
    static let gutter: CGFloat = 64
    private static let maxAvatars = 3

    let message: MessageRow
    let media: MediaLoader
    let space: Namespace.ID
    @State private var showsReaders = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            // When someone reads further, their avatar glides down from the message they had
            // read to the new one; a newcomer pops in, and the ticks fill in.
            .animation(reduceMotion ? .easeOut(duration: 0.2) : Motion.receipt, value: message.readers.map(\.id))
            .animation(.easeOut(duration: 0.3 * Motion.slowdown), value: message.delivery)
    }

    @ViewBuilder private var content: some View {
        if !message.readers.isEmpty {
            Button {
                showsReaders = true
            } label: {
                HStack(spacing: 3) {
                    if message.readers.count > Self.maxAvatars {
                        Text("+\(message.readers.count - Self.maxAvatars)")
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .transition(.opacity)
                    }
                    HStack(spacing: -4) {
                        ForEach(message.readers.prefix(Self.maxAvatars).reversed()) { reader in
                            AvatarView(media: media, url: reader.avatarURL, name: reader.name, seed: reader.id, size: 16)
                                .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
                                .matchedGeometryEffect(id: reader.id, in: space, isSource: true)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Read by " + message.readers.map(\.name).formatted(.list(type: .and)))
            .popover(isPresented: $showsReaders, arrowEdge: .trailing) {
                ReadersList(readers: message.readers, media: media)
            }
        } else if let delivery = message.delivery {
            DeliveryMark(delivery: delivery, readDate: message.readDate,
                         readDateIsExact: message.readDateIsExact)
        }
    }
}

/// Notes when the user last scrolled (wheel or trackpad, the scroller, paging keys), to
/// tell their scrolling apart from the content moving by itself.
@MainActor
/// Notices the reader scrolling the conversation: only input aimed at it counts. Scrolling the
/// room list, or the small drag in the click that opened the room, would otherwise pass for
/// the reader scrolling away while the room's messages are still arriving, and the room would
/// open short of its newest message.
private final class ScrollInputTracker {
    private var monitor: Any?
    private var lastInput = Date.distantPast
    /// What it was, for the log.
    private(set) var lastKind = ""
    /// Whether it went toward the newest message (scrolling down, Page Down, End): that can't
    /// take the reader away from the end, so the view keeps following it as rows grow meanwhile.
    private(set) var wentTowardNewest = false

    /// The reader moved the view recently, away from the end or not knowing which way: a drag of
    /// the scroll bar, scrolling up, Page Up, Home.
    var leftRecently: Bool { isRecent && !wentTowardNewest }
    /// A view covering the conversation, where input has to be to count.
    weak var area: NSView?
    /// Whether the mouse went down in the conversation: its drags are the reader's.
    private var dragStartedInside = false

    var isRecent: Bool { DevHooks.freeScroll || Date().timeIntervalSince(lastInput) < 0.6 }

    /// Whether the reader has scrolled (or dragged, or paged) since then.
    func hasInput(since date: Date) -> Bool { lastInput > date }

    func start() {
        guard monitor == nil else { return }
        // Clicks themselves aren't scrolling: a click on a button (a message's actions, the
        // composer's) counted would take the composer growing under it for the user scrolling away.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { [weak self] event in
            self?.note(event)
            return event
        }
    }

    private func note(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragStartedInside = isInside(event)
        case .leftMouseDragged:
            if dragStartedInside { counts("drag") }
        case .scrollWheel:
            // Only what moves the conversation up or down. A trackpad also sends scroll events
            // that move nothing: fingers touching down or lifting, momentum ending. Counted, they
            // made pictures growing as a room opened look like the reader scrolling away.
            if event.scrollingDeltaY != 0, isInside(event) {
                counts("scroll", towardNewest: event.scrollingDeltaY < 0)
            }
        case .keyDown:
            // Page Up, Page Down, Home, End, with the conversation (or its composer) focused.
            // Other keys are typing; in the room list these scroll the list.
            if [116, 121, 115, 119].contains(event.keyCode), focusIsInside(event.window) {
                counts("key", towardNewest: [121, 119].contains(event.keyCode))
            }
        default:
            break
        }
    }

    private func counts(_ kind: String, towardNewest: Bool = false) {
        lastInput = Date()
        lastKind = kind
        wentTowardNewest = towardNewest
        onInput?()
    }

    /// Told of each bit of the reader's scrolling.
    var onInput: (() -> Void)?

    private func isInside(_ event: NSEvent) -> Bool {
        guard let area, let window = area.window else { return false }
        let location: NSPoint
        if let eventWindow = event.window {
            guard eventWindow === window else { return false }
            location = event.locationInWindow
        } else {
            // An event with no window has its location on the screen.
            location = window.convertPoint(fromScreen: event.locationInWindow)
        }
        return area.bounds.contains(area.convert(location, from: nil))
    }

    private func focusIsInside(_ window: NSWindow?) -> Bool {
        guard let area, let window, window === area.window, let responder = window.firstResponder as? NSView else {
            return false
        }
        return area.bounds.intersects(area.convert(responder.bounds, from: responder))
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The edge between the IRC layout's names and messages, all the way down the conversation:
/// dragged, it makes the names' column wider or narrower (this room's, remembered for it);
/// double-clicked, it fits the column to the longest name. A line marks it while the pointer is
/// on it, with the resizing pointer.
private struct NameColumnHandle: View {
    static let width: CGFloat = 9

    let width: CGFloat
    @Binding var dragged: CGFloat?
    let fitted: () -> CGFloat
    let commit: (CGFloat) -> Void
    @State private var isHovering = false
    @State private var dragStart: CGFloat?
    @State private var cursorShown = false

    private var isActive: Bool { isHovering || dragStart != nil }

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .overlay {
                Rectangle()
                    .fill(Color.accentColor.opacity(dragStart != nil ? 0.8 : 0.5))
                    .frame(width: 1)
                    .opacity(isActive ? 1 : 0)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                updateCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        dragged = IRCNameColumn.clamped(start + value.translation.width)
                        updateCursor()
                    }
                    .onEnded { _ in
                        let final = dragged ?? width
                        dragStart = nil
                        dragged = nil
                        commit(final)
                        updateCursor()
                    }
            )
            .onTapGesture(count: 2) { commit(fitted()) }
            .onDisappear {
                if cursorShown { NSCursor.pop() }
                cursorShown = false
            }
            .help("Drag to resize the names. Double-click to fit the longest name.")
            // A slider, to VoiceOver: the width, changed in steps.
            .accessibilityRepresentation {
                Slider(value: Binding(get: { Double(width) }, set: { commit(IRCNameColumn.clamped(CGFloat($0))) }),
                       in: Double(IRCNameColumn.widths.lowerBound)...Double(IRCNameColumn.widths.upperBound),
                       step: 8) {
                    Text("Names column width")
                }
                .accessibilityValue("\(Int(width)) points")
                .accessibilityAction(named: "Fit to Longest Name") { commit(fitted()) }
            }
    }

    /// The resizing pointer while on the edge or dragging it; pushed and popped in pairs so the
    /// pointer underneath comes back as it was.
    private func updateCursor() {
        let wanted = isHovering || dragStart != nil
        guard wanted != cursorShown else { return }
        cursorShown = wanted
        if wanted { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
    }
}

/// Counts the view's own scrolls. Many in a moment means something keeps moving the content
/// and the view keeps going after it: noted in the log (once a minute at most), with what it
/// was doing, as that keeps the whole app busy.
private final class JumpCounter {
    private var times: [CFTimeInterval] = []
    private var lastNoted: CFTimeInterval = 0

    func count(rowsDrawn: Int, follows: Bool, atBottom: Bool) {
        let now = CACurrentMediaTime()
        times.append(now)
        times.removeAll { now - $0 > 2 }
        guard times.count > 20, now - lastNoted > 60 else { return }
        lastNoted = now
        TimelineLog.log.notice("Scrolled itself \(self.times.count, privacy: .public) times in 2 s: \(rowsDrawn, privacy: .public) rows drawn, following newest \(follows, privacy: .public), newest on screen \(atBottom, privacy: .public)")
    }
}

/// Hands the reading place AppKit's scroll view, from inside the scroll content.
private struct ScrollViewProbe: NSViewRepresentable {
    let place: ReadingPlace

    func makeNSView(context: Context) -> NSView { Probe(place: place) }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class Probe: NSView {
        let place: ReadingPlace
        init(place: ReadingPlace) {
            self.place = place
            super.init(frame: .zero)
        }
        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scrollView = enclosingScrollView { place.scrollView = scrollView }
        }
    }
}

/// Hands the tracker a view covering the conversation.
private struct InputArea: NSViewRepresentable {
    let tracker: ScrollInputTracker

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        tracker.area = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        tracker.area = view
    }
}

/// One grey tick while sending, two grey once the server has it, two coloured once read.
private struct DeliveryMark: View {
    let delivery: MessageRow.Delivery
    var readDate: Date?
    var readDateIsExact = false

    var body: some View {
        ZStack(alignment: .leading) {
            Image(systemName: "checkmark")
            if delivery != .sending {
                Image(systemName: "checkmark")
                    .offset(x: 5)
                    .transition(.scale(scale: 0.4, anchor: .leading).combined(with: .opacity))
            }
        }
        // Same width in every state, so the first tick doesn't shift when the second appears.
        .padding(.trailing, 5)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(delivery == .read ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
        .help(label)
        .accessibilityLabel(label)
    }

    /// The message's own time is already shown beside the sender, so this adds only what isn't:
    /// the state, and when it was read if that is actually known.
    private var label: String {
        switch delivery {
        case .sending:
            return "Sending…"
        case .sent:
            return "Sent"
        case .read:
            // A receipt marks only the last message someone read. Earlier messages are known to
            // be read, but not when, so they get no time.
            if let readDate, readDateIsExact {
                return "Read \(Self.describe(readDate))"
            }
            return "Read"
        }
    }

    private static func describe(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today at \(time)" }
        if calendar.isDateInYesterday(date) { return "yesterday at \(time)" }
        return "\(date.formatted(date: .abbreviated, time: .omitted)) at \(time)"
    }
}

private struct ReadersList: View {
    let readers: [MessageRow.Reader]
    let media: MediaLoader

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Read by")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(readers) { reader in
                HStack(spacing: 8) {
                    AvatarView(media: media, url: reader.avatarURL, name: reader.name, seed: reader.id, size: 22)
                    Text(reader.name)
                        .lineLimit(1)
                    Spacer(minLength: 16)
                    if let date = reader.date {
                        Text(date.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 220)
    }
}

/// "3 replies · Last reply 2 hours ago" under a message, Slack style. Opens the thread.
private struct ThreadChip: View {
    let thread: ThreadInfo
    let media: MediaLoader
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let sender = thread.latestSender {
                    AvatarView(media: media,
                               url: thread.latestSenderAvatarURL,
                               name: thread.latestSenderName ?? sender,
                               seed: sender,
                               size: 18)
                }
                Text(thread.replyCount == 1 ? "1 reply" : "\(thread.replyCount) replies")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                if thread.hasNewReplies {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 7, height: 7)
                    Text("New replies")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                } else if isHovering {
                    Text("View thread")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let date = thread.latestDate {
                    Text("Last reply \(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            .padding(.trailing, 22)
            .padding(.vertical, 4)
            .frame(maxWidth: 340, alignment: .leading)
            .overlay(alignment: .trailing) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .padding(.trailing, 8)
            }
            .background(isHovering ? AnyShapeStyle(.background) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.separator.opacity(isHovering ? 1 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .padding(.leading, -6)
        .padding(.top, 1)
    }
}

extension String {
    /// Plain text with URLs turned into clickable links.
    var linkified: AttributedString {
        var result = AttributedString(self)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        for match in detector.matches(in: self, range: NSRange(startIndex..., in: self)) {
            guard let url = match.url,
                  let range = Range(match.range, in: self),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

private extension Date {
    /// "Today", "Yesterday", or the full date.
    var dayLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "Today" }
        if calendar.isDateInYesterday(self) { return "Yesterday" }
        return formatted(date: .complete, time: .omitted)
    }
}

/// Timings shared by the timeline's small animations.
enum Motion {
    /// The Dev build can slow every animation down, to look at one frame by frame.
    static let slowdown: Double = AppEnvironment.isDev
        ? max(1, ProcessInfo.processInfo.environment["HUDDLE_DEV_SLOW_ANIMATIONS"].flatMap(Double.init) ?? 1) : 1

    /// A reader's avatar moving on: unhurried, settling without a bounce.
    static let receipt = Animation.spring(duration: 0.45, bounce: 0.12).speed(1 / slowdown)

    /// The thread panel arriving: a soft spring that decelerates into place, no overshoot.
    static let panelIn = Animation.spring(duration: 0.42, bounce: 0.04).speed(1 / slowdown)
    /// Leaving is a touch quicker than arriving, as things get out of the way.
    static let panelOut = Animation.spring(duration: 0.32, bounce: 0).speed(1 / slowdown)
    /// The panel's content settling, a beat after the panel itself.
    static let panelContent = Animation.spring(duration: 0.5, bounce: 0).delay(0.06).speed(1 / slowdown)
    /// Moving between the thread list and a thread inside the panel.
    static let panelPush = Animation.spring(duration: 0.36, bounce: 0).speed(1 / slowdown)
}

/// Lays its content out at a given width while taking up only the width it is offered:
/// content that is wider runs on past the edge (where the scroll view cuts it off), narrower
/// content leaves a space beside it. A plain frame would grow to fit wider content, and the
/// conversation would push the closing thread panel out of the window.
private struct LaidOutAtWidth: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        FixedWidthLayout(width: width) { content }
    }

    private struct FixedWidthLayout: Layout {
        let width: CGFloat?

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let child = subviews.first else { return .zero }
            let size = child.sizeThatFits(ProposedViewSize(width: width ?? proposal.width, height: proposal.height))
            let offered = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            return CGSize(width: offered ?? size.width, height: size.height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                                  proposal: ProposedViewSize(width: width ?? bounds.width, height: bounds.height))
        }
    }
}

/// Holds the newest message in place while the content changes height, within the same
/// layout pass that changes it (macOS 15 and later). Otherwise the timeline only scrolls back
/// to it afterwards, and for a moment the conversation dips and comes back.
private struct NewestMessageHold: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.defaultScrollAnchor(isOn ? .bottom : nil, for: .sizeChanges)
        } else {
            content
        }
    }
}

/// Where each row on screen sits, measured from the top of the visible area. Not observed:
/// it changes on every scroll and is only read when the width changes.
@MainActor
final class ReadingPlace {
    var rows: [String: CGRect?] = [:]
    /// AppKit's scroll view under SwiftUI's (ScrollViewProbe). SwiftUI's measures of where the
    /// view is come from SwiftUI's own record of it, and the two can come apart: right after a
    /// room's first rows arrive, SwiftUI can take its jump to the end as done while AppKit's
    /// view stays short of it, every measure then saying the end is in view.
    weak var scrollView: NSScrollView?

    /// How far AppKit's view is from the end, in points, by its own content and insets (the
    /// composer's at the foot); nil without it.
    var scrollViewShortOfEnd: CGFloat? {
        guard let scrollView, let document = scrollView.documentView, document.isFlipped else { return nil }
        let clip = scrollView.contentView
        return endOrigin(of: clip).y - clip.bounds.origin.y
    }

    /// Scrolls AppKit's view to the end, as the reader dragging it there would.
    func scrollViewToEnd() {
        guard let scrollView, scrollView.documentView?.isFlipped == true else { return }
        let clip = scrollView.contentView
        clip.scroll(to: endOrigin(of: clip))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where the view's top sits with the end in view: the content's height, less what shows,
    /// plus the inset the composer takes at the foot.
    private func endOrigin(of clip: NSClipView) -> NSPoint {
        let height = scrollView?.documentView?.frame.height ?? 0
        let insets = scrollView?.contentInsets ?? NSEdgeInsetsZero
        return NSPoint(x: clip.bounds.origin.x, y: max(-insets.top, height - clip.bounds.height + insets.bottom))
    }
    /// The pending look at whether the newest message ended up in view; see `settleOnNewest`.
    var settleCheck: DispatchWorkItem?
    var viewport: CGFloat = 0
    /// What covers the top and bottom of the view: the pinned banner and the composer.
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0

    /// Whether all of a row can be seen, clear of the banner and the composer. Rows are measured
    /// from just below the banner; the composer covers the foot of what is left.
    func isFullyVisible(_ id: String) -> Bool {
        guard let frame = rows[id] ?? nil else { return false }
        return frame.minY >= -1 && frame.maxY <= viewport - topInset - bottomInset + 1
    }
    /// The row being read and where its top was, from just before the messages re-wrapped.
    var heldRow: (id: String, top: CGFloat)?
    /// The row being read and where its top is, while reading older messages and not scrolling;
    /// see `keepReadingPlace`.
    var anchor: (id: String, top: CGFloat)?
    var anchorWork: DispatchWorkItem?
    /// When the content last changed height while reading older messages.
    var contentChanged = Date.distantPast
    /// When `heldRow` was taken: the reader's own scrolling after it wins over it.
    var heldSince = Date.distantPast

    /// The row nearest the middle of the view, and where its top is.
    func middleRow(among order: [String]) -> (id: String, top: CGFloat)? {
        let middle = viewport / 2
        var best: (id: String, top: CGFloat, distance: CGFloat)?
        for id in order {
            guard let frame = rows[id] ?? nil else { continue }
            let distance = abs(frame.midY - middle)
            if best == nil || distance < best!.distance { best = (id, frame.minY, distance) }
        }
        return best.map { ($0.id, $0.top) }
    }
}

/// A message being edited in the composer.
struct EditTarget: Equatable {
    let itemID: EventOrTransactionId
    let kind: MessageRow.EditKind
    /// The text the edit started from, as it was put in the composer.
    let text: String
    /// The message as it was, for the bar above the composer.
    let original: ReplyPreview
}

/// What the composer held when an edit began.
struct StashedDraft {
    var text = ""
    var mentions: [ComposedMention] = []
    var reply: ReplyPreview?
    var images: [StagedImage] = []
    var files: [StagedFile] = []
}

/// A message on its way to other rooms: what it looks like, and what to send.
struct ForwardRequest: Identifiable {
    let id = UUID()
    let preview: ReplyPreview
    let content: RoomMessageEventContentWithoutRelation
}

/// A message's actions as its context menu, and the same for VoiceOver, which can't reach the
/// hover bar or the context menu. One list, worked out once each time the row is drawn.
///
/// The VoiceOver actions only while VoiceOver is on: every row carrying its own accessibility
/// actions makes a room noticeably slower to open, for nobody's benefit otherwise.
private struct MessageActionsMenus: ViewModifier {
    let sections: [[MessageMenuItem]]
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverIsOn

    func body(content: Content) -> some View {
        let menu = content.contextMenu { MessageContextMenu(sections: sections) }
        if voiceOverIsOn || DevHooks.accessibilityActions {
            menu
                .accessibilityElement(children: .contain)
                .accessibilityActions {
                    ForEach(sections.flatMap { $0 }) { item in
                        Button(item.title.replacingOccurrences(of: "…", with: ""), action: item.action)
                    }
                }
        } else {
            menu
        }
    }
}

/// What a room's main conversation shares beyond its own timeline.
struct RoomContext {
    /// The room's live timeline; a view around an older message stands in for it for a while.
    let live: RoomTimeline
    /// The room's pinned messages, while it has any.
    let pins: RoomTimeline?
    /// Which pinned message the banner shows; kept by the room, so it carries on across views.
    let pinIndex: Binding<Int>
    let showPinned: () -> Void
    /// Shows a message that isn't loaded, in a view of its own around it.
    let focus: (String) -> Void
    /// Back to the room as it is now.
    let returnToLive: () -> Void
    /// Whether the room has been marked unread while it is open.
    var isMarkedUnread = false
    let markRead: () -> Void
    /// Opens the room's details beside it.
    var showInfo: (() -> Void)?
    /// Opens the list of the room's threads beside it.
    var showThreads: (() -> Void)?
}

/// Over the top of the conversation while threads have replies you haven't seen: who replied
/// and to what, or how many threads, for several. Styled as Jump to Latest is.
private struct NewThreadRepliesPill: View {
    let threads: [ThreadListEntry]
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .foregroundStyle(Color.accentColor)
                Text(title)
                    .layoutPriority(1)
                if threads.count == 1 {
                    Text(threads[0].preview)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 240, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(.separator) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(threads.count == 1 ? "Open the thread" : "Show the room’s threads")
        .accessibilityLabel(threads.count == 1 ? "\(title): \(threads[0].preview)" : title)
    }

    private var title: String {
        guard threads.count == 1 else { return "New replies in \(threads.count) threads" }
        return "\(threads[0].latestReplierName ?? "Someone") replied in a thread"
    }
}

/// Along the top of a room the user has marked unread while in it: what that means, and the
/// way back. Without it the only sign is a dot in the room list, easily missed, and nothing
/// says why read receipts have stopped going out for messages plainly on screen.
private struct MarkedUnreadBar: View {
    let markRead: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
            Text("Marked as unread")
                .fontWeight(.semibold)
                .layoutPriority(1)
            Text("Read receipts are paused until you come back to it.")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button("Mark as Read", action: markRead)
                .controlSize(.small)
                .help("Mark this room read (⇧⌘U)")
        }
        .font(.callout)
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(Color.accentColor.opacity(0.08))
        .background(.bar)
        .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Mark as Read", markRead)
    }
}

extension MessageView {
    /// A file sent in a message: a video macOS can play, played in place, or a tile to open.
    @ViewBuilder func attachedFile(_ file: FileAttachment) -> some View {
        let cancel: (() -> Void)? = message.sendState == nil ? nil : {
            Task { await timeline.discard(message.itemID) }
        }
        if let video = file.video, file.isPlayableVideo, file.media != nil || video.localURL != nil {
            VideoMessageView(id: message.eventID ?? file.media?.source.url() ?? file.filename, file: file,
                             video: video, media: media, owner: timeline, sendState: message.sendState,
                             uploadProgress: message.uploadProgress, cancelUpload: cancel)
        } else {
            FileMessageView(file: file, media: media, sendState: message.sendState,
                            uploadProgress: message.uploadProgress, cancelUpload: cancel)
        }
    }
}

/// The message field's rounded box, which the recording bar and the recording waiting to be
/// sent take over in turn, one line high as the field is with one line in it.
private struct ComposerField: ViewModifier {
    /// A line of the field's text.
    static let line = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: NSFont.systemFontSize)))
    /// The field with one line in it: the line, and the padding above and below.
    static let oneLine = line + 14

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
    }
}

/// Return sends a voice message from the composer, and Escape deletes it, as they would a
/// message typed there.
private struct VoiceKeys: ViewModifier {
    let focus: FocusState<Bool>.Binding
    let send: () -> Void
    let escape: () -> Void

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused(focus)
            .onKeyPress(.return) {
                send()
                return .handled
            }
            .onKeyPress(.escape) {
                escape()
                return .handled
            }
    }
}
