import SwiftUI
import Perception

/// A searchable grid of emoji, shown in a popover to pick a reaction.
struct EmojiPicker: View {
    /// Whether what's picked counts as used, for Recently Used: a reaction does; an emoji chosen
    /// as a setting doesn't.
    var recordsUse = true
    /// Emoji to mark as chosen already: your reactions to the message, which picking again
    /// takes back.
    var marked: Set<String> = []
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var recents = EmojiCatalog.recents
    @FocusState private var searchFocused: Bool

    private static let columns = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 8)

    var body: some View { WithPerceptionTracking {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search emoji", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let first = matches.first { pick(first.emoji) }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            ScrollView {
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 2, pinnedViews: []) { WithPerceptionTracking {
                    if isSearching {
                        cells(matches)
                    } else {
                        if !recents.isEmpty {
                            Section {
                                cells(recents.map { EmojiCatalog.Entry(emoji: $0, name: "") }, in: "Recently Used")
                            } header: { header("Recently Used") }
                        }
                        ForEach(EmojiCatalog.sections) { section in WithPerceptionTracking {
                            Section { cells(section.entries, in: section.title) } header: { header(section.title) }
                        } }
                    }
                } }
                .padding(8)
                if isSearching, matches.isEmpty {
                    Text("No emoji found")
                        .foregroundStyle(.secondary)
                        .padding(.top, 30)
                }
            }
        }
        .frame(width: 296, height: 320)
        .onAppear { searchFocused = true }
    } }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var matches: [EmojiCatalog.Entry] { EmojiCatalog.search(query) }

    /// One emoji can be in two sections, Recently Used and its own: the grid draws only one of
    /// the cells it takes for the same, so each section's are told apart.
    private func cells(_ entries: [EmojiCatalog.Entry], in section: String = "") -> some View {
        ForEach(entries.map { (id: section + "/" + $0.emoji, entry: $0) }, id: \.id) { cell in WithPerceptionTracking {
            EmojiCell(entry: cell.entry, isMarked: marked.contains(EmojiCatalog.canonical(cell.entry.emoji))) {
                pick(cell.entry.emoji)
            }
        } }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
            .padding(.leading, 4)
    }

    private func pick(_ emoji: String) {
        if recordsUse { EmojiCatalog.noteUse(of: emoji) }
        onPick(emoji)
    }
}

private struct EmojiCell: View {
    let entry: EmojiCatalog.Entry
    var isMarked = false
    let action: () -> Void
    @State private var isHovering = false

    var body: some View { WithPerceptionTracking {
        Button(action: action) {
            Text(entry.emoji)
                .font(.system(size: 20))
                .frame(width: 32, height: 32)
                .background(isMarked ? Color.accentColor.opacity(isHovering ? 0.3 : 0.2)
                                     : isHovering ? Color.primary.opacity(0.1) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isMarked ? "Remove Your Reaction" : entry.name.isEmpty ? entry.emoji : entry.name.capitalized)
    } }
}

/// Every emoji the system knows, built from Unicode's own tables so no list is shipped.
enum EmojiCatalog {
    struct Entry: Identifiable {
        let emoji: String
        /// Lowercased Unicode name, for search: "face with tears of joy".
        let name: String
        var id: String { emoji }
    }

