import Foundation

/// Names other people choose, made safe to show: display names, room and space names, device
/// names, and topics. Anyone can name themselves or a room anything, and some characters can
/// make a name read as something it isn't:
/// - direction overrides turn text round ("Mallory\u{202E}nimda" reads "Malloryadmin"), and an
///   override left open turns round whatever follows the name on the same line;
/// - invisible characters (zero-width spaces, word joiners, Hangul fillers, blank Braille) make
///   a name that looks like another's a different string, or a name that looks like nothing;
/// - hundreds of accents stacked on one letter draw over the lines above and below.
/// So those go, line breaks become spaces, and a name with nothing visible left is no name.
/// What makes text in other languages (right-to-left scripts, the joiners emoji and some scripts
/// need, accents) stays.
enum ShownName {
    /// A name to show on one line, or nil when nothing visible is left of it: the caller falls
    /// back to the Matrix ID or room address, as for someone with no name.
    static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let cleaned = filtered(raw, keepsLineBreaks: false)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.unicodeScalars.contains(where: isVisible) ? cleaned : nil
    }

    /// A person's name: theirs, cleaned, or their Matrix ID if they have none. When the SDK
    /// finds it ambiguous (someone else in the room goes by the same name, or one that looks the
    /// same, or the name looks like a Matrix ID), their Matrix ID follows it, as Element shows it.
    static func person(_ raw: String?, userID: String, isAmbiguous: Bool) -> String {
        guard let name = clean(raw) else { return userID }
        return isAmbiguous && name != userID ? "\(name) (\(userID))" : name
    }

    /// Longer text, a topic: cleaned the same way, its line breaks kept (no more than one blank
    /// line in a row). Nil when nothing visible is left.
    static func text(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lines = filtered(raw, keepsLineBreaks: true)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0.isWhitespace && !$0.isNewline }).joined(separator: " ") }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) { kept.append(line) }
        while kept.last?.isEmpty == true { kept.removeLast() }
        let cleaned = kept.joined(separator: "\n")
        return cleaned.unicodeScalars.contains(where: isVisible) ? cleaned : nil
    }

    /// Accents kept on one letter at most: enough for any language's, not for a tower of them.
    private static let mostMarks = 4

    private static func filtered(_ raw: String, keepsLineBreaks: Bool) -> String {
        var result = String.UnicodeScalarView()
        var marks = 0
        var inFlag = false
        for scalar in raw.unicodeScalars {
            let category = scalar.properties.generalCategory
            // A subdivision flag (England's, Scotland's) is a black flag and invisible tags.
            if inFlag, (0xE0020...0xE007F).contains(scalar.value) {
                result.append(scalar)
                continue
            }
            inFlag = scalar.value == 0x1F3F4
            switch category {
            case .control, .lineSeparator, .paragraphSeparator:
                let isBreak = scalar == "\n" || scalar == "\r" || category == .lineSeparator || category == .paragraphSeparator
                result.append(keepsLineBreaks && isBreak ? "\n" : " ")
                marks = 0
            case .format:
                // Joiners shape emoji and some scripts (Persian, the Indic ones); every other
                // format character (direction marks and overrides, zero-width spaces, word
                // joiners, soft hyphens, invisible operators) goes.
                if scalar.value == 0x200C || scalar.value == 0x200D { result.append(scalar) }
            case .nonspacingMark, .enclosingMark:
                // Variation selectors choose how a character looks (emoji or text); not accents.
                let isSelector = (0xFE00...0xFE0F).contains(scalar.value) || (0xE0100...0xE01EF).contains(scalar.value)
                if isSelector { result.append(scalar); continue }
                marks += 1
                if marks <= mostMarks { result.append(scalar) }
            default:
                if invisibleLetters.contains(scalar.value) { continue }
                result.append(scalar)
                marks = 0
            }
        }
        return String(result)
    }

    /// Letters that draw nothing, used for names that look blank: Hangul fillers, blank Braille.
    private static let invisibleLetters: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800]

    /// Whether a character draws something: not a space, a joiner, an accent on its own or a
    /// variation selector.
    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control, .format,
             .nonspacingMark, .enclosingMark: false
        default: !invisibleLetters.contains(scalar.value)
        }
    }
}
