import AppKit
import SwiftUI
import Perception

/// In place of the message field while a voice message is recorded: a pulsing red dot and the
/// time, the sound as it comes in, and a button to stop and play it back.
struct VoiceRecordingBar: View {
    let phase: VoiceRecorder.Phase
    let elapsed: TimeInterval
    let levels: [Float]
    let stop: () -> Void
    @State private var isHoveringStop = false

    var body: some View { WithPerceptionTracking {
        HStack(spacing: 10) {
            RecordingDot(isRecording: phase == .recording)
            Text(Self.clock(elapsed))
                .font(.body.monospacedDigit())
                .foregroundStyle(phase == .recording ? .primary : .secondary)
                .frame(minWidth: 36, alignment: .leading)
                .accessibilityHidden(true)
            LiveWaveform(levels: levels)
                .frame(height: 16)
                .accessibilityHidden(true)
            Button(action: stop) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 17))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isHoveringStop ? Color.red : Color.secondary)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(phase != .recording)
            .onHoverInFrontWindow { isHoveringStop = $0 }
            .help("Stop recording, to listen before sending")
            .accessibilityLabel("Stop recording")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(phase == .starting ? "Starting to record" : "Recording voice message, \(Self.spoken(elapsed))")
    } }

    /// "0:07", "12:30".
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    static func spoken(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds)).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

/// Red and gently pulsing while recording; grey while the microphone starts.
private struct RecordingDot: View {
    let isRecording: Bool
    @State private var isDim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View { WithPerceptionTracking {
        Circle()
            .fill(isRecording ? Color.red : Color.secondary.opacity(0.5))
            .frame(width: 9, height: 9)
            .opacity(isRecording && isDim && !reduceMotion ? 0.35 : 1)
            .animation(isRecording && !reduceMotion ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default,
                       value: isDim)
            .onAppear { isDim = true }
            .accessibilityHidden(true)
    } }
}

/// The sound coming in, as bars: from the left at first, then moving along with the newest at
/// the right end.
private struct LiveWaveform: View {
    let levels: [Float]
    private static let barWidth: CGFloat = 2.5
    private static let gap: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            // A bar a tenth of a second: two of the recorder's loudness readings, the louder.
            let bars = stride(from: 0, to: levels.count, by: 2).map { index in
                max(levels[index], index + 1 < levels.count ? levels[index + 1] : 0)
            }
            let step = Self.barWidth + Self.gap
            let room = max(Int((size.width + Self.gap) / step), 1)
            let shown = bars.suffix(room)
            for (offset, level) in shown.enumerated() {
                let height = max(2.5, CGFloat(level) * size.height)
                let bar = CGRect(x: CGFloat(offset) * step, y: (size.height - height) / 2,
                                 width: Self.barWidth, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: Self.barWidth / 2), with: .color(.accentColor))
            }
        }
    }
}

/// In place of the attach button while there's a voice message in the composer: deletes it.
struct DeleteRecordingButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View { WithPerceptionTracking {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(isHovering ? 0.12 : 0.07), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help("Delete voice message")
        .accessibilityLabel("Delete voice message")
    } }
}

extension VoiceRecorder.Failure {
    var title: String {
        switch self {
        case .microphoneDenied: "Huddle Can’t Use the Microphone"
        case .noMicrophone: "No Microphone"
        case .couldNotStart: "Couldn’t Start Recording"
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied:
            "Allow Huddle in System Settings ▸ Privacy & Security ▸ Microphone, then try again."
        case .noMicrophone:
            "Connect a microphone, or choose one in System Settings ▸ Sound, then try again."
        case .couldNotStart:
            "The microphone didn’t start. Try again, or choose another one in System Settings ▸ Sound."
        }
    }

    /// Where the fix is.
    var settingsURL: URL? {
        switch self {
        case .microphoneDenied: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .noMicrophone, .couldNotStart: URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input")
        }
    }
}