    struct SectionGroup: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    static let sections: [SectionGroup] = {
        var seen: Set<UInt32> = []
        func entries(_ ranges: [ClosedRange<UInt32>]) -> [Entry] {
            var result: [Entry] = []
            for range in ranges {
                for value in range {
                    guard let scalar = Unicode.Scalar(value), !seen.contains(value) else { continue }
                    let properties = scalar.properties
                    guard properties.isEmoji, !properties.isEmojiModifier,
                          !(0x1F9B0...0x1F9B3).contains(value),   // hair components
                          let name = properties.name else { continue }
                    seen.insert(value)
                    // Symbols that default to text style need the emoji variation selector.
                    let emoji = properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
                    result.append(Entry(emoji: emoji, name: name.lowercased()))
                }
            }
            return result
        }
        return [
            SectionGroup(title: "Smileys", entries: entries([
                0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97A, 0x1F9D0...0x1F9D0,
                0x1FAE0...0x1FAE8, 0x1F47B...0x1F47F, 0x1F4A9...0x1F4A9,
            ])),
            SectionGroup(title: "Hearts & Celebration", entries: entries([
                0x2764...0x2764, 0x1F493...0x1F49F, 0x1F5A4...0x1F5A4, 0x1F90D...0x1F90F, 0x1F9E1...0x1F9E1,
                0x1F4AF...0x1F4AF, 0x1F4A2...0x1F4AB, 0x2728...0x2728, 0x2B50...0x2B50, 0x1F525...0x1F525,
                0x1F389...0x1F38A, 0x2705...0x2705, 0x274C...0x274C, 0x2753...0x2757,
            ])),
            SectionGroup(title: "Hands & People", entries: entries([
                0x1F440...0x1F450, 0x1F590...0x1F596, 0x1F90C...0x1F91F, 0x1F932...0x1F93A,
                0x1F9B5...0x1F9B6, 0x1FAF0...0x1FAF8, 0x1F464...0x1F483, 0x1F9D1...0x1F9DF,
            ])),
            SectionGroup(title: "Nature, Food & Objects", entries: entries([
                0x1F300...0x1F5FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF, 0x1F680...0x1F6FF, 0x2600...0x27BF,
            ])),
        ]
    }()

    static let all: [Entry] = sections.flatMap(\.entries)

    /// An emoji as the catalog writes it: with the emoji variation selector when its first
    /// character defaults to text style, so one typed or picked either way is found as one.
    static func canonical(_ emoji: String) -> String {
        guard let scalar = emoji.unicodeScalars.first else { return emoji }
        if emoji.unicodeScalars.count > 2 || (emoji.unicodeScalars.count == 2 && emoji.unicodeScalars.last != "\u{FE0F}") {
            return emoji
        }
        return scalar.properties.isEmojiPresentation ? String(scalar) : String(scalar) + "\u{FE0F}"
    }

    /// Shortcodes people know from Slack, GitHub and Element, for emoji whose Unicode names
    /// don't start with them (":tada:" is a party popper); most others are found by their names.
    private static let shortcodes: [String: String] = [
        "+1": "👍", "thumbsup": "👍", "-1": "👎", "thumbsdown": "👎", "heart": "❤️", "tada": "🎉",
        "100": "💯", "pray": "🙏", "sob": "😭", "rofl": "🤣", "joy": "😂", "heart_eyes": "😍",
        "sweat_smile": "😅", "smile": "😄", "smiley": "😃", "laughing": "😆", "satisfied": "😆",
        "blush": "😊", "relaxed": "☺️", "kissing_heart": "😘", "yum": "😋", "stuck_out_tongue": "😛",
        "rage": "😡", "angry": "😠", "triumph": "😤", "cry": "😢", "sweat": "😓", "cold_sweat": "😰",
        "disappointed_relieved": "😥", "roll_eyes": "🙄", "mask": "😷", "vomiting": "🤮",
        "hot_face": "🥵", "cold_face": "🥶", "cowboy": "🤠", "hugs": "🤗", "shushing_face": "🤫",
        "star_struck": "🤩", "partying_face": "🥳", "pleading_face": "🥺", "zany_face": "🤪",
        "innocent": "😇", "smiling_imp": "😈", "imp": "👿", "poop": "💩", "hankey": "💩",
        "muscle": "💪", "raised_hands": "🙌", "wave": "👋", "raised_hand": "✋", "v": "✌️",
        "point_up": "☝️", "point_right": "👉", "point_left": "👈", "point_down": "👇",
        "crossed_fingers": "🤞", "metal": "🤘", "vulcan_salute": "🖖", "x": "❌",
        "white_check_mark": "✅", "heavy_check_mark": "✔️", "zap": "⚡", "boom": "💥",
        "star2": "🌟", "dizzy": "💫", "coffee": "☕", "beers": "🍻", "birthday": "🎂", "gift": "🎁",
        "checkered_flag": "🏁", "bulb": "💡", "memo": "📝", "exclamation": "❗", "bangbang": "‼️",
        "sunny": "☀️", "shrug": "🤷", "facepalm": "🤦", "ok": "🆗", "cool": "🆒", "new": "🆕",
    ]

