import AVFoundation
import MatrixRustSDK

/// An audio message as the timeline shows it.
struct AudioAttachment: Equatable {
    let media: MediaRef
    let filename: String
    let caption: String?
    /// As the sender reported it; the real length is known once the audio has loaded.
    let duration: TimeInterval?
    /// Bar heights from 0 to 1, for drawing the sound's shape. Empty if the sender gave none.
    let waveform: [Float]
    /// A recording made in the chat, as opposed to an audio file that was attached.
    let isVoice: Bool

    static let barCount = 48

    init(_ content: AudioMessageContent) {
        media = MediaRef(source: content.source)
        filename = content.filename
        caption = content.caption
        duration = content.audio?.duration ?? content.info?.duration
        waveform = Self.bars(from: content.audio?.waveform ?? [])
        isVoice = content.voice != nil
    }

    /// Fits the sender's waveform, which can be any length, to a fixed number of bars: the
    /// loudest point of each stretch when there are more samples than bars, a blend between
    /// neighbours when there are fewer. Scaled so the loudest bar is full height.
    static func bars(from waveform: [UInt16], count: Int = barCount) -> [Float] {
        guard waveform.count > 1, let peak = waveform.max(), peak > 0 else { return [] }
        return (0..<count).map { index in
            let value: Float
            if waveform.count >= count {
                let start = index * waveform.count / count
                let end = max(start + 1, (index + 1) * waveform.count / count)
                value = Float(waveform[start..<min(end, waveform.count)].max() ?? 0)
            } else {
                let position = Float(index) * Float(waveform.count - 1) / Float(count - 1)
                let lower = Int(position)
                let upper = min(lower + 1, waveform.count - 1)
                let blend = position - Float(lower)
                value = Float(waveform[lower]) * (1 - blend) + Float(waveform[upper]) * blend
            }
            return value / Float(peak)
        }
    }
}

enum AudioLoadError: Error {
    case download
    case unsupported
    case tooLong

    var message: String {
        switch self {
        case .download: "Couldn't load this audio. Click to try again."
        case .unsupported: "Huddle can't play this audio format."
        case .tooLong: "This recording is too long to play in Huddle."
        }
    }
}

/// Turns an audio file as sent into something `AVAudioPlayer` will play.
enum AudioPreparer {
    static func playableData(from data: Data) throws -> Data {
        if OggOpusDecoder.isOgg(data) {
            do {
                return try OggOpusDecoder.wav(from: data)
            } catch OggOpusDecoder.Failure.tooLong {
                throw AudioLoadError.tooLong
            } catch {
                // Ogg holding something other than Opus (Vorbis, say): recent systems can read it.
                return try systemDecoded(data, fileExtension: "ogg")
            }
        }
        // MP3, AAC, FLAC, WAV and the rest play as they are. Only the file is examined here; the
        // sound hardware isn't touched until playback starts.
        if let player = try? AVAudioPlayer(data: data), player.duration > 0 {
            return data
        }
        throw AudioLoadError.unsupported
    }

    /// Decodes with the system's own file reader, which needs a file on disk. The file lives in a
    /// folder only this user can read, for the moment the decoding takes.
    private static func systemDecoded(_ data: Data, fileExtension: String) throws -> Data {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "app.huddle.Huddle") + ".audio", isDirectory: true)
        let url = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(fileExtension)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard manager.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw AudioLoadError.unsupported
            }
            defer { try? manager.removeItem(at: url) }

            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
            let format = file.processingFormat
            guard file.length > 0, Double(file.length) / format.sampleRate <= OggOpusDecoder.maximumDuration else {
                throw file.length > 0 ? AudioLoadError.tooLong : AudioLoadError.unsupported
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
                throw AudioLoadError.unsupported
            }
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let channel = buffer.int16ChannelData else { throw AudioLoadError.unsupported }
            let channels = Int(format.channelCount)
            let samples = Array(UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength) * channels))
            return WAVFile.data(samples: samples, channels: channels, sampleRate: format.sampleRate)
        } catch let error as AudioLoadError {
            throw error
        } catch {
            throw AudioLoadError.unsupported
        }
    }
}
