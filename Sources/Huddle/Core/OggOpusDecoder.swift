import AVFoundation

/// Decodes Ogg Opus, the format of Matrix voice messages, to WAV.
///
/// macOS has an Opus decoder but, before 15.4, nothing that reads the Ogg container around it,
/// and even on later versions `AVAudioPlayer` will not play such a file. So this unpacks the
/// container itself, hands the Opus packets to the system decoder, and returns audio that
/// `AVAudioPlayer` plays everywhere.
enum OggOpusDecoder {
    enum Failure: Error {
        case notOggOpus
        case tooLong
        case decodingFailed
    }

    /// Longest recording to decode: the whole of it is held in memory as 16-bit audio.
    static let maximumDuration: TimeInterval = 45 * 60
    /// Most samples, over all its channels, decoded for one recording: 45 minutes of mono at
    /// 48 kHz, or 22½ of stereo. Held once, as 16-bit audio, that is 259 MB at most.
    static let maximumSamples = Int(maximumDuration * 48_000)

    static func isOgg(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual("OggS".utf8)
    }

    /// The recording as a WAV file in memory, decoded straight into it: the audio is held once,
    /// never copied.
    static func wav(from data: Data) throws -> Data {
        let stream = try Stream(data: data)
        guard stream.duration * Double(stream.channels) <= maximumDuration else { throw Failure.tooLong }
        var wav = WAVFile.header(dataSize: 0, channels: stream.channels, sampleRate: sampleRate)
        let alreadySkipped = try decode(stream, appendingTo: &wav)
        // Drop the decoder's warm-up at the start and any padding after the true end. The stream
        // counts its warm-up from the first sample; the system decoder has already removed some.
        let samples = (wav.count - WAVFile.headerSize) / 2
        let skip = max(stream.preSkip - alreadySkipped, 0)
        let start = min(skip * stream.channels, samples)
        var end = samples
        if let count = stream.sampleCount { end = min(end, start + count * stream.channels) }
        guard end > start else { throw Failure.decodingFailed }
        wav.removeSubrange(WAVFile.headerSize + end * 2 ..< wav.count)
        wav.removeSubrange(WAVFile.headerSize ..< WAVFile.headerSize + start * 2)
        WAVFile.setDataSize(of: &wav, channels: stream.channels, sampleRate: sampleRate)
        return wav
    }

    // MARK: Container

    /// The Opus packets of the first Opus stream in an Ogg file, with what its header says.
    struct Stream {
        var channels = 0
        /// Samples at the start that are decoder warm-up, to be thrown away.
        var preSkip = 0
        /// Samples to play, after `preSkip`, per channel. Nil if the file doesn't say.
        var sampleCount: Int?
        var packets: [Data] = []

        var duration: TimeInterval {
            let samples = sampleCount ?? packets.reduce(0) { $0 + OggOpusDecoder.sampleCount(ofPacket: $1) }
            return TimeInterval(samples) / OggOpusDecoder.sampleRate
        }

