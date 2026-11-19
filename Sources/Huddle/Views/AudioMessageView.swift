import AppKit
import MatrixRustSDK
import SwiftUI
import UniformTypeIdentifiers

/// An audio message: a play button, the sound's shape (or a plain track) to scrub through, and
/// the time. Voice messages are one line; attached files also show their name.
struct AudioMessageView: View {
    /// Identifies the message to the player.
    let id: String
    let audio: AudioAttachment
    let media: MediaLoader
    /// The timeline this row is in. Leaving it stops audio that was started from it.
    let owner: RoomTimeline

    /// Where the pointer is while dragging through the audio, as a fraction of its length.
    @State private var scrub: Double?
    /// Where playback was asked to start, shown while the audio is still loading.
    @State private var pendingStart: Double?

    private var playback: AudioPlayback { .shared }

    private static let fullScrubberWidth: CGFloat = 192
    @Environment(\.messageContentWidth) private var contentWidth

    /// Whether the speed button is showing, which it is while the audio is open.
    private var isOpen: Bool {
        let phase = playback.phase(of: id)
        return phase == .playing || phase == .paused
    }

    /// Everything beside the track: padding, the play button, the gaps, and the speed button
    /// while it shows.
    private var chrome: CGFloat { 8 + 30 + 10 + 12 + (isOpen ? 10 + 32 : 0) }

    /// In a very narrow column the time is left out rather than let the player spill over.
    private var showsTime: Bool { contentWidth - chrome - 8 - Self.timeWidth >= 48 }

    /// The track: full length where there is room, shorter in a narrow column.
    private var scrubberWidth: CGFloat {
        let room = contentWidth - chrome - (showsTime ? 8 + Self.timeWidth : 0)
        return max(48, min(Self.fullScrubberWidth, room))
    }
    /// Room for "0:00"; longer times widen it.
    private static let timeWidth: CGFloat = 34

