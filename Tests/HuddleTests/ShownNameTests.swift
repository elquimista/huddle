import XCTest
@testable import Huddle

/// Names people choose for themselves and their rooms, made safe to show (ShownName.swift).
final class ShownNameTests: XCTestCase {
    func testDirectionOverridesGo() {
        // "Mallory‮nimda" would read "Malloryadmin".
        XCTAssertEqual(ShownName.clean("Mallory\u{202E}nimda"), "Mallorynimda")
        XCTAssertEqual(ShownName.clean("\u{202D}Alice\u{202C}"), "Alice")
        XCTAssertEqual(ShownName.clean("Bob\u{2066}\u{200F}"), "Bob")
    }

    func testInvisibleCharactersGo() {
        // Zero-width space, word joiner, soft hyphen: "Alice" and "Al​ice" would be different names.
        XCTAssertEqual(ShownName.clean("Al\u{200B}i\u{2060}c\u{00AD}e"), "Alice")
        // Hangul fillers and blank Braille draw nothing.
        XCTAssertEqual(ShownName.clean("Eve\u{3164}\u{2800}"), "Eve")
    }

    func testANameWithNothingVisibleIsNoName() {
        XCTAssertNil(ShownName.clean("\u{200B}\u{3164}\u{2800}"))
        XCTAssertNil(ShownName.clean("   \n\t"))
        XCTAssertNil(ShownName.clean("\u{0301}\u{0301}"))
        XCTAssertNil(ShownName.clean(""))
        XCTAssertNil(ShownName.clean(nil))
    }

    func testLineBreaksBecomeSpaces() {
        XCTAssertEqual(ShownName.clean("Alice\nSmith\r\n\u{2028}Jr"), "Alice Smith Jr")
    }

    func testATowerOfAccentsIsCutToFour() throws {
        let tower = "Z" + String(repeating: "\u{0301}", count: 200)
        let cleaned = try XCTUnwrap(ShownName.clean(tower))
        XCTAssertEqual(cleaned.unicodeScalars.count, 5)
        // Each letter gets its own four.
        let two = "a" + String(repeating: "\u{0300}", count: 10) + "b" + String(repeating: "\u{0300}", count: 10)
        XCTAssertEqual(ShownName.clean(two)?.unicodeScalars.count, 10)
    }

    func testOtherScriptsAndEmojiStay() {
        for name in ["Zoë", "Ñandú", "محمد", "שלום", "日本語", "Ελένη", "Nguyễn Văn"] {
            XCTAssertEqual(ShownName.clean(name), name, name)
        }
        // Joiners (a family, a profession) and variation selectors (emoji style) are kept.
        XCTAssertEqual(ShownName.clean("👩‍👩‍👧 Smiths"), "👩‍👩‍👧 Smiths")
        XCTAssertEqual(ShownName.clean("☎️ Desk"), "☎️ Desk")
        XCTAssertEqual(ShownName.clean("می\u{200C}خواهم"), "می\u{200C}خواهم")
        // A subdivision flag is a black flag followed by tag characters.
        let scotland = "🏴\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}"
        XCTAssertEqual(ShownName.clean(scotland + " fans"), scotland + " fans")
    }

    func testAnAmbiguousNameShowsTheMatrixID() {
        XCTAssertEqual(ShownName.person("Alice", userID: "@bob:example.org", isAmbiguous: true), "Alice (@bob:example.org)")
        XCTAssertEqual(ShownName.person("Alice", userID: "@alice:example.org", isAmbiguous: false), "Alice")
        // No name, or none visible: the Matrix ID alone.
        XCTAssertEqual(ShownName.person("\u{200B}", userID: "@carol:example.org", isAmbiguous: true), "@carol:example.org")
        XCTAssertEqual(ShownName.person(nil, userID: "@carol:example.org", isAmbiguous: false), "@carol:example.org")
        // A name that is the ID already isn't doubled.
        XCTAssertEqual(ShownName.person("@dave:example.org", userID: "@dave:example.org", isAmbiguous: true), "@dave:example.org")
    }

    func testATopicKeepsItsLinesButNotItsTricks() {
        let topic = "Welcome\u{202E}!\n\n\n\nRules:\n- be kind\u{200B}\n\n"
        XCTAssertEqual(ShownName.text(topic), "Welcome!\n\nRules:\n- be kind")
        XCTAssertNil(ShownName.text("\n\u{200B}\n"))
    }
}
