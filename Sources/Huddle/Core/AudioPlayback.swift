import AVFoundation
import CoreAudio
import MatrixRustSDK
import Observation

/// Plays audio messages, one at a time, for the whole app.
///
/// Nothing here calls into the sound hardware on the main thread. Starting an output device can
/// take seconds (a Bluetooth headset waking, a virtual device that isn't being listened to), and
/// the interface must stay responsive through that. So the player lives on its own queue
/// (`AudioVoice`), and this class keeps a clock of its own for drawing progress, corrected against
/// the real player a couple of times a second.
@MainActor @Observable
final class AudioPlayback {
    static let shared = AudioPlayback()

    enum Phase: Equatable {
        /// Downloading, decoding, or waiting for the sound output to start.
        case loading
        case playing
        case paused
    }

    static let rates: [Float] = [1, 1.5, 2]

    /// The message whose audio is loaded or loading. Nil when nothing is.
    private(set) var currentID: String?
    private(set) var phase: Phase?
    /// Length of the loaded audio, measured from the audio itself.
    private(set) var duration: TimeInterval = 0
    /// Why a message's audio wouldn't play, by message, until it is tried again.
    private(set) var failures: [String: AudioLoadError] = [:]
    /// Set when the audio is ready but the Mac's sound output is taking its time: the name of
    /// that output, or an empty string if it couldn't be found out.
    private(set) var slowOutput: String?
    /// Goes up whenever the position is set (a seek, a pause, a correction), so views showing it
    /// redraw even while nothing is animating.
    private(set) var clockChanges = 0
    private(set) var rate: Float = {
        let stored = UserDefaults.standard.float(forKey: "audioPlaybackRate")
        return AudioPlayback.rates.contains(stored) ? stored : 1
    }()

    @ObservationIgnored private var voice: AudioVoice?
    @ObservationIgnored private var loading: Task<Void, Never>?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    /// The timeline the audio was started from, so leaving it can stop the sound.
    @ObservationIgnored private var owner: ObjectIdentifier?
    /// Goes up whenever what is loaded changes; late answers about older audio are dropped.
    @ObservationIgnored private var session = 0
    /// Goes up on every pause, resume, seek and speed change; a position report that was asked
    /// for before the latest of them is out of date.
    @ObservationIgnored private var revision = 0
    /// Position at `clockStart`, and when that was; nil while not advancing.
    @ObservationIgnored private var clockPosition: TimeInterval = 0
    @ObservationIgnored private var clockStart: Date?

    /// Where the audio has got to. Not observed: read it once per frame while playing.
    var currentTime: TimeInterval {
        guard let clockStart else { return clockPosition }
        return min(clockPosition + Date().timeIntervalSince(clockStart) * Double(rate), duration)
    }

    func phase(of id: String) -> Phase? { currentID == id ? phase : nil }

    // MARK: Controls

    /// Play, pause or resume a message's audio. While it is still loading, cancel.
    func toggle(id: String, source: MediaSource, media: MediaLoader, owner: AnyObject) {
        toggle(id: id, load: { try await media.playableAudio(source: source) }, owner: owner)
    }

    /// The same, for audio on this Mac: a voice message recorded and not yet sent.
    func toggle(id: String, localURL url: URL, owner: AnyObject) {
        toggle(id: id, load: { try Self.playableAudio(at: url) }, owner: owner)
    }

    private func toggle(id: String, load: @escaping @Sendable () async throws -> Data, owner: AnyObject) {
        guard currentID == id else {
            start(id: id, load: load, owner: owner, at: 0)
            return
        }
        switch phase {
        case .loading:
            stop()
        case .playing:
            setClock(currentTime, running: false)
            phase = .paused
            apply { $0.pause(then: $1) }
        case .paused:
            phase = .playing
            // The clock starts when the player says it has.
            apply { $0.resume(then: $1) }
        case nil:
            break
        }
    }

    /// Jump to a point in a message's audio, as a fraction of its length. On audio that isn't
    /// loaded yet this starts playing from there.
    func seek(id: String, source: MediaSource, media: MediaLoader, owner: AnyObject, to fraction: Double) {
        seek(id: id, load: { try await media.playableAudio(source: source) }, owner: owner, to: fraction)
    }

