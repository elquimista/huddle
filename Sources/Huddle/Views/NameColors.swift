import AppKit
import SwiftUI
import Perception

/// People's and rooms' colours as Element gives them: Compound's six decorative colours (lime,
/// cyan, fuchsia, purple, pink and orange), picked by adding up the ID's UTF-16 code units, as
/// Compound's `useIdColorHash` does for Element Web and Element X. A person has the same colour
/// here as there. Each colour has its shades for light, dark and their high-contrast forms,
/// taken from Compound's design tokens.
enum Decorative {
    struct Shades {
        let light: UInt32
        let lightHighContrast: UInt32
        let dark: UInt32
        let darkHighContrast: UInt32
    }

    static let count = 6

    /// The colour of an ID, 0 to 5: the sum of its UTF-16 code units, modulo six.
    static func index(for id: String) -> Int {
        id.utf16.reduce(0) { $0 + Int($1) } % count
    }

    /// `text-decorative-1…6` (each colour's 1100): names.
    static let text: [Color] = [
        Shades(light: 0x005F00, lightHighContrast: 0x004200, dark: 0x56C02C, darkHighContrast: 0x92E175),
        Shades(light: 0x00548C, lightHighContrast: 0x00376E, dark: 0x21BACD, darkHighContrast: 0x93D9E2),
        Shades(light: 0x822198, lightHighContrast: 0x5C0F76, dark: 0xD991DE, darkHighContrast: 0xEAC0ED),
        Shades(light: 0x5D26CD, lightHighContrast: 0x4200A6, dark: 0xAD9CFE, darkHighContrast: 0xCEC7FF),
        Shades(light: 0x9F0850, lightHighContrast: 0x72003A, dark: 0xFE84A2, darkHighContrast: 0xFFBBCA),
        Shades(light: 0x9B2200, lightHighContrast: 0x770000, dark: 0xF6913D, darkHighContrast: 0xFDC197),
    ].map(color)

    /// A picture-less avatar's disc, under a white initial: each colour's 900 in light and 800
    /// in dark, deep enough for the white in both. Element draws a pale disc (its 300) with the
    /// initial in the name's colour; that nearly vanishes against a dark background, and a
    /// solid one is quicker to tell apart, so Huddle keeps its own way with Element's colours.
    static let avatarBackground: [Color] = [
        Shades(light: 0x197D0C, lightHighContrast: 0x005700, dark: 0x1D7C13, darkHighContrast: 0x31941D),
        Shades(light: 0x0072AC, lightHighContrast: 0x004C84, dark: 0x0271AA, darkHighContrast: 0x008ABA),
        Shades(light: 0xAD33BD, lightHighContrast: 0x781C90, dark: 0xAA36BA, darkHighContrast: 0xC153CB),
        Shades(light: 0x7A47F1, lightHighContrast: 0x571CC4, dark: 0x7849EC, darkHighContrast: 0x8B66F8),
        Shades(light: 0xD20C65, lightHighContrast: 0x92084B, dark: 0xCE1865, darkHighContrast: 0xE00C6A),
        Shades(light: 0xBC4500, lightHighContrast: 0x931700, dark: 0xB94607, darkHighContrast: 0xC44D00),
    ].map(color)

    /// A colour that follows the window's appearance, Increase Contrast included.
    private static func color(_ shades: Shades) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex: UInt32 = switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua,
                                                                 .accessibilityHighContrastDarkAqua]) {
            case .darkAqua: shades.dark
            case .accessibilityHighContrastAqua: shades.lightHighContrast
            case .accessibilityHighContrastDarkAqua: shades.darkHighContrast
            default: shades.light
            }
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// Names' colours: Element's, except in a room of up to six people, where nobody shares one.
/// There, where Element's colours would give two people the same, the one whose user ID sorts
/// first keeps it and the other takes one nobody in the room has; everyone else keeps Element's.
/// Sorting by user ID keeps this the same whoever speaks first. A bigger room has Element's
/// colours as they are: six can't keep seven people apart, and shuffling them would change
/// people's colours as others join.
@MainActor @Perceptible
final class NameColors {
    static let shared = NameColors()
    static let largestRoom = Decorative.count

    /// For each room of up to six, the people whose colour isn't Element's, and theirs.
    private var adjusted: [String: [String: Int]] = [:]

    func index(for userID: String, inRoom roomID: String?) -> Int {
        roomID.flatMap { adjusted[$0]?[userID] } ?? Decorative.index(for: userID)
    }

    /// A person's name colour; in a room, as that room has it.
    func color(for userID: String, inRoom roomID: String?) -> Color {
        Decorative.text[index(for: userID, inRoom: roomID)]
    }

    /// The room's joined members, everyone's colour worked out again from them.
    func setMembers(_ userIDs: [String], ofRoom roomID: String) {
        var changes: [String: Int] = [:]
        if userIDs.count <= Self.largestRoom {
            var taken: Set<Int> = []
            var clashing: [String] = []
            for userID in userIDs.sorted() {
                if !taken.insert(Decorative.index(for: userID)).inserted { clashing.append(userID) }
            }
            var free = (0..<Decorative.count).filter { !taken.contains($0) }.makeIterator()
            for userID in clashing {
                if let index = free.next() { changes[userID] = index }
            }
        }
        let new = changes.isEmpty ? nil : changes
        if adjusted[roomID] != new { adjusted[roomID] = new }
    }
}

extension EnvironmentValues {
    /// The room whose people are shown, for their colours as that room has them (NameColors):
    /// set by the room's view, so reply quotes, pinned messages and avatars inside it agree with
    /// the conversation.
    @Entry var nameColorRoom: String? = nil
}

extension RoomSummary {
    /// What picks the colour of the room's avatar when it has no picture: a direct chat's is the
    /// other person's, so the chat looks like them, as their name does in it and as Element X
    /// shows a direct chat; any other room's is its own ID.
    var avatarSeed: String { directUserID ?? id }
}
