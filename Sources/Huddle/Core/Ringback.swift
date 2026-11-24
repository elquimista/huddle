import AVFoundation

/// The tone a caller hears while the other person's phone rings: 440 and 480 Hz together, two
/// seconds on and four off, as phones in North America ring back. Played from the moment the
/// call's invite has gone out until it's answered, declined, given up or run out.
@MainActor
final class Ringback {
    private var engine: AVAudioEngine?
    private var isOn = false

    func start() {
        guard !isOn else { return }
        isOn = true
        // For scripted tests, which keep Dev quiet (HUDDLE_DEV_MUTE_AUDIO).
        if AppEnvironment.isDev { print("DEV_RINGBACK on"); fflush(stdout) }
        guard !DevHooks.mutesAudio,
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let cycle = Self.cycle(format: format) else { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return      // no sound to be had (no output device): the call goes on without it
        }
        player.scheduleBuffer(cycle, at: nil, options: .loops)
        player.play()
        self.engine = engine
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        if AppEnvironment.isDev { print("DEV_RINGBACK off"); fflush(stdout) }
        engine?.stop()
        engine = nil
    }

    /// One ring and the pause after it. The ring fades in and out over a few milliseconds, so it
    /// doesn't click, and is about as loud as the ring of a call coming in (macOS's Submarine).
    static func cycle(format: AVAudioFormat, ring: Double = 2, pause: Double = 4) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let ringFrames = Int(ring * rate)
        let frames = AVAudioFrameCount(Double(ringFrames) + pause * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let fade = Int(0.02 * rate)
        for frame in 0..<Int(frames) {
            guard frame < ringFrames else {
                samples[frame] = 0
                continue
            }
            let time = Double(frame) / rate
            let edge = min(frame, ringFrames - 1 - frame)
            let envelope = edge < fade ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(fade)) : 1
            let tone = sin(2 * .pi * 440 * time) + sin(2 * .pi * 480 * time)
            samples[frame] = Float(0.08 * envelope * tone)
        }
        return buffer
    }
}
