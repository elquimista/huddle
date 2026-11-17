import SwiftUI

/// A searchable grid of emoji, shown in a popover to pick a reaction.
struct EmojiPicker: View {
    let onPick: (String) -> Void

    @State private var query = ""
    @State private var recents = EmojiCatalog.recents
    @FocusState private var searchFocused: Bool

    private static let columns = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 8)

    var body: some View {
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
                LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 2, pinnedViews: []) {
                    if isSearching {
                        cells(matches)
                    } else {
                        if !recents.isEmpty {
                            Section { cells(recents.map { EmojiCatalog.Entry(emoji: $0, name: "") }) } header: { header("Recently Used") }
                        }
                        ForEach(EmojiCatalog.sections) { section in
                            Section { cells(section.entries) } header: { header(section.title) }
                        }
                    }
                }
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
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var matches: [EmojiCatalog.Entry] {
        let words = query.lowercased().split(separator: " ")
        return EmojiCatalog.all.filter { entry in words.allSatisfy { entry.name.contains($0) } }
    }

    private func cells(_ entries: [EmojiCatalog.Entry]) -> some View {
        ForEach(entries) { entry in
            EmojiCell(entry: entry) { pick(entry.emoji) }
        }
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
        EmojiCatalog.noteUse(of: emoji)
        onPick(emoji)
    }
}

private struct EmojiCell: View {
    let entry: EmojiCatalog.Entry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(entry.emoji)
                .font(.system(size: 20))
                .frame(width: 32, height: 32)
                .background(isHovering ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(entry.name.isEmpty ? entry.emoji : entry.name.capitalized)
    }
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

    private static let recentsKey = "recentEmoji"

    static var recents: [String] { UserDefaults.standard.stringArray(forKey: recentsKey) ?? [] }

    static func noteUse(of emoji: String) {
        var list = recents.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        UserDefaults.standard.set(Array(list.prefix(16)), forKey: recentsKey)
    }
}
