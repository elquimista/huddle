import MatrixRustSDK
import XCTest
@testable import Huddle

/// Small pieces of the timeline: the room list's "reacted to" line, and what a sender's own
/// numbers can't break.
final class TimelineHelperTests: XCTestCase {
    private func message(_ id: String, at seconds: TimeInterval, text: String = "hello", html: String? = nil,
                         reactions: [MessageRow.ReactionChip] = []) -> TimelineRow {
        var row = MessageRow(itemID: .eventId(eventId: id), sender: "@bob:example.org", senderName: "Bob",
                             senderAvatarURL: nil, isOwn: false, date: Date(timeIntervalSince1970: seconds), body: .text(text))
        row.html = html
        row.reactions = reactions
        return TimelineRow(id: id, kind: .message(row))
    }

    private func reaction(_ key: String, by sender: String, at seconds: TimeInterval) -> MessageRow.ReactionChip {
        .init(key: key, count: 1, isOwn: false, senders: [sender], latestSender: sender,
              latestDate: Date(timeIntervalSince1970: seconds))
    }

    @MainActor
    func testTheNewestReactionAfterTheNewestMessage() {
        let rows = [
            message("$1", at: 100, html: "<b>Ship</b> it", reactions: [reaction("👍", by: "@carol:example.org", at: 300)]),
            message("$2", at: 200, reactions: [reaction("🎉", by: "@me:example.org", at: 250)]),
        ]
        let preview = ReactionPreview.newest(in: rows, ownUserID: "@me:example.org",
                                             name: { $0 == "@carol:example.org" ? "Carol" : nil })
        XCTAssertEqual(preview?.text, "Carol reacted 👍 to “Ship it”")
        XCTAssertEqual(preview?.date, Date(timeIntervalSince1970: 300))
    }

    @MainActor
    func testNoneIfAMessageCameAfter() {
        let rows = [
            message("$1", at: 100, reactions: [reaction("👍", by: "@carol:example.org", at: 150)]),
            message("$2", at: 200),
        ]
        XCTAssertNil(ReactionPreview.newest(in: rows, ownUserID: "@me:example.org", name: { _ in nil }))
    }

    @MainActor
    func testYourOwnReactionSaysYou() {
        let rows = [message("$1", at: 100, reactions: [reaction("❤️", by: "@me:example.org", at: 200)])]
        XCTAssertEqual(ReactionPreview.newest(in: rows, ownUserID: "@me:example.org", name: { _ in nil })?.text,
                       "You reacted ❤️ to “hello”")
    }

    func testALengthOfAnythingDoesntCrash() {
        XCTAssertEqual(VideoDetails.durationText(42), "0:42")
        XCTAssertEqual(VideoDetails.durationText(3723), "1:02:03")
        for silly in [Double.infinity, -.infinity, .nan, -5, 1e300] {
            _ = VideoDetails.durationText(silly)
        }
    }

    func testAWaveformOfAnySizeFitsTheBars() throws {
        XCTAssertEqual(AudioAttachment.bars(from: [0, 512, 1024]).count, AudioAttachment.barCount)
        XCTAssertEqual(AudioAttachment.bars(from: Array(repeating: 7, count: 10_000)).count, AudioAttachment.barCount)
        XCTAssertEqual(try XCTUnwrap(AudioAttachment.bars(from: [3, 3]).max()), 1, accuracy: 0.0001)
        XCTAssertEqual(AudioAttachment.bars(from: []), [])
        XCTAssertEqual(AudioAttachment.bars(from: [0, 0, 0]), [])
    }
}