    func seek(id: String, localURL url: URL, owner: AnyObject, to fraction: Double) {
        seek(id: id, load: { try Self.playableAudio(at: url) }, owner: owner, to: fraction)
    }

    private func seek(id: String, load: @escaping @Sendable () async throws -> Data, owner: AnyObject, to fraction: Double) {
        let fraction = min(max(fraction, 0), 1)
        guard currentID == id else {
            start(id: id, load: load, owner: owner, at: fraction)
            return
        }
        guard phase == .playing || phase == .paused else { return }
        setClock(fraction * duration, running: phase == .playing)
        apply { $0.seek(to: fraction, then: $1) }
    }

    /// 1× → 1.5× → 2× → 1×. Kept for next time.
    func cycleRate() {
        let position = currentTime
        let index = Self.rates.firstIndex(of: rate) ?? 0
        rate = Self.rates[(index + 1) % Self.rates.count]
        UserDefaults.standard.set(rate, forKey: "audioPlaybackRate")
        setClock(position, running: clockStart != nil)
        let rate = rate
        apply { $0.setRate(rate, then: $1) }
    }

    func stop() {
        session += 1
        loading?.cancel()
        loading = nil
        monitor?.cancel()
        monitor = nil
        voice?.stop()
        voice = nil
        currentID = nil
        phase = nil
        duration = 0
        owner = nil
        slowOutput = nil
        setClock(0, running: false)
    }

    /// Stops the audio if it was started from this timeline, which is going away.
    func stop(owner: AnyObject) {
        if self.owner == ObjectIdentifier(owner) { stop() }
    }

    // MARK: Clock

    private func setClock(_ position: TimeInterval, running: Bool) {
        clockPosition = position
        clockStart = running ? Date() : nil
        clockChanges += 1
    }

    /// Sends a command to the player and, when it answers, sets the clock by where it really is.
    private func apply(_ command: (AudioVoice, @escaping @Sendable (AudioVoice.Status?) -> Void) -> Void) {
        guard let voice else { return }
        revision += 1
        let (session, revision) = (session, revision)
        command(voice) { [weak self] status in
            Task { @MainActor in self?.synchronize(with: status, session: session, revision: revision) }
        }
    }

    private func synchronize(with status: AudioVoice.Status?, session: Int, revision: Int) {
        guard session == self.session, revision == self.revision, let status else { return }
        if phase == .playing, !status.isPlaying {
            stop()      // reached the end: back to the start, ready to play again
        } else if phase == .playing || phase == .paused {
            setClock(status.time, running: status.isPlaying)
        }
    }

    // MARK: Loading

    private nonisolated static func playableAudio(at url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url) else { throw AudioLoadError.download }
        return try AudioPreparer.playableData(from: data)
    }

    private func start(id: String, load: @escaping @Sendable () async throws -> Data, owner: AnyObject, at fraction: Double) {
        stop()
        VideoPlayback.shared.pause()
        let session = session
        currentID = id
        phase = .loading
        failures[id] = nil
        self.owner = ObjectIdentifier(owner)

        let voice = AudioVoice()
        voice.onFinish = { [weak self] in
            Task { @MainActor in
                if let self, self.session == session, self.phase == .playing { self.stop() }
            }
        }
        self.voice = voice

        loading = Task { [weak self] in
            do {
                let data = try await load()
                guard let self, self.session == session else { return }

                // From here any wait is for the sound output, not the network. Say so if it drags.
                let patience = Task { [weak self] in
                    try await Task.sleep(for: .seconds(2.5))
                    let name = await AudioVoice.defaultOutputName()
                    if let self, self.session == session, self.phase == .loading { self.slowOutput = name ?? "" }
                }
                defer { patience.cancel() }

                let status = try await voice.start(data: data, at: fraction, rate: self.rate,
                                                   muted: DevHooks.mutesAudio, device: DevHooks.audioDevice,
                                                   stall: DevHooks.audioStartDelay)
                guard self.session == session else { return }
                self.slowOutput = nil
                self.duration = status.duration
                self.setClock(status.time, running: true)
                self.phase = .playing
                self.watch(session: session)
            } catch {
                guard let self, self.session == session else { return }
                self.stop()
                self.failures[id] = error as? AudioLoadError ?? .unsupported
            }
        }
    }

    /// While playing, checks the real player twice a second: to notice the end, and to keep the
    /// drawn position from drifting away from the sound.
    private func watch(session: Int) {
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.session == session, !Task.isCancelled else { return }
                guard self.phase == .playing, let voice = self.voice else { continue }
                let revision = self.revision
                voice.status { [weak self] status in
                    Task { @MainActor in self?.synchronize(with: status, session: session, revision: revision) }
                }
            }
        }
    }
}