    var body: some View {
        let phase = playback.phase(of: id)
        let failure = playback.failures[id]
        let isOpen = phase == .playing || phase == .paused
        /// Nothing more to try: the audio is in a form Huddle can't play.
        let isUnplayable = failure != nil && failure != .download

        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                playButton(phase: phase, failure: failure)
                if audio.isVoice {
                    progress(phase: phase)
                        .opacity(isUnplayable ? 0.45 : 1)
                        .allowsHitTesting(!isUnplayable)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(audio.filename.isEmpty ? "Audio" : audio.filename)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(audio.filename)
                        progress(phase: phase)
                            .opacity(isUnplayable ? 0.45 : 1)
                            .allowsHitTesting(!isUnplayable)
                    }
                    .frame(width: scrubberWidth + (showsTime ? 8 + Self.timeWidth : 0), alignment: .leading)
                }
                if isOpen {
                    speedButton
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .animation(.snappy(duration: 0.22), value: isOpen)

            if phase == .loading, let output = playback.slowOutput {
                // The audio is ready; it is the Mac's sound output that hasn't started.
                Text(output.isEmpty ? "Waiting for your Mac’s sound output…" : "Waiting for the sound output “\(output)”…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            } else if let failure {
                HStack(spacing: 6) {
                    // A failed download is an error and worth another try. A format Huddle can't
                    // play is just a fact, said quietly, with a way to keep the file.
                    if failure == .download {
                        Label(failure.message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    } else {
                        Text(failure.message)
                            .foregroundStyle(.secondary)
                        Button("Save…") { AttachmentSaver.save(audio, media: media) }
                            .buttonStyle(.link)
                    }
                }
                .font(.caption)
                .padding(.leading, 4)
            }
        }
        .onChange(of: phase) {
            if phase != .loading { pendingStart = nil }
        }
    }

    // MARK: Play button

    private func playButton(phase: AudioPlayback.Phase?, failure: AudioLoadError?) -> some View {
        let isUnplayable = failure != nil && failure != .download
        return Button {
            playback.toggle(id: id, source: audio.media.source, media: media, owner: owner)
        } label: {
            ZStack {
                Circle().fill(isUnplayable ? AnyShapeStyle(Color.primary.opacity(0.14)) : AnyShapeStyle(Color.accentColor))
                switch phase {
                case .loading:
                    LoadingArc()
                case .playing:
                    Image(systemName: "pause.fill")
                case .paused, nil:
                    if isUnplayable {
                        Image(systemName: "speaker.slash.fill")
                            .foregroundStyle(.secondary)
                    } else if failure != nil {
                        Image(systemName: "arrow.clockwise")
                    } else {
                        // The play triangle's weight sits left of its centre; nudge it to look centred.
                        Image(systemName: "play.fill").offset(x: 1)
                    }
                }
            }
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isUnplayable)
        .help(phase == .loading ? "Cancel" : "")
        .accessibilityLabel(buttonLabel(phase: phase, failure: failure))
    }

    private func buttonLabel(phase: AudioPlayback.Phase?, failure: AudioLoadError?) -> String {
        switch phase {
        case .loading: return "Loading audio. Cancel"
        case .playing: return "Pause"
        case .paused: return "Resume"
        case nil:
            if failure == .download { return "Try again" }
            if failure != nil { return "Can’t be played" }
            return audio.isVoice ? "Play voice message" : "Play \(audio.filename)"
        }
    }

    // MARK: Scrubber and time

    /// The scrubber and time, redrawn every frame while playing so they move smoothly.
    private func progress(phase: AudioPlayback.Phase?) -> some View {
        // Read so that a seek while paused, when no frames are being drawn, still redraws this.
        _ = playback.clockChanges
        return SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: phase != .playing)) { _ in
            let isOpen = phase == .playing || phase == .paused
            let length = isOpen ? playback.duration : (audio.duration ?? 0)
            let fraction = scrub
                ?? (isOpen && playback.duration > 0 ? playback.currentTime / playback.duration : nil)
                ?? (phase == .loading ? pendingStart : nil)
                ?? 0
            // Idle: how long it is. Playing, paused or being dragged through: where it has got to.
            let time: String = {
                if isOpen || scrub != nil, length > 0 { return Self.clock(fraction * length, roundingUp: false) }
                return audio.duration.map { Self.clock($0, roundingUp: true) } ?? "–:––"
            }()

            HStack(spacing: 8) {
                scrubber(fraction: fraction, showsKnob: isOpen || scrub != nil)
                if showsTime {
                    Text(time)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: Self.timeWidth, alignment: .trailing)
                        .fixedSize()
                }
            }
            // To VoiceOver and keyboard users this is an ordinary slider.
            .accessibilityRepresentation {
                Slider(value: Binding(get: { fraction }, set: { seek(to: $0) }), in: 0...1, step: 0.05) {
                    Text("Playback position")
                }
                .accessibilityValue(length > 0
                    ? "\(Self.clock(fraction * length, roundingUp: false)) of \(Self.clock(length, roundingUp: true))"
                    : "Not loaded")
            }
        }
    }

    private func scrubber(fraction: Double, showsKnob: Bool) -> some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let split = size.width * CGFloat(min(max(fraction, 0), 1))
                draw(in: context, size: size, color: Color.primary.opacity(0.26))
                var played = context
                played.clip(to: Path(CGRect(x: 0, y: 0, width: split, height: size.height)))
                draw(in: played, size: size, color: .accentColor)

                // A plain track gets a handle; a waveform shows the position well enough itself.
                if audio.waveform.isEmpty, showsKnob {
                    let radius: CGFloat = 5.5
                    let centre = min(max(split, radius), size.width - radius)
                    let knob = CGRect(x: centre - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: knob), with: .color(.accentColor))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrub = Self.fraction(of: $0.location.x, in: geometry.size.width) }
                    .onEnded {
                        seek(to: Self.fraction(of: $0.location.x, in: geometry.size.width))
                        scrub = nil
                    }
            )
        }
        .frame(width: scrubberWidth, height: audio.waveform.isEmpty ? 16 : 26)
    }

    /// The sound's shape as bars, or a plain rounded track when the sender gave no waveform.
    private func draw(in context: GraphicsContext, size: CGSize, color: Color) {
        guard !audio.waveform.isEmpty else {
            let track = CGRect(x: 0, y: (size.height - 4) / 2, width: size.width, height: 4)
            context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(color))
            return
        }
        let step = size.width / CGFloat(audio.waveform.count)
        let width = max(step - 2, 1.5)
        for (index, level) in audio.waveform.enumerated() {
            let height = max(3, CGFloat(level) * size.height)
            let bar = CGRect(x: CGFloat(index) * step + (step - width) / 2, y: (size.height - height) / 2,
                             width: width, height: height)
            context.fill(Path(roundedRect: bar, cornerRadius: width / 2), with: .color(color))
        }
    }

    private func seek(to fraction: Double) {
        if playback.phase(of: id) == nil { pendingStart = fraction }
        playback.seek(id: id, source: audio.media.source, media: media, owner: owner, to: fraction)
    }

    private static func fraction(of x: CGFloat, in width: CGFloat) -> Double {
        width > 0 ? Double(min(max(x / width, 0), 1)) : 0
    }

    /// "0:07", "12:34", "1:02:03".
    static func clock(_ seconds: TimeInterval, roundingUp: Bool) -> String {
        let total = max(0, Int(roundingUp ? seconds.rounded() : seconds.rounded(.down)))
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }

    // MARK: Speed

    private var speedButton: some View {
        Button {
            playback.cycleRate()
        } label: {
            Text(Self.label(for: playback.rate))
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 20)
                .background(Color.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Playback speed")
        .accessibilityLabel("Playback speed")
        .accessibilityValue(Self.label(for: playback.rate))
    }

    private static func label(for rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : String(format: "%.1f×", rate)
    }
}

