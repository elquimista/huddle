import XCTest
@testable import Huddle

/// What a link in a message may open, and when it asks first (LinkPolicy.swift).
final class LinkPolicyTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    /// Whether the link put on `shown` asks before going to `target`.
    private func asks(_ target: String, shown: String) -> Bool {
        LinkPolicy.link(to: url(target), shown: shown).scheme == "x-huddle-check"
    }

    func testOnlyWebPagesAndEmailOpen() {
        for open in ["https://example.org", "http://example.org/a", "mailto:a@example.org", "HTTPS://EXAMPLE.ORG"] {
            XCTAssertTrue(LinkPolicy.isOpenable(url(open)), open)
        }
        for refused in ["file:///etc/passwd", "smb://server/share", "ssh://host", "x-apple.systempreferences:com.apple",
                        "javascript:alert(1)", "tel:123", "facetime:someone", "vnc://host"] {
            XCTAssertFalse(LinkPolicy.isOpenable(url(refused)), refused)
        }
    }

    func testAServerPageIsHTTPSOrThisMac() {
        XCTAssertTrue(LinkPolicy.isSafeServerPage(url("https://matrix.example.org/login")))
        XCTAssertTrue(LinkPolicy.isSafeServerPage(url("http://localhost:8008/")))
        XCTAssertTrue(LinkPolicy.isSafeServerPage(url("http://127.0.0.1:8081/authorize")))
        XCTAssertFalse(LinkPolicy.isSafeServerPage(url("http://matrix.example.org/login")))
        XCTAssertFalse(LinkPolicy.isSafeServerPage(url("http://localhost.example.org/")))
        XCTAssertFalse(LinkPolicy.isSafeServerPage(url("file:///tmp/a.html")))
    }

    func testALinkThatSaysWhereItGoesDoesntAsk() {
        XCTAssertFalse(asks("https://bank.com/login", shown: "https://bank.com/login"))
        XCTAssertFalse(asks("https://www.bank.com/", shown: "bank.com"))
        XCTAssertFalse(asks("https://bank.com/", shown: "Sign in to your bank"))
        XCTAssertFalse(asks("https://bank.com/", shown: "click here"))
    }

    func testALinkThatNamesSomewhereElseAsks() {
        XCTAssertTrue(asks("https://evil.example/", shown: "https://bank.com/login"))
        XCTAssertTrue(asks("https://evil.example/", shown: "Sign in at bank.com."))
        XCTAssertTrue(asks("https://evil.example/", shown: "your statement (https://bank.com/statement)"))
        // Anywhere in the text, after another address that does match.
        XCTAssertTrue(asks("https://evil.example/", shown: "evil.example or bank.com"))
    }

    func testInvisibleCharactersDontHideTheAddress() {
        // Zero-width spaces and direction marks inside the address, which a detector would split on.
        XCTAssertTrue(asks("https://evil.example/", shown: "https://ba\u{200B}nk.c\u{200E}om/login"))
        XCTAssertTrue(asks("https://evil.example/", shown: "bank\u{2060}.com"))
    }

    func testTheStandInCarriesWhereItReallyGoes() throws {
        let checked = LinkPolicy.link(to: url("https://evil.example/x?y=1"), shown: "bank.com")
        let items = try XCTUnwrap(URLComponents(url: checked, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "to" }?.value, "https://evil.example/x?y=1")
        XCTAssertEqual(items.first { $0.name == "shown" }?.value, "bank.com")
    }
}