/// One piece of loaded audio and the `AVAudioPlayer` playing it. Every call that reaches the
/// player runs on this object's own queue, never the main thread; answers come back through
/// completion handlers on that queue.
final class AudioVoice: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    struct Status: Sendable {
        var time: TimeInterval
        var duration: TimeInterval
        var isPlaying: Bool
    }

    /// Called, on some background thread, when the audio plays to its end.
    var onFinish: (@Sendable () -> Void)?

    private let queue = DispatchQueue(label: "app.huddle.audio-voice", qos: .userInitiated)
    private var player: AVAudioPlayer?      // only touched on `queue`
    private let cancelled = Flag()

    /// Creates the player and starts it. Returns once sound is actually under way, which is as
    /// long as the output device takes to start.
    /// - Parameter stall: seconds to wait first, for testing how a slow device is handled.
    func start(data: Data, at fraction: Double, rate: Float, muted: Bool, device: String?,
               stall: TimeInterval = 0) async throws -> Status {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    if stall > 0 { Thread.sleep(forTimeInterval: stall) }
                    let player = try AVAudioPlayer(data: data)
                    player.delegate = self
                    player.enableRate = true
                    player.rate = rate
                    if muted { player.volume = 0 }
                    if let device { player.currentDevice = device }
                    guard !cancelled.isSet, player.prepareToPlay(), player.duration > 0 else {
                        throw cancelled.isSet ? CancellationError() : AudioLoadError.unsupported
                    }
                    // The wait for the device is over; if the user gave up meanwhile, stay silent.
                    guard !cancelled.isSet else { throw CancellationError() }
                    player.currentTime = min(fraction * player.duration, max(player.duration - 0.05, 0))
                    guard player.play() else { throw AudioLoadError.unsupported }
                    self.player = player
                    continuation.resume(returning: status(of: player))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func pause(then report: @escaping @Sendable (Status?) -> Void) {
        perform(report) { $0.pause() }
    }

    func resume(then report: @escaping @Sendable (Status?) -> Void) {
        perform(report) { $0.play() }
    }

    func seek(to fraction: Double, then report: @escaping @Sendable (Status?) -> Void) {
        // Just short of the very end, so a drag to the far right doesn't finish the audio.
        perform(report) { $0.currentTime = min(fraction * $0.duration, max($0.duration - 0.05, 0)) }
    }

    func setRate(_ rate: Float, then report: @escaping @Sendable (Status?) -> Void) {
        perform(report) { $0.rate = rate }
    }

    func status(then report: @escaping @Sendable (Status?) -> Void) {
        perform(report) { _ in }
    }

    /// Silences this audio for good. Safe to call while `start` is still waiting for the device.
    func stop() {
        cancelled.set()
        queue.async { [self] in
            player?.stop()
            player = nil
        }
    }

    private func perform(_ report: @escaping @Sendable (Status?) -> Void, _ change: @escaping @Sendable (AVAudioPlayer) -> Void) {
        queue.async { [self] in
            guard let player, !cancelled.isSet else { return report(nil) }
            change(player)
            report(status(of: player))
        }
    }

    private func status(of player: AVAudioPlayer) -> Status {
        Status(time: player.currentTime, duration: player.duration, isPlaying: player.isPlaying)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if !cancelled.isSet { onFinish?() }
    }

    /// The name of the Mac's current sound output, such as "MacBook Pro Speakers".
    static func defaultOutputName() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var device = AudioDeviceID(0)
                var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                         mScope: kAudioObjectPropertyScopeGlobal,
                                                         mElement: kAudioObjectPropertyElementMain)
                guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
                      device != 0 else { return continuation.resume(returning: nil) }
                var name: Unmanaged<CFString>?
                size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                address.mSelector = kAudioObjectPropertyName
                guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: name?.takeRetainedValue() as String?)
            }
        }
    }

    /// A yes/no that can be read from any thread, including while the queue is busy waiting.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}
