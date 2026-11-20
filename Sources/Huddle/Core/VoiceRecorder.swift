import AVFoundation
import Observation

/// A voice message recorded and waiting in its composer to be sent.
struct VoiceRecording: Equatable {
    let id = UUID()
    /// The Ogg Opus file, among those cleared a day after.
    let url: URL
    let duration: TimeInterval
    /// Loudness from 0 to 1 at up to a hundred points through it, sent with it for others to draw.
    let waveform: [Float]
    let size: UInt64

    static let filename = "Voice message.ogg"
    static let mimetype = "audio/ogg"

    /// What the composer plays it back as, and its row shows while it's sent.
    var attachment: AudioAttachment {
        AudioAttachment(voiceAt: url, duration: duration, waveform: waveform)
    }

    /// How it goes into the send queue.
    var staged: StagedFile {
        StagedFile(url: url, filename: Self.filename, size: size, mimetype: Self.mimetype,
                   kind: .voice(duration: duration, waveform: waveform))
    }
}

/// Records voice messages, one at a time for the whole app, as there is one microphone. Each
/// recording belongs to a composer (by its draft key: a room's, or a thread's) and waits there
/// once stopped, to be played back and sent, or deleted. Leaving the room stops a recording
/// without losing it.
@MainActor @Observable
final class VoiceRecorder {
    static let shared = VoiceRecorder()

    /// Longest a voice message can be, as in Element: recording stops there.
    static let maximumDuration: TimeInterval = 15 * 60
    /// Shorter than this is a slip of the mouse, not a message: it's dropped.
    static let shortest: TimeInterval = 0.5
    /// Loudness is measured over this many seconds at a time.
    nonisolated static let levelInterval: TimeInterval = 0.05

    enum Phase: Equatable {
        /// Asking for the microphone, or waiting for it to start.
        case starting
        case recording
        /// Stopped; the file is being finished.
        case finishing
    }

    enum Failure: Error, Equatable {
        case microphoneDenied
        case noMicrophone
        case couldNotStart
    }

    /// The composer recording, by draft key.
    private(set) var key: String?
    private(set) var phase: Phase?
    /// How long it has been recording.
    private(set) var elapsed: TimeInterval = 0
    /// Loudness, from 0 to 1, every `levelInterval` so far.
    private(set) var levels: [Float] = []
    /// Recordings stopped and waiting to be sent, by draft key.
    private(set) var recordings: [String: VoiceRecording] = [:]
    /// Why recording couldn't start, and in which composer, to say so there.
    var failure: (key: String, reason: Failure)?

    @ObservationIgnored private var capture: VoiceCapture?
    /// Goes up whenever a recording starts or ends; late news of an earlier one is dropped.
    @ObservationIgnored private var session = 0

    func phase(for key: String) -> Phase? { self.key == key ? phase : nil }

    // MARK: Recording

    /// Starts recording for a composer, stopping one going on elsewhere (which waits in its own
    /// composer). Nothing happens where a recording is already waiting to be sent.
    func start(key: String) async {
        guard self.key != key, recordings[key] == nil else { return }
        if self.key != nil { await stop() }
        session += 1
        let session = session
        self.key = key
        phase = .starting
        elapsed = 0
        levels = []
        failure = nil
        // One sound at a time: what's playing stops for the recording.
        AudioPlayback.shared.stop()
        VideoPlayback.shared.stop()
        do {
            let fake = DevHooks.fakeMicrophone
            if fake == nil { try await Self.askForMicrophone() }
            let capture = try VoiceCapture(fakeInput: fake)
            capture.onProgress = { [weak self] samples, levels in
                Task { @MainActor in self?.progress(samples: samples, levels: levels, session: session) }
            }
            try await capture.start()
            guard self.session == session else {
                _ = await capture.finish()
                return
            }
            self.capture = capture
            phase = .recording
        } catch {
            guard self.session == session else { return }
            self.key = nil
            phase = nil
            failure = (key, error as? Failure ?? .couldNotStart)
        }
    }

    private func progress(samples: Int, levels new: [Float], session: Int) {
        guard self.session == session, phase == .recording else { return }
        elapsed = Double(samples) / OggOpusEncoder.sampleRate
        levels += new
        if elapsed >= Self.maximumDuration { Task { await stop() } }
    }

    /// Stops a composer's recording, if it's the one recording.
    func stop(_ key: String) async {
        if self.key == key { await stop() }
    }

    /// Stops recording. The recording waits in its composer, unless it was too short to keep.
    func stop() async {
        guard let key, phase == .starting || phase == .recording else { return }
        session += 1
        let capture = capture
        self.capture = nil
        guard let capture else {
            // Still starting: nothing recorded yet.
            self.key = nil
            phase = nil
            return
        }
        phase = .finishing
        let levels = levels
        let finished = await capture.finish()
        if self.key == key { self.key = nil; phase = nil }
        guard let finished, finished.duration >= Self.shortest else { return }
        recordings[key] = VoiceRecording(url: finished.url, duration: finished.duration,
                                         waveform: Self.waveform(from: levels), size: finished.size)
    }

    /// Stops recording and throws it away.
    func cancel() {
        guard key != nil else { return }
        session += 1
        let capture = capture
        self.capture = nil
        key = nil
        phase = nil
        if let capture { Task { _ = await capture.finish(keeping: false) } }
    }

    // MARK: Recordings

    /// The recording waiting in a composer, handed over to be sent.
    func take(_ key: String) -> VoiceRecording? {
        recordings.removeValue(forKey: key)
    }

