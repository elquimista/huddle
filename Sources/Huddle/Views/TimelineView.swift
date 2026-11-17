import MatrixRustSDK
import QuickLook
import SwiftUI

/// A scrolling list of messages with a composer: a room's timeline, or one thread's.
struct TimelineView: View {
    let timeline: RoomTimeline
    let media: MediaLoader
    var placeholder = "Message"
    /// Opens a message's thread. Nil inside a thread, where there is nothing further to open.
    var onOpenThread: ((String) -> Void)?
    @State private var draft = ""
    /// The message being replied to, while writing a reply.
    @State private var replyTarget: ReplyPreview?
    /// The row just jumped to from a reply's quote, lit up for a moment.
    @State private var highlightedRow: String?
    /// The message being looked for after clicking a quote, while older history loads.
    @State private var searchingFor: String?
    /// Images waiting in the composer to be sent.
    @State private var stagedImages: [StagedImage] = []
    /// Something about attaching or opening an image that the user should know.
    @State private var imageNotice: String?
    @State private var isDropTarget = false
    @State private var pasteInterceptor = PasteInterceptor()
    /// The image open in the full-size viewer, as the file Quick Look is showing.
    @State private var previewURL: URL?
    /// The image being fetched to open, by its address.
    @State private var openingImage: String?
    private static let mostImagesAtOnce = 10
    /// Mentions picked from the suggestions for the message being written.
    @State private var composedMentions: [ComposedMention] = []
    @State private var suggestionIndex = 0
    /// A mention query the user closed with Escape; stays closed until they type on.
    @State private var dismissedQuery: String?
    @FocusState private var composerFocused: Bool

    /// Whether the newest message is on screen.
    @State private var isAtBottom = true
    /// The intent to stay on the newest message. Unlike `isAtBottom` it survives a batch of
    /// messages, a reload or a resize pushing the newest one out of view, so the view can follow.
    /// Only the user scrolling away ends it.
    @State private var followsNewest = true
    @State private var input = ScrollInputTracker()
    /// Whether the top of the loaded history is on screen, which is when to fetch more.
    @State private var historyEdgeVisible = false
    private static let bottomID = "timeline-bottom"

    /// Messages arriving while the app is in the background stay unread until it is back in front.
    @State private var appIsActive = NSApp.isActive || DevHooks.assumesActive

    private struct ReadTrigger: Equatable {
        let lastRow: String?
        let isAtBottom: Bool
        let appIsActive: Bool
    }

