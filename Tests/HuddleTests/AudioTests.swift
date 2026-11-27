import AVFoundation
import XCTest
@testable import Huddle

/// Voice messages and other audio, made playable (AudioLoader.swift, OggOpusDecoder.swift): what
/// a file decodes to, and that a file built to unpack to gigabytes is turned away.
final class AudioTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// The fields of a 16-bit PCM WAV header.
    private struct WAV {
        let channels: Int, rate: Int, dataSize: Int, riffSize: Int
        init(_ data: Data) throws {
            XCTAssertGreaterThanOrEqual(data.count, 44)
            func u32(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 | Int(data[at + 2]) << 16 | Int(data[at + 3]) << 24 }
            func u16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
            XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
            XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
            XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
            XCTAssertEqual(u16(20), 1, "PCM")
            XCTAssertEqual(u16(34), 16, "bits per sample")
            channels = u16(22)
            rate = u32(24)
            XCTAssertEqual(u32(28), rate * channels * 2, "bytes per second")
            XCTAssertEqual(u16(32), channels * 2, "bytes per frame")
            riffSize = u32(4)
            dataSize = u32(40)
        }
    }

    func testAVoiceMessageDecodes() throws {
        let wav = try AudioPreparer.playableData(from: fixture("voice.ogg"))
        let header = try WAV(wav)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.rate, 48_000)
        XCTAssertEqual(header.dataSize, wav.count - 44)
        XCTAssertEqual(header.riffSize, wav.count - 8)
        // As decoded when the decoder was changed to write straight into the file.
        XCTAssertEqual(wav.count, 806_444)
    }

    func testOggVorbisDecodesWithTheSystemsReader() throws {
        let wav = try AudioPreparer.playableData(from: fixture("chime.ogg"))
        let header = try WAV(wav)
        XCTAssertEqual(header.channels, 2)
        XCTAssertEqual(header.rate, 44_100)
        XCTAssertEqual(header.dataSize, wav.count - 44)
        XCTAssertEqual(wav.count, 529_452)
    }

    /// What Huddle records, Huddle plays: two seconds of tone, encoded and decoded again.
    func testARecordingRoundTrips() throws {
        let encoder = try OggOpusEncoder()
        let format = OggOpusEncoder.inputFormat
        let frames = 48_000 * 2
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<frames { samples[i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        encoder.append(buffer)
        let ogg = encoder.finish()
        XCTAssertTrue(OggOpusDecoder.isOgg(ogg))
        let wav = try OggOpusDecoder.wav(from: ogg)
        let header = try WAV(wav)
        XCTAssertEqual(header.channels, 1)
        // Two seconds of 16-bit mono, give or take a packet.
        XCTAssertEqual(Double(header.dataSize) / 2 / 48_000, 2, accuracy: 0.03)
    }

    // MARK: Files built to unpack to gigabytes

    /// An Ogg Opus file of `packets` one-byte-and-a-bit packets, each saying it holds
    /// 63 × 60 ms, with a header stating `stated` samples: a few kilobytes claiming hours.
    private func craftedOgg(channels: UInt8, packets: Int, stated: Int64) -> Data {
        var file = Data()
        var sequence: UInt32 = 0
        func page(_ packets: [Data], granule: Int64, flags: UInt8) {
            var header = Data("OggS".utf8)
            header.append(0)                          // version
            header.append(flags)
            withUnsafeBytes(of: granule.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(7).littleEndian) { header.append(contentsOf: $0) }      // serial
            withUnsafeBytes(of: sequence.littleEndian) { header.append(contentsOf: $0) }
            header.append(contentsOf: [0, 0, 0, 0])   // checksum, which the decoder doesn't read
            header.append(UInt8(packets.count))
            for packet in packets { header.append(UInt8(packet.count)) }
            file.append(header)
            for packet in packets { file.append(packet) }
            sequence += 1
        }
        var head = Data("OpusHead".utf8)
        head.append(contentsOf: [1, channels, 0x38, 0x01])        // version, channels, pre-skip 312
        withUnsafeBytes(of: UInt32(48_000).littleEndian) { head.append(contentsOf: $0) }
        head.append(contentsOf: [0, 0, 0])                         // gain, mapping
        page([head], granule: 0, flags: 2)
        page([Data("OpusTags".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 0])], granule: 0, flags: 0)
        // TOC 0x1B: SILK, 60 ms frames, code 3; then 63 frames.
        let packet = Data([0x1B, 0x3F])
        var left = packets
        while left > 0 {
            let count = min(left, 255)
            left -= count
            page(Array(repeating: packet, count: count), granule: left == 0 ? stated + 312 : -1, flags: left == 0 ? 4 : 0)
        }
        return file
    }

    func testPacketsClaimingHoursAreTurnedAway() {
        // States one second; its packets claim 63 × 60 ms × 800 = 50 minutes.
        let ogg = craftedOgg(channels: 1, packets: 800, stated: 48_000)
        XCTAssertLessThan(ogg.count, 10_000)
        XCTAssertThrowsError(try OggOpusDecoder.wav(from: ogg)) { error in
            guard case OggOpusDecoder.Failure.tooLong = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try AudioPreparer.playableData(from: ogg)) { error in
            XCTAssertEqual(error as? AudioLoadError, .tooLong)
        }
    }

    func testStereoGetsHalfTheTime() {
        // 30 minutes stated: within 45 for one channel, beyond it for two.
        let thirtyMinutes = Int64(30 * 60 * 48_000)
        XCTAssertThrowsError(try OggOpusDecoder.wav(from: craftedOgg(channels: 2, packets: 1, stated: thirtyMinutes))) { error in
            guard case OggOpusDecoder.Failure.tooLong = error else { return XCTFail("\(error)") }
        }
    }

    func testTheLimitIsAQuarterOfAGigabyte() {
        XCTAssertEqual(OggOpusDecoder.maximumSamples, 45 * 60 * 48_000)
        XCTAssertLessThanOrEqual(OggOpusDecoder.maximumSamples * 2, 260 * 1_000_000)
    }

    func testNotAudioIsUnsupported() {
        XCTAssertThrowsError(try AudioPreparer.playableData(from: Data("not really audio ".utf8))) { error in
            XCTAssertEqual(error as? AudioLoadError, .unsupported)
        }
    }

    func testAWAVHeaderSaysWhatFollows() throws {
        var file = WAVFile.header(dataSize: 0, channels: 2, sampleRate: 44_100)
        file.append(Data(count: 400))
        WAVFile.setDataSize(of: &file, channels: 2, sampleRate: 44_100)
        let header = try WAV(file)
        XCTAssertEqual(header.dataSize, 400)
        XCTAssertEqual(header.riffSize, 436)
        // Out-of-range values make a file that doesn't play, not a crash.
        _ = WAVFile.header(dataSize: Int.max / 2, channels: 99_999, sampleRate: .infinity)
    }
}
