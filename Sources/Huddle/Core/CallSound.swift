import AppKit

/// The short sounds that mark a call's turns: macOS's own, as FaceTime plays them. Like the
/// ringtone, they're the call's, not alerts: they play whatever Settings says of alert sounds.
@MainActor
enum CallSound: String {
    /// A call over that had been answered (or that you stopped yourself): FaceTime's chime.
    case ended = "vc~ended"
    /// The person called didn't take it: declined, or no answer.
    case busy = "busy_tone_cept"
    /// In a room's call you're in, someone else came in, or went.
    case joined = "multiway-join"
    case left = "multiway-leave"

    private static let folder = URL(fileURLWithPath:
        "/System/Library/PrivateFrameworks/TelephonyUtilities.framework/Versions/A/Resources", isDirectory: true)

    /// Held while they play: a sound let go of stops.
    private static var playing: [NSSound] = []

    /// Plays it, unless this macOS doesn't have it (then nothing, as before there was any).
    func play() {
        // For scripted tests, which keep Dev quiet (HUDDLE_DEV_MUTE_AUDIO).
        if AppEnvironment.isDev {
            print("DEV_CALL_SOUND \(self)")
            fflush(stdout)
        }
        guard !DevHooks.mutesAudio,
              let sound = NSSound(contentsOf: Self.folder.appendingPathComponent(rawValue + ".caf"), byReference: true)
        else { return }
        Self.playing.removeAll { !$0.isPlaying }
        if sound.play() { Self.playing.append(sound) }
    }
}