        init(data: Data) throws {
            let bytes = [UInt8](data)
            var offset = 0
            var serial: UInt32?
            var pending = Data()        // a packet continuing across pages
            var sawHead = false
            var sawTags = false
            var lastGranule: Int64 = -1

            // Each page: a 27-byte header, a table of segment lengths, then the segments. A packet
            // is a run of segments ending with one shorter than 255 bytes.
            while offset + 27 <= bytes.count {
                guard bytes[offset] == 0x4F, bytes[offset + 1] == 0x67, bytes[offset + 2] == 0x67, bytes[offset + 3] == 0x53 else {
                    throw Failure.notOggOpus
                }
                let granule = Int64(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 6, as: Int64.self) })
                let pageSerial = UInt32(littleEndian: bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 14, as: UInt32.self) })
                let segmentCount = Int(bytes[offset + 26])
                let tableStart = offset + 27
                guard tableStart + segmentCount <= bytes.count else { break }
                let lengths = bytes[tableStart..<tableStart + segmentCount]
                var cursor = tableStart + segmentCount
                let pageEnd = cursor + lengths.reduce(0) { $0 + Int($1) }
                guard pageEnd <= bytes.count else { break }      // truncated file: keep what we have
                offset = pageEnd

                // A file can carry several streams; follow the one that turns out to be Opus.
                if let serial, serial != pageSerial { continue }

                for length in lengths {
                    pending.append(contentsOf: bytes[cursor..<cursor + Int(length)])
                    cursor += Int(length)
                    guard length < 255 else { continue }
                    let packet = pending
                    pending = Data()
                    if !sawHead {
                        guard packet.count >= 19, packet.prefix(8).elementsEqual("OpusHead".utf8) else {
                            if serial == nil { break }      // some other stream's first page
                            throw Failure.notOggOpus
                        }
                        serial = pageSerial
                        sawHead = true
                        channels = Int(packet[packet.startIndex + 9])
                        preSkip = Int(packet[packet.startIndex + 10]) | Int(packet[packet.startIndex + 11]) << 8
                    } else if !sawTags {
                        sawTags = true      // "OpusTags": title, artist and so on
                    } else if !packet.isEmpty {
                        packets.append(packet)
                    }
                }
                if sawHead, serial == pageSerial, granule > 0 { lastGranule = granule }
            }

            guard sawHead, (1...2).contains(channels), !packets.isEmpty else { throw Failure.notOggOpus }
            if lastGranule > Int64(preSkip) { sampleCount = Int(lastGranule) - preSkip }
        }
    }

    // MARK: Decoding

    private static let sampleRate: Double = 48_000

    /// How many samples (at 48 kHz) an Opus packet decodes to, read from its first byte.
    static func sampleCount(ofPacket packet: Data) -> Int {
        guard let toc = packet.first else { return 0 }
        let config = Int(toc >> 3)
        let frameSize: Int        // in samples at 48 kHz
        switch config {
        case 0..<12: frameSize = [480, 960, 1920, 2880][config % 4]      // SILK: 10, 20, 40, 60 ms
        case 12..<16: frameSize = [480, 960][config % 2]                 // hybrid: 10, 20 ms
        default: frameSize = [120, 240, 480, 960][config % 4]            // CELT: 2.5, 5, 10, 20 ms
        }
        let frames: Int
        switch toc & 0x03 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: frames = packet.count > 1 ? Int(packet[packet.startIndex + 1] & 0x3F) : 0
        }
        return frameSize * frames
    }

    /// Appends everything the packets decode to, as interleaved 16-bit samples, to `output`.
    /// Returns how many samples per channel of warm-up the system decoder left out of it.
    static func decode(_ stream: Stream, appendingTo output: inout Data) throws -> Int {
        let sizes = stream.packets.map(sampleCount(ofPacket:))
        // The length the packets themselves claim, not only the one the stream states at its end:
        // a crafted file can state a short one and claim hours, packet by packet.
        let limit = maximumSamples / stream.channels
        let claimed = sizes.reduce(0, +)
        guard claimed <= limit else { throw Failure.tooLong }
        // Nearly every encoder uses one packet size throughout; tell the decoder which.
        let framesPerPacket = sizes.first ?? 960
        let isUniform = sizes.dropLast().allSatisfy { $0 == framesPerPacket }

        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: isUniform ? UInt32(framesPerPacket) : 0, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(stream.channels), mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(stream.channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: format) else { throw Failure.decodingFailed }

        let largestPacket = stream.packets.map(\.count).max() ?? 0
        var next = 0
        let start = output.count
        output.reserveCapacity(start + claimed * stream.channels * 2)
        guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 5760 * 8) else { throw Failure.decodingFailed }

        while true {
            var failure: NSError?
            let status = converter.convert(to: chunk, error: &failure) { _, inputStatus in
                guard next < stream.packets.count else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                let packet = stream.packets[next]
                let buffer = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: max(largestPacket, 1))
                packet.copyBytes(to: buffer.data.assumingMemoryBound(to: UInt8.self), count: packet.count)
                buffer.byteLength = UInt32(packet.count)
                buffer.packetCount = 1
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: isUniform ? 0 : UInt32(sizes[next]),
                    mDataByteSize: UInt32(packet.count))
                next += 1
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error || failure != nil { throw Failure.decodingFailed }
            if chunk.frameLength > 0, let channel = chunk.int16ChannelData {
                let bytes = Int(chunk.frameLength) * stream.channels * 2
                channel[0].withMemoryRebound(to: UInt8.self, capacity: bytes) { output.append($0, count: bytes) }
                // Whatever the packets claimed, no more than the longest recording played.
                if output.count - start > (limit + 5760) * stream.channels * 2 { throw Failure.tooLong }
            }
            if status == .endOfStream || (status == .inputRanDry && next >= stream.packets.count) { break }
            if chunk.frameLength == 0, status != .haveData { break }
        }

        // The system decoder leaves a little of its own warm-up out of what it returns (120
        // samples, unannounced). Measure it: it is whatever the packets hold that didn't come out.
        let missing = claimed - (output.count - start) / 2 / stream.channels
        return (0...stream.preSkip).contains(missing) ? missing : 0
    }
}

/// Builds an uncompressed 16-bit WAV file in memory: a header, then the samples, interleaved,
/// one value per channel per moment.
enum WAVFile {
    static let headerSize = 44

    /// The header for `dataSize` bytes of samples, for the samples to be appended to.
    static func header(dataSize: Int, channels: Int, sampleRate: Double) -> Data {
        var file = Data(capacity: headerSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: "RIFF".utf8)
        // Clamped, not converted: a value out of range would stop the app, where a wrong header
        // only makes a file that doesn't play. (Callers keep them in range already.)
        let rate = sampleRate.isFinite ? Int(min(max(sampleRate, 0), 1_000_000)) : 0
        append(UInt32(clamping: 36 + dataSize))
        file.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))                               // size of the format block
        append(UInt16(1))                                // PCM
        append(UInt16(clamping: channels))
        append(UInt32(clamping: rate))
        append(UInt32(clamping: rate * channels * 2))    // bytes per second
        append(UInt16(clamping: channels * 2))           // bytes per sample frame
        append(UInt16(16))                               // bits per sample
        file.append(contentsOf: "data".utf8)
        append(UInt32(clamping: dataSize))
        return file
    }

    /// Rewrites the header of a file whose samples have been appended, for their number.
    static func setDataSize(of file: inout Data, channels: Int, sampleRate: Double) {
        let header = header(dataSize: file.count - headerSize, channels: channels, sampleRate: sampleRate)
        file.replaceSubrange(0..<headerSize, with: header)
    }
}
