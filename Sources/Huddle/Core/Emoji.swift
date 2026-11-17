import Foundation

enum Emoji {
    /// The most emoji a message can have and still be drawn large.
    static let largeLimit = 12

    /// Whether a message is nothing but emoji (spaces between them allowed), and few enough of
    /// them to be drawn large.
    static func isLargeOnly(_ text: String) -> Bool {
        // Spaces count towards the length here, so a long text is turned away before looking
        // at each character.
        guard text.count <= largeLimit * 4 else { return false }
        var count = 0
        for character in text where !character.isWhitespace {
            guard character.isEmojiGlyph else { return false }
            count += 1
            if count > largeLimit { return false }
        }
        return count > 0
    }
}

extension Character {
    /// Whether this is drawn as an emoji picture: one shown as a picture by default, or one
    /// made into a picture by what follows it (a variation selector, a keycap, a skin tone, a
    /// joined sequence). A plain digit or "#" is not, though Unicode counts them as emoji.
    var isEmojiGlyph: Bool {
        guard let first = unicodeScalars.first else { return false }
        if first.properties.isEmojiPresentation { return true }
        return unicodeScalars.count > 1 && first.properties.isEmoji
    }
}
