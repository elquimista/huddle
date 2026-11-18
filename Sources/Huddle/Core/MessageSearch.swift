import Foundation
import MatrixRustSDK

/// A message found by a search, ready to show.
struct SearchHit: Identifiable, Equatable {
    var id: String { eventID }
    let roomID: String
    let eventID: String
    let sender: String
    let senderName: String
    let senderAvatarURL: String?
    let date: Date
    /// One line of plain text standing for the message.
    let text: String
    /// An SF Symbol for what the message is, when it isn't plain text.
    let icon: String?
    /// The message the room shows for this one, when known to differ: the one an edit
    /// changed, or the first message of the thread a reply is in. Nil when not known yet.
    var jumpEventID: String?

    init(roomID: String, eventID: String, sender: String, senderName: String, senderAvatarURL: String?,
         date: Date, text: String, icon: String?, jumpEventID: String? = nil) {
        self.roomID = roomID
        self.eventID = eventID
        self.sender = sender
        self.senderName = senderName
        self.senderAvatarURL = senderAvatarURL
        self.date = date
        self.text = text
        self.icon = icon
        self.jumpEventID = jumpEventID
    }

    /// From the SDK's search of this Mac's index.
    init(roomID: String, result: MessageSearchResult) {
        let senderName = result.senderProfile.name(fallback: result.sender)
        let (text, icon) = ReplyPreview.describe(result.content, senderName: senderName)
        self.init(roomID: roomID, eventID: result.eventId, sender: result.sender, senderName: senderName,
                  senderAvatarURL: result.senderProfile.avatarURL, date: Date(matrixTimestamp: result.timestamp),
                  text: text, icon: icon)
    }
}

/// Searching an account's messages, from two places at once, merged newest first:
/// - this Mac's index, kept by the SDK, which holds encrypted messages too (and, with the
///   full-history pass, every encrypted room's whole history);
/// - the homeserver's own search, which covers the whole history of unencrypted rooms
///   without anything being downloaded.
/// One search per account, so it carries on from room to room.
@MainActor @Observable
final class MessageSearch {
    enum Scope: Hashable {
        case room
        case all
    }

    var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    var scope: Scope = .room {
        didSet { if scope != oldValue { scopeChanged() } }
    }
    /// The room "This Room" means: the one whose panel the search is showing in.
    var roomID: String? {
        didSet { if roomID != oldValue, scope == .room { scopeChanged() } }
    }
    /// The result last opened, marked in the list; Find Next and Find Previous go on from it.
    var selectedEventID: String?
    /// Changed to put the cursor in the search field.
    private(set) var focusRequest = 0
    private(set) var failure: String?
    /// True from a keystroke until its search has started, so "No Results" never flashes
    /// up for a query that hasn't run yet.
    private(set) var isPending = false
    /// False once the server has said it doesn't search messages; then only this Mac's
    /// index is searched.
    private(set) var serverSearches = true

    // This Mac's index: every room's results, newest first.
    private var localHits: [SearchHit] = []
    private var localLoading = false
    private var localEnded = false
    private var localStarted = false

    // The server's: already narrowed to the scope, newest first.
    private var serverHits: [SearchHit] = []
    private var serverLoading = false
    private var serverEnded = false
    private var serverStarted = false
    @ObservationIgnored private var serverNextBatch: String?
    /// Forms of the searched-for words the server matched, to pick out in its results.
    private(set) var highlights: [String] = []
    /// Counts server searches, so a page that arrives for an earlier one is dropped.
    @ObservationIgnored private var serverGeneration = 0

    var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isSearching: Bool { !trimmedQuery.isEmpty }
    var isLoading: Bool { localLoading || serverLoading }
    var endReached: Bool { localEnded && (serverEnded || !serverSearches) }

    /// The results for the chosen scope, newest first, each message once. Only down to where
    /// both sources have got to: older ones wait until the other catches up, so that nothing
    /// it finds later lands above what is already showing.
    var shown: [SearchHit] {
        guard isSearching else { return [] }
        let local = scope == .room && roomID != nil ? localHits.filter { $0.roomID == roomID } : localHits
        var seen = Set<String>()
        // This Mac's version first: the SDK has resolved its sender and content.
        let merged = (local + serverHits)
            .filter { seen.insert($0.eventID).inserted }
            .sorted { $0.date > $1.date }
        var cutoff: Date?
        if localStarted, !localEnded, let oldest = localHits.last?.date { cutoff = oldest }
        if serverSearches, serverStarted, !serverEnded, let oldest = serverHits.last?.date {
            cutoff = max(cutoff ?? oldest, oldest)
        }
        guard let cutoff else { return merged }
        return merged.filter { $0.date >= cutoff }
    }

    @ObservationIgnored private let service: SearchService
    @ObservationIgnored private let server: ServerSearch
    @ObservationIgnored private var handles: [TaskHandle] = []
    @ObservationIgnored private var localResults: [SearchServiceResult] = []
    @ObservationIgnored private var queryTask: Task<Void, Never>?

    /// Enough results in view that the list fills the panel; more load as it scrolls.
    private static let pageTarget = 20

    init(client: Client) {
        service = client.searchService()
        server = ServerSearch(client: client)
        Task { await subscribe() }
    }

    // MARK: This Mac's index

    private func subscribe() async {
        handles.append(await service.subscribeToResults(listener: SearchResultsListener { [weak self] updates in
            Task { @MainActor in self?.applyLocal(updates) }
        }))
        handles.append(service.subscribeToPaginationStateUpdates(listener: SearchPaginationListener { [weak self] state in
            Task { @MainActor in self?.localPaginationChanged(to: state) }
        }))
    }

