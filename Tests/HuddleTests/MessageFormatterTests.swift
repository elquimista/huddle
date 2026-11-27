import MatrixRustSDK
import XCTest
@testable import Huddle

/// Turning a message's HTML into what the timeline shows (MessageFormatter.swift).
final class MessageFormatterTests: XCTestCase {
    private func render(_ html: String, text: String = "", name: @escaping (String) -> String? = { _ in nil }) -> AttributedString {
        MessageFormatter.render(text: text, html: html, mentionsRoom: false, ownUserID: "@me:example.org", name: name)
    }

    private func links(in text: AttributedString) -> [URL] {
        text.runs.compactMap(\.link)
    }

    /// Links nested inside each other around a long run of text froze Huddle for a minute or more,
    /// each closing tag going back over the whole text. It must take moments.
    func testNestedLinksDontFreezeIt() {
        let depth = 1500
        let html = String(repeating: "<a href='//a.b'>", count: depth)
            + String(repeating: "a.b/", count: 30_000 / 4)
            + String(repeating: "</a>", count: depth)
        let started = Date()
        _ = render(html, text: "x")
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "rendering nested links took too long")
    }

    func testDeepNestingIsCutShortNotFollowed() {
        let html = String(repeating: "<blockquote><ul><li>", count: 2000) + "deep" + String(repeating: "</li></ul></blockquote>", count: 2000)
        let started = Date()
        let shown = render(html)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        XCTAssertTrue(String(shown.characters).contains("deep"))
    }

    func testALinkWhoseTextNamesAnotherAddressAsks() throws {
        let shown = render(#"<a href="https://evil.example/">https://bank.com/login</a>"#)
        let link = try XCTUnwrap(links(in: shown).first)
        XCTAssertEqual(link.scheme, "x-huddle-check")
    }

    func testAnHonestLinkGoesStraightThere() throws {
        let shown = render(#"<a href="https://example.org/page">the page</a>"#)
        XCTAssertEqual(links(in: shown), [URL(string: "https://example.org/page")!])
    }

    func testAMentionNamesWhoItPointsTo() {
        // Written as "Alice", but it's Bob's: the pill says Bob.
        let shown = render(#"Hi <a href="https://matrix.to/#/@bob:example.org">Alice</a>"#,
                           name: { $0 == "@bob:example.org" ? "Bob" : nil })
        let text = String(shown.characters)
        XCTAssertTrue(text.contains("Bob"), text)
        XCTAssertFalse(text.contains("Alice"), text)
    }

    func testPlainTextDropsFormatting() {
        let plain = MessageFormatter.plainText(text: "fallback",
                                               formatted: FormattedBody(format: .html, body: "<p><b>Ship</b> it <i>today</i></p>"))
        XCTAssertEqual(plain, "Ship it today")
    }

    func testAReplysQuotedFallbackIsDropped() {
        let body = "> <@bob:example.org> the original\n> second line\n\nmy answer"
        XCTAssertEqual(MessageFormatter.strippingReplyFallback(body), "my answer")
    }
}
