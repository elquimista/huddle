import SwiftUI
import Perception

/// Searching messages, in the panel beside a room: this room's or every room's. Clicking a
/// result goes to it; the arrow keys (or ⌘G and ⇧⌘G) go through them in turn.
struct SearchPanelView: View {
    let account: AccountSession
    let roomID: String

    private var search: MessageSearch { account.search }

    var body: some View { WithPerceptionTracking {
        @Perception.Bindable var search = search
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                SearchField(text: $search.query, prompt: "Search messages", focusRequest: search.focusRequest,
                            onSubmit: { open(search.selectedEventID == nil ? search.shown.first : nil) },
                            onMove: { step($0) },
                            onEscape: {
                                // Escape clears what was typed first; with nothing typed, it closes.
                                guard !search.query.isEmpty else { return false }
                                search.query = ""
                                return true
                            })
                Picker("Search in", selection: $search.scope) {
                    Text("This Room").tag(MessageSearch.Scope.room)
                    Text("All Rooms").tag(MessageSearch.Scope.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(12)
            Divider()
            results
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if account.historyIndexer.isRunning {
                IndexingNote(indexer: account.historyIndexer)
            }
        }
        .onAppear { search.roomID = roomID }
    } }

    @ViewBuilder private var results: some View {
        let shown = search.shown
        if !search.isSearching {
            EmptyState {
                Label("Search Messages", systemImage: "magnifyingglass")
            } description: {
                Text("Find messages by the words in them, in encrypted rooms too: they’re searched right here on this Mac.")
            }
        } else if shown.isEmpty {
            if search.isPending || search.isLoading || !search.endReached && search.failure == nil {
                ProgressView()
                    .controlSize(.small)
            } else if let failure = search.failure {
                EmptyState("Can’t Search", systemImage: "exclamationmark.triangle",
                                       description: Text(failure))
            } else {
                SearchEmptyState(text: search.trimmedQuery)
            }
        } else {
            ScrollViewReader { proxy in WithPerceptionTracking {
                ScrollView {
                    LazyVStack(spacing: 0) { WithPerceptionTracking {
                        ForEach(shown) { hit in WithPerceptionTracking {
                            SearchResultRow(account: account, hit: hit,
                                            query: ([search.trimmedQuery] + search.highlights).joined(separator: " "),
                                            showsRoom: search.scope == .all,
                                            isSelected: hit.eventID == search.selectedEventID) {
                                account.open(hit)
                            }
                            .id(hit.eventID)
                            .onAppear { if hit.eventID == shown.last?.eventID { search.loadMore() } }
                            Divider().padding(.leading, 50)
                        } }
                        if search.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(12)
                        }
                    } }
                }
                .onChanged(of: search.selectedEventID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                }
            } }
        }
    }

    private func step(_ offset: Int) -> Bool {
        guard let hit = search.step(by: offset) else { return false }
        account.open(hit)
        return true
    }

    private func open(_ hit: SearchHit?) {
        if let hit { account.open(hit) }
    }
}

/// One result: who wrote it, where and when, and the words around what was searched for.
private struct SearchResultRow: View {
    let account: AccountSession
    let hit: SearchHit
    let query: String
    let showsRoom: Bool
    let isSelected: Bool
    let open: () -> Void
    @State private var isHovering = false
    @Environment(\.colorScheme) private var colorScheme

    /// The user's own name for them, where they've given one (ContactNames.swift).
    private var senderName: String { account.contactName(for: hit.sender) ?? hit.senderName }

    private var roomName: String? {
        guard showsRoom else { return nil }
        return account.allRooms.first { $0.id == hit.roomID }?.name
    }

    var body: some View { WithPerceptionTracking {
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                AvatarView(media: account.media, url: hit.senderAvatarURL, name: senderName,
                           seed: hit.sender, size: 28)
                    // In the found message's room, which may not be the one open.
                    .environment(\.nameColorRoom, hit.roomID)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(senderName)
                            .fontWeight(.semibold)
                            .foregroundStyle(NameColors.shared.color(for: hit.sender, inRoom: hit.roomID))
                            .lineLimit(1)
                        if let roomName {
                            Text(roomName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(hit.date.roomListLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        if let icon = hit.icon {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(SearchSnippet.make(hit.text, matching: query, dark: colorScheme == .dark))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help("Go to this message")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    } }

    private var background: some ShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        if isHovering { return AnyShapeStyle(.quaternary.opacity(0.6)) }
        return AnyShapeStyle(.clear)
    }
}

/// The words searched for, picked out in a message: the text from a little before the first
/// of them, so it shows even in a long message, with each one highlighted. Words are matched
/// from their start, in other forms too ("wrap" and "wrapped" for "wraps"), as the indexes
/// match them. A soft yellow in light mode; in dark mode, where a tint turns muddy, the
/// bright yellow and dark text of the system's own find highlight.
enum SearchSnippet {
    static func make(_ text: String, matching query: String, dark: Bool = false) -> AttributedString {
        guard let pattern = pattern(for: query) else { return AttributedString(text) }

        // Start a few words before the first match, when it is too far in to be seen.
        var excerpt = text
        if let first = matches(of: pattern, in: text).first?.lowerBound,
           text.distance(from: text.startIndex, to: first) > 60 {
            var start = text.index(first, offsetBy: -40)
            if let space = text[start..<first].firstIndex(where: \.isWhitespace) {
                start = text.index(after: space)
            }
            excerpt = "…" + text[start...]
        }

        var result = AttributedString(excerpt)
        for range in matches(of: pattern, in: excerpt) {
            guard let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            if dark {
                result[lower..<upper].backgroundColor = Color(nsColor: .findHighlightColor)
                result[lower..<upper].foregroundColor = Color.black
            } else {
                result[lower..<upper].backgroundColor = Color.yellow.opacity(0.4)
            }
            result[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return result
    }

    /// Whole words beginning with any searched-for word, or its stem.
    private static func pattern(for query: String) -> NSRegularExpression? {
        var needles = Set<String>()
        for term in query.lowercased().split(whereSeparator: \.isWhitespace) {
            let word = term.trimmingCharacters(in: CharacterSet(charactersIn: "\"'*+-()"))
            guard !word.isEmpty else { continue }
            needles.insert(word)
            for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) && word.count - suffix.count >= 3 {
                needles.insert(String(word.dropLast(suffix.count)))
                break
            }
        }
        guard !needles.isEmpty else { return nil }
        let alternatives = needles.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        return try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])(?:\(alternatives.joined(separator: "|")))[\\p{L}\\p{N}]*",
                                        options: [.caseInsensitive])
    }

    private static func matches(of pattern: NSRegularExpression, in text: String) -> [Range<String.Index>] {
        pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text) }
    }
}

/// Along the bottom of the search while encrypted rooms' older messages are still being
/// indexed, which is why some may not be found yet.
private struct IndexingNote: View {
    let indexer: HistoryIndexer

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 8) {
            ProgressView(value: Double(indexer.roomsDone), total: Double(max(indexer.roomsTotal, 1)))
                .progressViewStyle(.circular)
                .controlSize(.mini)
            Text("Indexing older encrypted messages: \(indexer.roomsDone) of \(indexer.roomsTotal) rooms")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .help("Older messages in encrypted rooms are being downloaded and indexed on this Mac, so search can find them. Settings ▸ Privacy can turn this off.")
        .accessibilityElement(children: .combine)
    } }
}