    private struct HistoryTrigger: Equatable {
        let edgeVisible: Bool
        let finishedRequests: Int
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy on purpose. A lazy stack only estimates the height of rows it hasn't
                // drawn, so scrolling to the newest message lands in the wrong place, gets
                // corrected a frame later (flicker), and sometimes leaves the view blank.
                VStack(alignment: .leading, spacing: 0) {
                    if timeline.hasMoreHistory, !timeline.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                            .padding(12)
                            .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { historyEdgeVisible = $0 }
                    }
                    ForEach(timeline.rows) { row in
                        TimelineRowView(row: row, timeline: timeline, media: media,
                                        actions: MessageActions(openThread: onOpenThread,
                                                                reply: { startReply(to: $0) },
                                                                showOriginal: { showOriginal($0, proxy) },
                                                                openImage: { openImage($0) }),
                                        isHighlighted: row.id == highlightedRow,
                                        searchingFor: searchingFor,
                                        openingImage: openingImage)
                            .id(row.id)
                        if row.id == threadRootRowID {
                            RepliesDivider(count: replyCount)
                        }
                    }
                    // The very last thing in the scroll view, with nothing below it: scrolling to it
                    // is scrolling to the end. The gap under the newest message sits above it.
                    Color.clear
                        .frame(height: 8)
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .onGeometryChange(for: Bool.self, of: Self.isOnScreen) { visible in
                            isAtBottom = visible
                            if visible {
                                followsNewest = true
                            } else if input.isRecent {
                                // The user scrolled away.
                                followsNewest = false
                            } else if followsNewest {
                                // The content moved under the view; go back to the end.
                                DispatchQueue.main.async {
                                    if followsNewest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                                }
                            }
                        }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                // Rows keep changing height after they first appear: messages decrypt, reactions
                // and thread summaries arrive, more batches load. Whenever the content's height
                // changes while following the newest message, go back to the end.
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height.rounded() }) { _ in
                    if followsNewest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                }
            }
            // A room opens at its newest message. A thread starts at its root message, so a short
            // one sits under the header; a long one is then scrolled to its newest reply.
            .defaultScrollAnchor(timeline.threadRoot == nil ? .bottom : .top)
            .onChange(of: timeline.rows.last?.id) { previousLast, _ in
                // The first content, or a new message while following the newest.
                if previousLast == nil || followsNewest { scrollToBottom(proxy) }
            }
            .onAppear {
                if !timeline.rows.isEmpty { scrollToBottom(proxy) }
            }
            // Opening or closing the side panel changes the width and re-wraps every message;
            // if the newest message was in view, keep it there once the change has finished.
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { _ in
                guard followsNewest else { return }
                scrollToBottom(proxy)
                for delay in [0.05, 0.3] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        if followsNewest { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                }
            }
            .onChange(of: timeline.prependCount) {
                // Older messages were added above. While following the newest message, stay
                // there; otherwise stay on the message being read.
                if followsNewest {
                    scrollToBottom(proxy)
                } else if let anchor = timeline.prependAnchorID {
                    proxy.scrollTo(anchor, anchor: .top)
                }
            }
            // Fetches history while its top edge is on screen, again after each request finishes.
            .task(id: HistoryTrigger(edgeVisible: historyEdgeVisible, finishedRequests: timeline.historyRequests)) {
                if historyEdgeVisible, timeline.hasMoreHistory { await timeline.loadOlder() }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom, !followsNewest, !timeline.rows.isEmpty {
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
                }
            }
            .overlay {
                if timeline.isLoading { ProgressView() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer(proxy) }
        }
        // Runs when a new message arrives and when the newest one scrolls into view.
        .task(id: ReadTrigger(lastRow: timeline.rows.last?.id, isAtBottom: isAtBottom, appIsActive: appIsActive)) {
            if isAtBottom, appIsActive, !timeline.rows.isEmpty { await timeline.markAsRead() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appIsActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appIsActive = DevHooks.assumesActive
        }
        .onAppear {
            composerFocused = true
            input.start()
            pasteInterceptor.onImages = { stage($0) }
            pasteInterceptor.start()
            _ = media.uploadLimit       // learn the server's size limit before it is needed
            if timeline.threadRoot == nil, !DevHooks.stagedImagePaths.isEmpty, !DevHooks.didStageImages {
                DevHooks.didStageImages = true
                stage(DevHooks.stagedImagePaths.map { .file(URL(fileURLWithPath: $0)) })
            }
        }
        .onChange(of: composerFocused, initial: true) { pasteInterceptor.isActive = composerFocused }
        // Images dragged anywhere over the conversation land in the composer.
        .onDrop(of: ImageDrop.types, isTargeted: $isDropTarget) { providers in
            Task { stage(await ImageDrop.sources(from: providers)) }
            return true
        }
        .overlay {
            if isDropTarget { DropTargetOverlay() }
        }
        .animation(.easeOut(duration: 0.12), value: isDropTarget)
        // The full-size viewer is Quick Look, as in Finder and Messages.
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { old, new in
            if let old, old != new { ImagePreviewFiles.remove(old) }
        }
        .onDisappear {
            input.stop()
            pasteInterceptor.stop()
            if let previewURL { ImagePreviewFiles.remove(previewURL) }
            AudioPlayback.shared.stop(owner: timeline)
            let timeline = timeline
            Task { await timeline.leave() }
        }
    }

    /// Whether a view inside the scroll view is within, or just outside, the visible area.
    private static func isOnScreen(_ geometry: GeometryProxy) -> Bool {
        guard let visible = geometry.bounds(of: .scrollView) else { return false }
        return visible.insetBy(dx: 0, dy: -24).intersects(geometry.frame(in: .local))
    }

    /// In a thread, the root message's row: replies are set off below it.
    private var threadRootRowID: String? {
        guard timeline.threadRoot != nil else { return nil }
        return timeline.rows.first(where: \.isMessage)?.id
    }

    private var replyCount: Int {
        max(timeline.rows.filter(\.isMessage).count - 1, 0)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        followsNewest = true
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }

    private func composer(_ proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = timeline.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 36)
            }
            if let imageNotice {
                Text(imageNotice)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 36)
            }
            if !stagedImages.isEmpty {
                StagedImagesRow(images: stagedImages) { image in
                    stagedImages.removeAll { $0.id == image.id }
                }
                .padding(.leading, 36)
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
                AttachButton { pickImages() }
                    .padding(.bottom, 1)
                TextField(stagedImages.isEmpty ? placeholder : "Add a caption…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($composerFocused)
                    .onSubmit { send(proxy) }
                    // While suggestions are showing, the arrows move through them and Return
                    // or Tab picks one instead of sending.
                    .onKeyPress(.upArrow) { moveSuggestion(-1) }
                    .onKeyPress(.downArrow) { moveSuggestion(1) }
                    .onKeyPress(.return) { pickSelectedSuggestion() }
                    .onKeyPress(.tab) { pickSelectedSuggestion() }
                    .onKeyPress(.escape) {
                        // Escape closes the mention list if it is open; otherwise it cancels a reply.
                        if !suggestions.isEmpty {
                            dismissedQuery = mentionQuery
                            return .handled
                        }
                        guard replyTarget != nil else { return .ignored }
                        replyTarget = nil
                        return .handled
                    }
                    .onChange(of: draft) {
                        suggestionIndex = 0
                        if mentionQuery != dismissedQuery { dismissedQuery = nil }
                        if mentionQuery != nil { Task { await timeline.loadMembers() } }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.background, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.separator) }
                Button { send(proxy) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 24))
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
                .disabled(!canSend)
                .help("Send (Return). Option-Return for a new line.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.2), value: replyTarget?.eventID)
        .animation(.snappy(duration: 0.2), value: stagedImages.map(\.id))
        .background(.bar)
        // Not Divider: inside the room's HStack it would draw itself vertically.
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 1) }
        // Floats over the messages, its bottom edge on the composer's top, so nothing moves.
        .overlay(alignment: .top) {
            // A zero-height line along the composer's top edge; the list hangs upward from it.
            Color.clear.frame(height: 0).overlay(alignment: .bottom) {
                if !suggestions.isEmpty {
                    MentionSuggestions(candidates: suggestions, selected: suggestionIndex, media: media) { pick($0) }
                        .padding(.horizontal, 14)
                        .padding(.bottom, 4)
                }
            }
        }
    }

    private var canSend: Bool {
        !stagedImages.isEmpty || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send(_ proxy: ScrollViewProxy) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = stagedImages
        guard !text.isEmpty || !images.isEmpty else { return }
        let mentions = composedMentions
        let replyTo = replyTarget?.eventID
        draft = ""
        composedMentions = []
        replyTarget = nil
        stagedImages = []
        imageNotice = nil
        scrollToBottom(proxy)
        if images.isEmpty {
            Task { await timeline.send(text, mentions: mentions, replyTo: replyTo) }
        } else {
            // With images, what was typed is their caption.
            timeline.send(images: images, caption: text, mentions: mentions, replyTo: replyTo)
        }
    }

    // MARK: Images

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Choose images to send"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK { stage(panel.urls.map(ImageSource.file)) }
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
        imageNotice = nil
        Task {
            // If the server's size limit isn't known yet, the server itself will say so on upload.
            let limit = media.uploadLimit
            for source in sources {
                guard stagedImages.count < Self.mostImagesAtOnce else {
                    imageNotice = "Up to \(Self.mostImagesAtOnce) images can be sent at once."
                    break
                }
                // Decoding and scaling can take a moment for a large photo: not on the main thread.
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try ImagePreparer.prepare(source, uploadLimit: limit) }
                }.value
                switch result {
                case .success(let image): stagedImages.append(image)
                case .failure(let error):
                    imageNotice = (error as? ImagePreparationError)?.message ?? "That image couldn't be read."
                }
            }
            composerFocused = true
        }
    }

    /// Opens an image at full size in Quick Look.
    private func openImage(_ image: ImageAttachment) {
        guard openingImage == nil else { return }
        openingImage = image.media.source.url()
        Task {
            defer { openingImage = nil }
            do {
                let data = try await media.imageFile(source: image.media.source)
                previewURL = try ImagePreviewFiles.write(data, named: image.suggestedFilename)
                imageNotice = nil
            } catch {
                imageNotice = "That image couldn't be loaded. Check your connection and try again."
            }
        }
    }

    // MARK: Replies

    private func startReply(to message: MessageRow) {
        guard let target = ReplyPreview(replyingTo: message) else { return }
        replyTarget = target
        composerFocused = true
    }

    /// Goes to the message a reply answers and lights it up, loading older history if it isn't
    /// on screen yet.
    private func showOriginal(_ reply: ReplyPreview, _ proxy: ScrollViewProxy) {
        guard searchingFor == nil else { return }
        searchingFor = reply.eventID
        Task {
            let rowID = await timeline.rowID(forEvent: reply.eventID)
            searchingFor = nil
            guard let rowID else {
                // Too far back, or not something the server will give us.
                if !DevHooks.mutesAudio { NSSound.beep() }
                return
            }
            // Leaving the newest message on purpose: don't follow it back.
            followsNewest = false
            withAnimation(.snappy(duration: 0.3)) {
                proxy.scrollTo(rowID, anchor: .center)
                highlightedRow = rowID
            }
            try? await Task.sleep(for: .seconds(1.8))
            if highlightedRow == rowID {
                withAnimation(.easeOut(duration: 0.6)) { highlightedRow = nil }
            }
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
        guard let query = mentionQuery, query != dismissedQuery else { return [] }
        let needle = query.lowercased()
        var starts: [MentionCandidate] = []
        var contains: [MentionCandidate] = []
        for member in timeline.members + [.room] {
            let name = member.name.lowercased()
            let localpart = member.id.matrixLocalpart.lowercased()
            if needle.isEmpty || name.hasPrefix(needle) || localpart.hasPrefix(needle) {
                starts.append(member)
            } else if name.contains(needle) || localpart.contains(needle) {
                contains.append(member)
            }
        }
        return Array((starts + contains).prefix(6))
    }

    private func moveSuggestion(_ step: Int) -> KeyPress.Result {
        let count = suggestions.count
        guard count > 0 else { return .ignored }
        suggestionIndex = (suggestionIndex + step + count) % count
        return .handled
    }

    private func pickSelectedSuggestion() -> KeyPress.Result {
        let current = suggestions
        guard !current.isEmpty else { return .ignored }
        pick(current[min(suggestionIndex, current.count - 1)])
        return .handled
    }

    private func pick(_ candidate: MentionCandidate) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft.replaceSubrange(at..., with: candidate.label + " ")
        let mention = ComposedMention(label: candidate.label, userID: candidate.isRoom ? nil : candidate.id)
        if !composedMentions.contains(mention) { composedMentions.append(mention) }
        composerFocused = true
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

private struct TimelineRowView: View {
    let row: TimelineRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let actions: MessageActions
    let isHighlighted: Bool
    let searchingFor: String?
    let openingImage: String?

    var body: some View {
        switch row.kind {
        case .message(let message):
            MessageView(message: message, timeline: timeline, media: media, actions: actions,
                        isHighlighted: isHighlighted, searchingFor: searchingFor, openingImage: openingImage)
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
    let message: MessageRow
    let timeline: RoomTimeline
    let media: MediaLoader
    let actions: MessageActions
    /// Lit up briefly after being jumped to from a reply.
    let isHighlighted: Bool
    let searchingFor: String?
    let openingImage: String?

    /// Opens this message's thread, when it can have one from here.
    private var openThread: (() -> Void)? {
        guard let onOpenThread = actions.openThread, let eventID = message.eventID else { return nil }
        return { onOpenThread(eventID) }
    }

    private var isImage: Bool {
        if case .image = message.body { return true }
        return false
    }

    /// Starts a reply to this message. Nil for one that hasn't been sent yet or was deleted.
    private var reply: (() -> Void)? {
        guard message.eventID != nil, message.body != .redacted else { return nil }
        return { actions.reply(message) }
    }
    @State private var isHovering = false
    @State private var showsPicker = false
    @AppStorage(MessageLayout.key) private var layout = MessageLayout.modern

    private static let quickReactions = ["👍", "❤️", "😂"]

    /// The action bar stays up while its emoji picker is open, even with the pointer elsewhere.
    private var showsActions: Bool { (isHovering || showsPicker || isDevHovered) && message.sendState == nil }

    private var isDevHovered: Bool {
        guard let wanted = DevHooks.hoverText, case .text(let text) = message.body else { return false }
        return text == wanted.trimmingCharacters(in: ["!"])
    }

    var body: some View {
        Group {
            switch layout {
            case .modern: modernRow
            case .irc: ircRow
            }
        }
        // A gutter on the right for read receipts, so they never sit on top of the text.
        .padding(.trailing, ReceiptView.gutter)
        .padding(.top, layout == .modern && message.showsHeader ? 9 : 3)
        .padding(.bottom, 3)
        .opacity(message.sendState != nil && message.sendState != .failed && !isImage ? 0.55 : 1)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.2))
                    .padding(.horizontal, -8)
                    .padding(.top, layout == .modern && message.showsHeader ? 4 : 0)
                    .transition(.opacity)
            }
            // Ties the floating actions to the message they act on.
            if showsActions {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .padding(.horizontal, -8)
                    // The row's own padding is the breathing room around the text. A row that
                    // starts a group has extra space above its avatar, so trim that side.
                    .padding(.top, layout == .modern && message.showsHeader ? 4 : 0)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            ReceiptView(message: message, media: media)
                .padding(.bottom, 3)
        }
        .overlay(alignment: .topTrailing) {
            if showsActions {
                actionBar
                    // Rides the top edge of the row, to the left of the receipts column so it
                    // covers neither this message's read receipts nor the previous one's.
                    .offset(x: -ReceiptView.gutter, y: -15)
            }
        }
        .onAppear {
            if isDevHovered, DevHooks.hoverText?.hasSuffix("!") == true { showsPicker = true }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            if let reply {
                Button("Reply", action: reply)
            }
            if let openThread {
                Button(message.thread == nil ? "Reply in Thread" : "Open Thread", action: openThread)
            }
            if case .audio(let audio) = message.body {
                Button("Save Audio As…") { AttachmentSaver.save(audio, media: media) }
            }
            if case .image(let image) = message.body, message.sendState == nil {
                Button("Open") { actions.openImage(image) }
                Button("Copy Image") {
                    Task {
                        if let data = try? await media.imageFile(source: image.media.source) { ImagePasteboard.copy(data) }
                    }
                }
                Button("Save Image As…") { AttachmentSaver.save(image, media: media) }
            }
            if case .text(let text) = message.body {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
        }
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
                            .foregroundStyle(AvatarView.color(for: message.sender))
                        Text(message.date.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
                Text(message.senderName)
                    .fontWeight(.semibold)
                    .foregroundStyle(AvatarView.color(for: message.sender))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 88, alignment: .trailing)
                    .help(message.sender)
            }
            VStack(alignment: .leading, spacing: 3) { content }
            Spacer(minLength: 0)
        }
    }

    /// The message itself with what hangs under it; shared by both layouts.
    @ViewBuilder private var content: some View {
        if let reply = message.replyTo {
            ReplyQuoteView(reply: reply, isSearching: searchingFor == reply.eventID) {
                actions.showOriginal(reply)
            }
        }
        bodyView
        if !message.reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(message.reactions) { reaction in
                    Button {
                        Task { await timeline.toggleReaction(reaction.key, on: message.itemID) }
                    } label: {
                        Text("\(reaction.key) \(reaction.count)")
                            .font(.callout)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(reaction.isOwn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.15),
                                        in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if let thread = message.thread, let openThread {
            ThreadChip(thread: thread, media: media, action: openThread)
        }
        if message.sendState == .failed {
            HStack(spacing: 8) {
                Label("Not sent", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                Button("Try Again") { Task { await timeline.retry(message.itemID) } }
                    .buttonStyle(.link)
                Button("Delete") { Task { await timeline.discard(message.itemID) } }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 1) {
            ForEach(Self.quickReactions, id: \.self) { emoji in
                ActionButton(help: "React with \(emoji)") {
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                } label: {
                    Text(emoji).font(.system(size: 15))
                }
            }
            ActionButton(help: "More reactions…") {
                showsPicker = true
            } label: {
                Image(systemName: "face.smiling")
            }
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                EmojiPicker { emoji in
                    showsPicker = false
                    Task { await timeline.toggleReaction(emoji, on: message.itemID) }
                }
            }
            if reply != nil || openThread != nil {
                Divider().frame(height: 16).padding(.horizontal, 3)
            }
            if let reply {
                ActionButton(help: "Reply", action: reply) {
                    Image(systemName: "arrowshape.turn.up.left")
                }
            }
            if let openThread {
                ActionButton(help: "Reply in thread", action: openThread) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
            }
        }
        .padding(3)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    /// The message with its formatting, links and mention pills.
    private func styled(_ text: String) -> AttributedString {
        MessageFormatter.render(text: text, html: message.html, mentionsRoom: message.mentionsRoom,
                                ownUserID: timeline.ownUserID, name: timeline.knownName(for:))
    }

    @ViewBuilder private var bodyView: some View {
        switch message.body {
        case .text(let text):
            (Text(styled(text)) + Text(message.isEdited ? " (edited)" : "").font(.caption).foregroundStyle(.secondary))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .emote(let text):
            (Text("* \(message.senderName) ") + Text(styled(text)))
                .italic()
                .textSelection(.enabled)
        case .image(let image):
            VStack(alignment: .leading, spacing: 4) {
                ImageMessageView(image: image, media: media, sendState: message.sendState,
                                 uploadProgress: message.uploadProgress,
                                 localPreview: message.localPreview,
                                 isOpening: openingImage == image.media.source.url(),
                                 open: { actions.openImage(image) },
                                 cancelUpload: message.sendState == nil ? nil : {
                                     Task { await timeline.discard(message.itemID) }
                                 })
                    .padding(.vertical, 3)
                if let caption = image.caption {
                    Text(styled(caption)).textSelection(.enabled)
                }
            }
        case .audio(let audio):
            VStack(alignment: .leading, spacing: 4) {
                AudioMessageView(id: message.eventID ?? audio.media.source.url(), audio: audio,
                                 media: media, owner: timeline)
                if let caption = audio.caption {
                    Text(caption.linkified).textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        case .attachment(let icon, let name):
            Label(name, systemImage: icon)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .undecryptable:
            Label("Waiting for encryption keys", systemImage: "lock")
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
private struct MentionSuggestions: View {
    let candidates: [MentionCandidate]
    let selected: Int
    let media: MediaLoader
    let onPick: (MentionCandidate) -> Void

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
                            AvatarView(media: media, url: candidate.avatarURL, name: candidate.name,
                                       seed: candidate.id, size: 22)
                        }
                        Text(candidate.isRoom ? "@room" : candidate.name)
                            .fontWeight(.medium)
                        Text(candidate.isRoom ? "Notify everyone in the room" : candidate.id)
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

/// One button in a message's floating action bar.
private struct ActionButton<Label: View>: View {
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
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// What sits at the right of a message: who has read up to it (group rooms), or how far your
/// own message has got (one grey tick while sending, two grey when sent, two coloured when read).
private struct ReceiptView: View {
    static let gutter: CGFloat = 64
    private static let maxAvatars = 3

    let message: MessageRow
    let media: MediaLoader
    @State private var showsReaders = false

    var body: some View {
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
                    }
                    HStack(spacing: -4) {
                        ForEach(message.readers.prefix(Self.maxAvatars).reversed()) { reader in
                            AvatarView(media: media, url: reader.avatarURL, name: reader.name, seed: reader.id, size: 16)
                                .overlay { Circle().strokeBorder(.background, lineWidth: 1.5) }
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
private final class ScrollInputTracker {
    private var monitor: Any?
    private var lastInput = Date.distantPast

    var isRecent: Bool { DevHooks.freeScroll || Date().timeIntervalSince(lastInput) < 0.6 }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .keyDown]) { [weak self] event in
            // Page Up, Page Down, Home, End. Other keys are typing.
            if event.type != .keyDown || [116, 121, 115, 119].contains(event.keyCode) {
                self?.lastInput = Date()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
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
                Image(systemName: "checkmark").offset(x: 5)
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
                    Text("Last reply \(date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
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
        .onHover { isHovering = $0 }
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
