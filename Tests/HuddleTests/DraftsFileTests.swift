import XCTest
@testable import Huddle

/// Unsent messages, kept encrypted (DraftsFile.swift). In a folder of the test's own: outside
/// the app, Huddle takes itself for the release build, whose data folder is the user's.
final class DraftsFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("HuddleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private var url: URL { folder.appendingPathComponent("drafts") }

    func testDraftsComeBackAsWritten() throws {
        let drafts = DraftsFile(url: url, passphrase: "store passphrase")
        let written = ["!room:example.org": "The plan for Monday", "!room:example.org|$thread": "In a thread 🧵"]
        try drafts.write(written)
        XCTAssertEqual(DraftsFile(url: url, passphrase: "store passphrase").read(), written)
    }

    func testTheFileHoldsNoText() throws {
        try DraftsFile(url: url, passphrase: "pass").write(["!room:example.org": "the merger is off"])
        let bytes = try Data(contentsOf: url)
        XCTAssertNil(bytes.range(of: Data("merger".utf8)))
        XCTAssertNil(bytes.range(of: Data("!room".utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testAnotherKeyReadsNothing() throws {
        try DraftsFile(url: url, passphrase: "this account's").write(["!room:example.org": "secret"])
        XCTAssertEqual(DraftsFile(url: url, passphrase: "another's").read(), [:])
    }

    func testAChangedFileReadsNothing() throws {
        try DraftsFile(url: url, passphrase: "pass").write(["!room:example.org": "secret"])
        var bytes = try Data(contentsOf: url)
        bytes[bytes.count / 2] ^= 0xFF
        try bytes.write(to: url)
        XCTAssertEqual(DraftsFile(url: url, passphrase: "pass").read(), [:])
    }

    func testNoDraftsNoFile() throws {
        let drafts = DraftsFile(url: url, passphrase: "pass")
        try drafts.write(["!room:example.org": "x"])
        try drafts.write([:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(drafts.read(), [:])
    }

    func testDraftsLeftInThePreferencesMoveIn() throws {
        let key = "drafts.test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(["!old:example.org": "left by 1.4.3", "!both:example.org": "older"], forKey: key)
        let drafts = DraftsFile(url: url, passphrase: "pass")
        try drafts.write(["!both:example.org": "newer"])

        let moved = drafts.readMoving(fromDefaultsKey: key)
        // What was already in the file is newer than what was left behind.
        XCTAssertEqual(moved, ["!old:example.org": "left by 1.4.3", "!both:example.org": "newer"])
        XCTAssertNil(UserDefaults.standard.object(forKey: key))
        XCTAssertEqual(drafts.read(), moved)
    }

    func testDraftsStayInThePreferencesIfTheyCantBeMoved() throws {
        let key = "drafts.test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(["!old:example.org": "keep me"], forKey: key)
        // A file in the way of the folder the drafts would go in.
        let blocked = folder.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let drafts = DraftsFile(url: blocked.appendingPathComponent("drafts"), passphrase: "pass")
        XCTAssertEqual(drafts.readMoving(fromDefaultsKey: key), ["!old:example.org": "keep me"])
        XCTAssertNotNil(UserDefaults.standard.object(forKey: key))
    }
}