    /// Lowercased with spaces, hyphens and underscores taken out: "thumbs_up" and "thumbs up"
    /// are both "thumbsup".
    private static func squeezed(_ text: String) -> String {
        String(text.lowercased().filter { $0 != " " && $0 != "_" && $0 != "-" })
    }

    private static let squeezedShortcodes: [(code: String, squeezed: String, emoji: String)] =
        shortcodes.map { ($0.key, squeezed($0.key), canonical($0.value)) }.sorted { $0.code < $1.code }

    /// What an emoji's name answers to: each word, a word in "-ing" as it's usually typed
    /// ("smiling" as "smile"), and the words from each one on run together ("thumbs up sign"
    /// as "thumbsupsign", "upsign" and "sign"), so "thumbsup" finds it.
    private static let keys: [String: [String]] = {
        var keys: [String: [String]] = [:]
        for entry in all {
            let words = entry.name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
            var found = Set(words)
            for word in words where word.hasSuffix("ing") && word.count > 5 {
                let stem = String(word.dropLast(3))
                found.insert(stem)
                found.insert(stem + "e")
                // "running" as "run"
                if let last = stem.last, stem.dropLast().last == last { found.insert(String(stem.dropLast())) }
            }
            for start in words.indices.dropLast() { found.insert(words[start...].joined()) }
            keys[entry.emoji] = Array(found)
        }
        return keys
    }()

    private static let byEmoji: [String: Entry] = Dictionary(all.map { ($0.emoji, $0) }, uniquingKeysWith: { first, _ in first })

    /// An entry for an emoji the catalog might not list, named as Unicode names it.
    private static func entry(for emoji: String) -> Entry {
        if let known = byEmoji[emoji] { return known }
        return Entry(emoji: emoji, name: emoji.unicodeScalars.first?.properties.name?.lowercased() ?? "")
    }

    /// Emoji for what's typed, best first: one whose shortcode it is exactly, then the rest of
    /// those whose shortcodes start with it or whose names have a word starting with each word
    /// typed, ranked: used lately, the quick reactions, a shortcode, a name starting with it,
    /// any other. Words may be split by spaces, underscores or hyphens ("thumbs up", "thumbs_up").
    @MainActor static func search(_ query: String, limit: Int? = nil) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" }).map(String.init)
        let whole = squeezed(query)
        guard !whole.isEmpty else { return [] }
        let terms = words.isEmpty ? [whole] : words

        let exact = squeezedShortcodes.filter { $0.squeezed == whole }.map(\.emoji)
        let coded = Set(squeezedShortcodes.filter { $0.squeezed.hasPrefix(whole) }.map(\.emoji))
        var candidates = all.filter { entry in
            if coded.contains(entry.emoji) { return true }
            let keys = Self.keys[entry.emoji] ?? []
            return terms.allSatisfy { term in keys.contains { $0.hasPrefix(term) } }
                || (terms.count > 1 && keys.contains { $0.hasPrefix(whole) })
        }
        // Shortcodes for emoji the catalog doesn't list.
        for emoji in coded where byEmoji[emoji] == nil { candidates.append(entry(for: emoji)) }

        let recents = Self.recents
        let quick = QuickReactions.shared.emoji
        func rank(_ entry: Entry) -> (Int, Int) {
            if let index = exact.firstIndex(of: entry.emoji) { return (0, index) }
            if let index = recents.firstIndex(of: entry.emoji) { return (1, index) }
            if let index = quick.firstIndex(of: entry.emoji) { return (2, index) }
            if coded.contains(entry.emoji) { return (3, 0) }
            return (entry.name.hasPrefix(terms[0]) ? 4 : 5, 0)
        }
        // Sorted stably: the catalog's own order within each rank.
        let ranked = candidates.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return limit.map { Array(ranked.prefix($0)) } ?? ranked
    }

    /// An emoji's well-known shortcode, if it has one ("tada" for 🎉), for showing beside it.
    static func shortcode(for emoji: String) -> String? {
        let emoji = canonical(emoji)
        let codes = squeezedShortcodes.filter { $0.emoji == emoji }.map(\.code)
        // A word ("thumbsup") says more than "+1".
        return codes.first { $0.first?.isLetter == true } ?? codes.first
    }

