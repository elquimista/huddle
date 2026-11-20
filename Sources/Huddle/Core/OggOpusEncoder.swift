import AVFoundation

/// Encodes sound as Ogg Opus, the format Matrix voice messages are sent in (Element records
/// them so), with the system's own Opus encoder. Sound is taken as it's recorded and only the
/// small Opus packets are kept, so a long recording is never held in memory as raw audio.
final class OggOpusEncoder {
    static let sampleRate: Double = 48_000
    /// What `append` takes: mono, 48 kHz, as floating point.
    static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                           channels: 1, interleaved: false)!

    enum Failure: Error {
        case noEncoder
    }

    private let converter: AVAudioConverter
    private let opusFormat: AVAudioFormat
    private var packets: [Data] = []
    /// Samples given, at 48 kHz.
    private(set) var sampleCount = 0
    private var pending: AVAudioPCMBuffer?

    /// - Parameter bitRate: 32 kbit/s, as Element sends voice: clear speech, about 4 KB a second.
    init(bitRate: Int = 32_000) throws {
        var description = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &description),
              let converter = AVAudioConverter(from: Self.inputFormat, to: opus) else { throw Failure.noEncoder }
        converter.bitRate = bitRate
        self.converter = converter
        opusFormat = opus
    }

    /// Takes more sound, in `inputFormat`.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        sampleCount += Int(buffer.frameLength)
        pending = buffer
        drain(ending: false)
    }

    /// Everything given, as an Ogg Opus file. The encoder is spent afterwards.
    func finish() -> Data {
        drain(ending: true)
        return OggOpusWriter.file(packets: packets, preSkip: Int(converter.primeInfo.leadingFrames),
                                  sampleCount: sampleCount)
    }

    /// Encodes what has been given so far, as far as whole packets go; with `ending`, the rest
    /// too, padded out.
    private func drain(ending: Bool) {
        let largest = max(converter.maximumOutputPacketSize, 1500)
        while true {
            let output = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 32, maximumPacketSize: largest)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { [self] _, inputStatus in
                if let buffer = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return buffer
                }
                inputStatus.pointee = ending ? .endOfStream : .noDataNow
                return nil
            }
            if let descriptions = output.packetDescriptions {
                for index in 0..<Int(output.packetCount) {
                    let description = descriptions[index]
                    packets.append(Data(bytes: output.data.advanced(by: Int(description.mStartOffset)),
                                        count: Int(description.mDataByteSize)))
                }
            }
            // More waiting only while the output came back full.
            if status != .haveData { break }
        }
    }
}

/// Wraps Opus packets in an Ogg container (RFC 7845): a page with the stream's header, one with
/// its tags, then the sound, a second or so to a page.
enum OggOpusWriter {
    static func file(packets: [Data], preSkip: Int, sampleCount: Int, vendor: String = "Huddle") -> Data {
        let serial = UInt32.random(in: 1...UInt32.max)
        var file = Data()
        var sequence: UInt32 = 0
        func page(_ contents: [Data], granule: Int64, flags: UInt8) {
            file.append(Self.page(contents, granule: granule, serial: serial, sequence: sequence, flags: flags))
            sequence += 1
        }

        var head = Data("OpusHead".utf8)
        head.append(1)                                  // version
        head.append(1)                                  // channels
        head.append(littleEndian: UInt16(clamping: preSkip))
        head.append(littleEndian: UInt32(48_000))       // the rate it was recorded at
        head.append(littleEndian: UInt16(0))            // output gain
        head.append(0)                                  // channel mapping: mono or stereo
        page([head], granule: 0, flags: 0x02)           // first page of the stream

        var tags = Data("OpusTags".utf8)
        tags.append(littleEndian: UInt32(vendor.utf8.count))
        tags.append(contentsOf: vendor.utf8)
        tags.append(littleEndian: UInt32(0))            // no comments
        page([tags], granule: 0, flags: 0)

        // The end, after the encoder's warm-up: where the sound given stops, not the padding.
        let end = Int64(preSkip + sampleCount)
        var batch: [Data] = []
        var segments = 0
        var decoded: Int64 = 0
        for (index, packet) in packets.enumerated() {
            let lacing = packet.count / 255 + 1
            if !batch.isEmpty, segments + lacing > 255 || batch.count >= 50 {
                page(batch, granule: min(decoded, end), flags: 0)
                batch = []
                segments = 0
            }
            batch.append(packet)
            segments += lacing
            decoded += Int64(OggOpusDecoder.sampleCount(ofPacket: packet))
            if index == packets.count - 1 { page(batch, granule: end, flags: 0x04) }      // the last
        }
        if packets.isEmpty { page([], granule: end, flags: 0x04) }
        return file
    }

    /// One page: its header, the table of segment lengths, then the packets, checksummed.
    private static func page(_ packets: [Data], granule: Int64, serial: UInt32, sequence: UInt32, flags: UInt8) -> Data {
        var lacing: [UInt8] = []
        for packet in packets {
            lacing += Array(repeating: 255, count: packet.count / 255)
            lacing.append(UInt8(packet.count % 255))
        }
        var page = Data("OggS".utf8)
        page.append(0)                                  // version
        page.append(flags)
        page.append(littleEndian: UInt64(bitPattern: granule))
        page.append(littleEndian: serial)
        page.append(littleEndian: sequence)
        page.append(littleEndian: UInt32(0))            // checksum, filled in below
        page.append(UInt8(lacing.count))
        page.append(contentsOf: lacing)
        for packet in packets { page.append(packet) }
        let checksum = crc(page)
        page.replaceSubrange(22..<26, with: withUnsafeBytes(of: checksum.littleEndian) { Data($0) })
        return page
    }

    /// Ogg's CRC-32: polynomial 0x04C11DB7, unreflected, starting from zero.
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = value & 0x8000_0000 != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1 }
        return value
    }

    private static func crc(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { crc, byte in (crc << 8) ^ table[Int((crc >> 24) ^ UInt32(byte))] }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