/// A turning arc, for the play button while audio loads. Drawn rather than using the system
/// spinner, which can't be made white.
private struct LoadingArc: View {
    @State private var isTurning = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(isTurning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isTurning)
            .onAppear { isTurning = true }
    }
}

/// Saves an attachment's file, exactly as it was sent, to a place the user picks.
@MainActor
enum AttachmentSaver {
    static func save(_ audio: AudioAttachment, media: MediaLoader) {
        let type = audio.mimetype.flatMap { UTType(mimeType: $0) }.flatMap { $0.conforms(to: .audio) ? $0 : nil }
        // A voice message is Ogg Opus, as Matrix has it.
        save(named: safeName(audio.filename.isEmpty ? "Audio" : audio.filename, as: type ?? .audio,
                             otherwise: audio.isVoice ? "ogg" : "m4a"),
             kind: "audio") {
            try await media.audioFile(source: audio.media.source)
        }
    }

    static func save(_ image: ImageAttachment, media: MediaLoader) {
        let type = image.mimetype.flatMap { UTType(mimeType: $0) }.flatMap { $0.conforms(to: .image) ? $0 : nil }
        save(named: safeName(image.suggestedFilename, as: type ?? .image, otherwise: "png"), kind: "image") {
            try await media.imageFile(source: image.media.source)
        }
    }

    /// The sender's name for the file, made safe to suggest: without the invisible characters
    /// that reverse text to hide an extension ("photo‮gnp.app" shows as "photoppa.png"), and
    /// ending in an extension of the kind of file it is shown as, so an "image" named
    /// "x.terminal" isn't saved as something that runs when opened.
    /// A file as it was sent, written straight to disk as it downloads, so a large one is never
    /// all in memory. Marked as downloaded, so macOS checks it before anything opens it.
    static func save(_ file: FileAttachment, media: MediaLoader) {
        guard let source = file.media else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.safeFilename
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await media.download(source, mimetype: file.mimetype, to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The file couldn’t be saved."
                    alert.informativeText = "It couldn’t be downloaded. Check your connection and try again."
                    alert.runModal()
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    /// - Parameter fallback: the extension to give it when its kind doesn't name one.
    static func safeName(_ name: String, as type: UTType, otherwise fallback: String) -> String {
        let invisible = CharacterSet(charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}")
        var cleaned = String(String.UnicodeScalarView(name.unicodeScalars.filter { !invisible.contains($0) }))
        cleaned = (cleaned as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.hasPrefix(".") { cleaned = (type.conforms(to: .image) ? "Image" : "Audio") + cleaned }
        let ext = (cleaned as NSString).pathExtension
        // Kept when it already says what the file is shown as.
        if !ext.isEmpty, let existing = UTType(filenameExtension: ext),
           existing.conforms(to: type.conforms(to: .image) ? .image : .audio) { return cleaned }
        return "\(cleaned).\(type.preferredFilenameExtension ?? fallback)"
    }

    private static func save(named name: String, kind: String, load: @escaping () async throws -> Data) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, var url = panel.url else { return }
            Task {
                do {
                    try await load().write(to: url, options: .atomic)
                    // Marked as downloaded, as a browser marks what it saves: macOS then checks
                    // the file before anything opens it, as it would one from the web.
                    var values = URLResourceValues()
                    values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Huddle",
                                                   kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload]
                    try? url.setResourceValues(values)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "The \(kind) couldn’t be saved."
                    alert.informativeText = (error as? AudioLoadError) == .download
                        ? "It couldn’t be downloaded. Check your connection and try again."
                        : error.localizedDescription
                    alert.runModal()
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
}