    /// The emoji a complete shortcode stands for: ":tada:" or ":fire:", or a name written out
    /// with underscores (":thumbs_up_sign:").
    static func emoji(forShortcode code: String) -> String? {
        let whole = squeezed(code)
        if let match = squeezedShortcodes.first(where: { $0.squeezed == whole }) { return match.emoji }
        return all.first { squeezed($0.name) == whole }?.emoji
    }

    private static let recentsKey = "recentEmoji"

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func noteUse(of emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(16)), forKey: recentsKey)
    }
}

/// The reactions one click away: six at the top of the reaction picker, and the first three (or
/// all six) on a message's bar in the layouts that have one there. Chosen in Settings ▸
/// Appearance, for every account on this Mac.
@MainActor @Perceptible
final class QuickReactions {
    static let shared = QuickReactions()
    static let defaults = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    /// How many a message's bar can show: the first three, a small bar, or all six.
    static let barCounts = [3, 6]
    static let defaultBarCount = 3
    private static let key = "quickReactions"
    private static let barKey = "quickReactionsOnBar"

    private(set) var emoji: [String]
    /// How many of them, from the first, a message's bar shows.
    private(set) var onBarCount: Int

    private init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        // Six different ones, or the standard six.
        let usable = saved.count == Self.defaults.count && Set(saved).count == saved.count
            && saved.allSatisfy { !$0.isEmpty }
        emoji = usable ? saved : Self.defaults
        let count = UserDefaults.standard.integer(forKey: Self.barKey)
        onBarCount = Self.barCounts.contains(count) ? count : Self.defaultBarCount
    }

    var onBar: [String] { Array(emoji.prefix(onBarCount)) }

    var areDefaults: Bool { emoji == Self.defaults && onBarCount == Self.defaultBarCount }

    func setOnBarCount(_ count: Int) {
        guard Self.barCounts.contains(count), count != onBarCount else { return }
        onBarCount = count
        if count == Self.defaultBarCount {
            UserDefaults.standard.removeObject(forKey: Self.barKey)
        } else {
            UserDefaults.standard.set(count, forKey: Self.barKey)
        }
    }

    /// Puts an emoji in a place. One that's already in another place swaps with the one it
    /// replaces, so each is there once and choosing one already there moves it.
    func set(_ new: String, at index: Int) {
        guard emoji.indices.contains(index), emoji[index] != new else { return }
        var list = emoji
        if let other = list.firstIndex(of: new) { list[other] = list[index] }
        list[index] = new
        save(list)
    }

    func restoreDefaults() {
        save(Self.defaults)
        setOnBarCount(Self.defaultBarCount)
    }

    private func save(_ list: [String]) {
        emoji = list
        // The standard six aren't saved, so a change to them reaches everyone who kept them.
        if list == Self.defaults {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(list, forKey: Self.key)
        }
    }
}

/// "Customize Quick Reactions…", for a quick reaction's menu: Settings, at Appearance, where
/// they're chosen.
struct CustomizeQuickReactionsButton: View {
    /// Done before Settings opens: putting away the popover the menu was in, say.
    var before: () -> Void = {}

    var body: some View { WithPerceptionTracking {
        if #available(macOS 14, *) {
            OpensSettings(before: before)
        } else {
            Button("Customize Quick Reactions…") {
                UserDefaults.standard.set(SettingsView.Tab.appearance.rawValue, forKey: SettingsView.tabKey)
                before()
                // macOS 13's way to Settings: the app menu's own command.
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    } }

    /// The button on macOS 14, where SwiftUI opens Settings itself.
    @available(macOS 14, *)
    private struct OpensSettings: View {
        let before: () -> Void
        @Environment(\.openSettings) private var openSettings

        var body: some View { WithPerceptionTracking {
            Button("Customize Quick Reactions…") {
                UserDefaults.standard.set(SettingsView.Tab.appearance.rawValue, forKey: SettingsView.tabKey)
                before()
                openSettings()
            }
        } }
    }
}