    /// Deletes the recording waiting in a composer.
    func discard(_ key: String) {
        guard let recording = recordings.removeValue(forKey: key) else { return }
        if AudioPlayback.shared.currentID == Self.playbackID(for: recording) { AudioPlayback.shared.stop() }
        try? FileManager.default.removeItem(at: recording.url.deletingLastPathComponent())
    }

    /// How the player knows a recording being played back.
    static func playbackID(for recording: VoiceRecording) -> String { "voice-\(recording.id.uuidString)" }

    /// Loudness through the whole recording at up to a hundred points: the loudest moment of each
    /// stretch, so short sounds still show.
    static func waveform(from levels: [Float], points: Int = 100) -> [Float] {
        guard levels.count > points else { return levels }
        return (0..<points).map { index in
            let start = index * levels.count / points
            let end = max(start + 1, (index + 1) * levels.count / points)
            return levels[start..<min(end, levels.count)].max() ?? 0
        }
    }

    private static func askForMicrophone() async throws {
        if DevHooks.deniesMicrophone { throw Failure.microphoneDenied }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw Failure.microphoneDenied
        default:
            throw Failure.microphoneDenied
        }
    }
}

/// The sound being recorded: from the Mac's microphone through `AVAudioEngine`, made mono at
/// 48 kHz, measured for loudness and encoded as it comes. All of it happens on this object's
/// own queue, never the main thread: starting the microphone can take a moment (a Bluetooth
/// headset waking), and the interface stays responsive through that.
final class VoiceCapture: @unchecked Sendable {
    struct Finished {
        let url: URL
        let duration: TimeInterval
        let size: UInt64
    }

    /// Called on the capture's queue with the samples recorded so far and the loudness of what
    /// was just added.
    var onProgress: (@Sendable (Int, [Float]) -> Void)?

    private let queue = DispatchQueue(label: "app.huddle.voice-capture", qos: .userInitiated)
    private let encoder: OggOpusEncoder
    private let fakeInput: URL?
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var fakeFile: AVAudioFile?
    private var fakeTimer: DispatchSourceTimer?
    private var isStopped = false
    /// The loudness window being filled: its sum of squares and how many samples.
    private var windowSum: Float = 0
    private var windowCount = 0
    private let windowLength = Int(OggOpusEncoder.sampleRate * VoiceRecorder.levelInterval)

    /// - Parameter fakeInput: a sound file to record instead of the microphone (Dev testing).
    init(fakeInput: URL?) throws {
        encoder = try OggOpusEncoder()
        self.fakeInput = fakeInput
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    if let fakeInput { try startFake(fakeInput) } else { try startMicrophone() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startMicrophone() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceRecorder.Failure.noMicrophone }
        // A tenth of a second at a time. The buffer is the engine's to reuse, so it's copied.
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate / 10), format: format) { [weak self] buffer, _ in
            guard let self, let copy = Self.copy(buffer) else { return }
            self.queue.async { self.process(copy) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceRecorder.Failure.couldNotStart
        }
        self.engine = engine
    }

    /// Plays a file into the recording in real time, round and round, as if spoken.
    private func startFake(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        fakeFile = file
        let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self, let file = self.fakeFile,
                  let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
            if (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                file.framePosition = 0
                try? file.read(into: buffer, frameCount: chunk)
            }
            self.process(buffer)
        }
        timer.resume()
        fakeTimer = timer
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard !isStopped, buffer.frameLength > 0 else { return }
        let target = OggOpusEncoder.inputFormat
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 256
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var given = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { _, status in
            if given {
                status.pointee = .noDataNow
                return nil
            }
            given = true
            status.pointee = .haveData
            return buffer
        }
        guard output.frameLength > 0, let samples = output.floatChannelData?[0] else { return }
        encoder.append(output)

        var levels: [Float] = []
        for index in 0..<Int(output.frameLength) {
            windowSum += samples[index] * samples[index]
            windowCount += 1
            if windowCount == windowLength {
                levels.append(Self.level(rms: sqrt(windowSum / Float(windowCount))))
                windowSum = 0
                windowCount = 0
            }
        }
        onProgress?(encoder.sampleCount, levels)
    }

    /// Loudness as a bar's height: speech at its loudest is full height, a quiet room close to none.
    private static func level(rms: Float) -> Float {
        let decibels = 20 * log10(max(rms, 0.000_01))
        return min(max((decibels + 55) / 45, 0), 1)
    }

    /// Stops recording and finishes the file: nil if it couldn't be written, or wasn't wanted.
    func finish(keeping: Bool = true) async -> Finished? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                isStopped = true
                if let engine {
                    engine.inputNode.removeTap(onBus: 0)
                    engine.stop()
                }
                engine = nil
                fakeTimer?.cancel()
                fakeTimer = nil
                fakeFile = nil
                guard keeping else {
                    continuation.resume(returning: nil)
                    return
                }
                let data = encoder.finish()
                continuation.resume(returning: Self.write(data, duration: Double(encoder.sampleCount) / OggOpusEncoder.sampleRate))
            }
        }
    }

    /// Into a folder of its own among those cleared a day after (MediaLoader.clearOpenedFiles),
    /// readable only by this user.
    private static func write(_ data: Data, duration: TimeInterval) -> Finished? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory
            .appendingPathComponent((Bundle.main.bundleIdentifier ?? "app.huddle.Huddle") + ".files", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent(VoiceRecording.filename)
            try data.write(to: url, options: .atomic)
            return Finished(url: url, duration: duration, size: UInt64(data.count))
        } catch {
            return nil
        }
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            guard let fromData = from.mData, let toData = to.mData else { continue }
            memcpy(toData, fromData, Int(min(from.mDataByteSize, to.mDataByteSize)))
        }
        return copy
    }
}
