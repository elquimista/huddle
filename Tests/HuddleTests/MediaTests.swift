import MatrixRustSDK
import XCTest
@testable import Huddle

/// What Huddle downloads and decodes without being asked (MediaLoader.swift), and the names
/// and kinds of files people send (FileAttachment.swift).
final class MediaTests: XCTestCase {
    /// A whole PNG of the given size, every pixel black, in one bit each: a large picture in a
    /// small file, as a "decompression bomb" is. (ImageIO reports the size of a large PNG only
    /// when its pixels are all there.)
    private func blackPNG(width: UInt32, height: UInt32) -> Data {
        func chunk(_ kind: String, _ body: Data) -> Data {
            var data = Data()
            withUnsafeBytes(of: UInt32(body.count).bigEndian) { data.append(contentsOf: $0) }
            let typed = Data(kind.utf8) + body
            data.append(typed)
            withUnsafeBytes(of: crc32(typed).bigEndian) { data.append(contentsOf: $0) }
            return data
        }
        var ihdr = Data()
        withUnsafeBytes(of: width.bigEndian) { ihdr.append(contentsOf: $0) }
        withUnsafeBytes(of: height.bigEndian) { ihdr.append(contentsOf: $0) }
        ihdr.append(contentsOf: [1, 0, 0, 0, 0])                       // one bit, grey
        // Each row: a filter byte and the row's bits, all zero.
        let raw = Data(count: (Int(width) + 7) / 8 * Int(height) + Int(height))
        let deflated = (try? (raw as NSData).compressed(using: .zlib)) as Data? ?? Data()
        // zlib's wrapping of the deflated stream, its Adler-32 of so many zeros worked out directly.
        var zlib = Data([0x78, 0x01]) + deflated
        let adler = UInt32(raw.count % 65_521) << 16 | 1
        withUnsafeBytes(of: adler.bigEndian) { zlib.append(contentsOf: $0) }
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", Data())
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    // MARK: Pictures of gigabytes

    func testAPictureOfTooManyPixelsIsWithheld() {
        // A 190 KB file of 40,000 × 40,000 one-bit pixels took 1.5 GB to draw.
        XCTAssertLessThan(blackPNG(width: 40_000, height: 40_000).count, 1_000_000)
        XCTAssertEqual(MediaLoader.excessPixels(in: blackPNG(width: 40_000, height: 40_000)),
                       .pixels(width: 40_000, height: 40_000))
        XCTAssertNotNil(MediaLoader.excessPixels(in: blackPNG(width: 9_000, height: 8_000)))
    }

    func testAnOrdinaryPhotoIsNot() {
        // A 48-megapixel phone photo, and a panorama.
        XCTAssertNil(MediaLoader.excessPixels(in: blackPNG(width: 8_064, height: 6_048)))
        XCTAssertNil(MediaLoader.excessPixels(in: blackPNG(width: 16_000, height: 3_900)))
    }

    func testBeyondTheShownLimitItsNeverDecoded() {
        let huge = MediaLoader.excessPixels(in: blackPNG(width: 20_000, height: 20_000), limit: MediaLoader.largestShownPixels)
        XCTAssertEqual(huge, .pixels(width: 20_000, height: 20_000))
        XCTAssertEqual(huge?.canBeShown, false)
        // 144 megapixels: not unasked, but when clicked.
        let large = MediaLoader.excessPixels(in: blackPNG(width: 12_000, height: 12_000))
        XCTAssertEqual(large?.canBeShown, true)
        XCTAssertNil(MediaLoader.excessPixels(in: blackPNG(width: 12_000, height: 12_000), limit: MediaLoader.largestShownPixels))
        XCTAssertTrue(MediaLoader.Withheld.bytes(40_000_000).canBeShown)
    }

    func testWhatIsntAPictureIsntJudged() {
        XCTAssertNil(MediaLoader.excessPixels(in: Data("hello".utf8)))
    }

    func testTheLimits() {
        XCTAssertEqual(MediaLoader.largestAutomaticPicture, 20 * 1024 * 1024)
        XCTAssertEqual(MediaLoader.largestAutomaticThumbnail, 2 * 1024 * 1024)
        XCTAssertEqual(MediaLoader.largestPosterDownload, 20 * 1024 * 1024)
        XCTAssertLessThan(MediaLoader.largestAutomaticPixels, MediaLoader.largestShownPixels)
    }

    // MARK: Files

    private func file(named name: String, mimetype: String? = nil) throws -> FileAttachment {
        let source = try MediaSource.fromUrl(url: "mxc://example.org/abc")
        let info = FileInfo(mimetype: mimetype, size: 1000, thumbnailInfo: nil, thumbnailSource: nil)
        return FileAttachment(FileMessageContent(filename: name, caption: nil, formattedCaption: nil, source: source, info: info))
    }

    func testANameCantHideWhatKindOfFileItIs() throws {
        // "photo‮gnp.app" shows as "photoppa.png".
        XCTAssertEqual(try file(named: "photo\u{202E}gnp.app").safeFilename, "photognp.app")
        XCTAssertEqual(try file(named: "report\u{200B}.pdf\u{0007}").safeFilename, "report.pdf")
    }

    func testANameCantPointElsewhere() throws {
        XCTAssertEqual(try file(named: "../../Library/LaunchAgents/evil.plist").safeFilename, "evil.plist")
        XCTAssertEqual(try file(named: "/etc/passwd").safeFilename, "passwd")
        XCTAssertEqual(try file(named: ".hidden").safeFilename, "File.hidden")
        XCTAssertEqual(try file(named: "").safeFilename, "File")
    }

    func testOpeningSomethingThatRunsCodeAsksFirst() throws {
        for risky in ["Installer.pkg", "Tool.app", "run.command", "script.sh", "image.dmg", "Profile.mobileconfig",
                      "link.webloc", "photo\u{202E}gnp.app", "Automator.workflow", "lib.dylib"] {
            XCTAssertTrue(try file(named: risky).canRunCode, risky)
        }
        for safe in ["report.pdf", "photo.jpg", "notes.txt", "song.mp3", "archive.zip", "README"] {
            XCTAssertFalse(try file(named: safe).canRunCode, safe)
        }
    }
}