    private func applyLocal(_ updates: [SearchServiceResultsUpdate]) {
        for update in updates { localResults.apply(update.diff) }
        localHits = localResults.map { result in
            switch result {
            case .message(let roomID, let message): SearchHit(roomID: roomID, result: message)
            }
        }
        fillIfNeeded()
    }

    private func localPaginationChanged(to state: SearchServicePaginationState) {
        switch state {
        case .loading:
            localLoading = true
        case .idle(let end):
            localLoading = false
            localEnded = end
            if end || !localHits.isEmpty { localStarted = true }
            fillIfNeeded()
        }
    }

    // MARK: The server's

    /// Starts the server's search afresh, for the query and scope as they are now.
    private func restartServer() {
        serverGeneration += 1
        serverHits = []
        highlights = []
        serverNextBatch = nil
        serverEnded = false
        serverStarted = false
        serverLoading = false
        guard serverSearches, isSearching else { return }
        loadServerPage()
    }

    private func loadServerPage() {
        guard serverSearches, isSearching, !serverLoading, !serverEnded else { return }
        let generation = serverGeneration
        let term = trimmedQuery
        let rooms = scope == .room ? roomID.map { [$0] } : nil
        let nextBatch = serverNextBatch
        serverLoading = true
        Task {
            do {
                let page = try await server.search(term, in: rooms, from: nextBatch)
                guard generation == serverGeneration else { return }
                // One row per message: a newer version, from an edit, may have come on an
                // earlier page.
                let known = Set(serverHits.map { $0.jumpEventID ?? $0.eventID })
                serverHits += page.hits.filter { !known.contains($0.jumpEventID ?? $0.eventID) }
                serverNextBatch = page.nextBatch
                highlights = Array(Set(highlights + page.highlights))
                serverEnded = page.nextBatch == nil
            } catch ServerSearch.Failure.unsupported {
                guard generation == serverGeneration else { return }
                serverSearches = false
            } catch {
                // This Mac's results still show; the server's are left out of this search.
                guard generation == serverGeneration else { return }
                serverEnded = true
            }
            serverStarted = true
            serverLoading = false
            fillIfNeeded()
        }
    }

    // MARK: Both

    /// Runs the query a moment after the last keystroke, so typing doesn't start a search
    /// for every letter.
    private func schedule() {
        queryTask?.cancel()
        selectedEventID = nil
        failure = nil
        let query = trimmedQuery
        guard !query.isEmpty else {
            isPending = false
            serverGeneration += 1
            return
        }
        isPending = true
        queryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            // The last query's results go at once, rather than when the SDK gets round to it.
            localResults = []
            localHits = []
            localStarted = false
            localEnded = false
            restartServer()
            do {
                try await service.setQuery(query: query)
            } catch {
                if self.trimmedQuery == query { self.failure = error.actionMessage }
            }
            if self.trimmedQuery == query { self.isPending = false }
        }
    }

    /// This Mac's results cover every room either way; the server's are asked for by scope,
    /// so they start again.
    private func scopeChanged() {
        selectedEventID = nil
        guard isSearching, !isPending else { return }
        restartServer()
        fillIfNeeded()
    }

    /// The next page, as the list reaches its end: from whichever source is holding the list
    /// back (the one that has got least far into the past), or both.
    func loadMore() {
        guard isSearching, !isPending else { return }
        let localOldest = localHits.last?.date ?? .distantFuture
        let serverOldest = serverHits.last?.date ?? .distantFuture
        let serverActive = serverSearches && !serverEnded
        if !localEnded, !localLoading, !serverActive || localOldest >= serverOldest {
            localLoading = true
            Task { try? await service.paginate() }
        }
        if serverActive, !localEnded ? serverOldest >= localOldest : true {
            loadServerPage()
        }
    }

    /// Searching one room goes through this Mac's results for every room, so keep loading
    /// until there are enough of that room's to fill the list, or there are no more.
    private func fillIfNeeded() {
        guard isSearching, shown.count < Self.pageTarget, !endReached else { return }
        loadMore()
    }

    /// The message to go to for a result, as the room shows it: the message an edit changed,
    /// or the first message of the thread a reply is in. The SDK's results don't say, so
    /// the server is asked; the relation is readable even in an encrypted room.
    func jumpTarget(for hit: SearchHit) async -> String {
        if let jump = hit.jumpEventID { return jump }
        return await server.relatedEventID(of: hit.eventID, in: hit.roomID) ?? hit.eventID
    }

    /// Opens the search field, for Find (⌘F) and Find in All Rooms (⇧⌘F).
    func focus(scope: Scope) {
        self.scope = scope
        focusRequest += 1
    }

    /// The result after (or before) the one last opened, for Find Next and Find Previous.
    func step(by offset: Int) -> SearchHit? {
        let list = shown
        guard !list.isEmpty else { return nil }
        let current = list.firstIndex { $0.eventID == selectedEventID }
        let index: Int
        if let current {
            index = current + offset
        } else {
            index = offset > 0 ? 0 : list.count - 1
        }
        guard list.indices.contains(index) else { return nil }
        if index >= list.count - 3 { loadMore() }
        return list[index]
    }

    func stop() {
        queryTask?.cancel()
        serverGeneration += 1
        handles.forEach { $0.cancel() }
        handles = []
    }
}
