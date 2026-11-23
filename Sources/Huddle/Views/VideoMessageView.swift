import AVKit
import SwiftUI

/// A video in the conversation, played where it is: shaped like the film, a still from it with a
/// play button and its length until it's played, then macOS's own player in its place, with its
/// controls (and full screen) along the bottom on hover. Downloads only when played, apart from
/// small videos sent without a still, which are fetched to take one.
struct VideoMessageView: View {
    /// The message, for knowing which video is playing.
    let id: String
    let file: FileAttachment
    let video: VideoDetails
    let media: MediaLoader
    /// The timeline it's in: leaving that stops it.
    let owner: AnyObject
    var sendState: MessageRow.SendState?
    var uploadProgress: Double?
    var cancelUpload: (() -> Void)?

    @State private var poster: NSImage?
    @State private var isHovering = false
    @State private var isOpening = false
    @Environment(\.messageContentWidth) private var contentWidth
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var playback: VideoPlayback { .shared }
    private var phase: VideoPlayback.Phase? { playback.phase(of: id) }
    private var failure: VideoPlayError? { playback.failures[id] }
    /// The film's true shape, once played, where the sender didn't give it or gave it wrongly.
    private var learntShape: CGSize? { file.media.flatMap { playback.shapes[$0.source.url()] } }

    /// Loaded again once the film has been played and its shape learnt: it has been downloaded
    /// then, so a still can be taken from it if there wasn't one.
    private struct PosterKey: Equatable {
        let url: String?
        let isPlayed: Bool
    }

    /// Smallest a video is drawn on its longer side, enlarging a tiny one: the player's controls
    /// need the room.
    private static let smallestSide: CGFloat = 240

    /// Narrowest the frame is: the player's controls hide its scrubber and times in less. A film
    /// narrower than this (an upright phone video) sits in the middle, black either side, as the
    /// player shows it.
    private static let narrowestFrame: CGFloat = 280

    /// The film, fitted: as big as it is, or scaled down to fit the box.
    private var filmSize: CGSize {
        var size = learntShape ?? video.pixelSize ?? poster?.size ?? video.thumbnailPixelSize
        if let known = size, max(known.width, known.height) < Self.smallestSide {
            let scale = Self.smallestSide / max(known.width, known.height)
            size = CGSize(width: known.width * scale, height: known.height * scale)
        }
        // A little taller than a picture may be: an upright video has more to show.
        return ImageAttachment.fitted(size, maxWidth: contentWidth, unknownShape: 16 / 9, maxHeight: 360)
    }

    /// The frame around the film: the film's own, widened where that's too narrow.
    private func frameSize(for film: CGSize) -> CGSize {
        let roomy = max(min(contentWidth, ImageAttachment.maximumSize.width), 120)
        return CGSize(width: max(film.width, min(Self.narrowestFrame, roomy)), height: film.height)
    }

    var body: some View {
        let film = filmSize
        let size = frameSize(for: film)
        let radius = min(10, min(size.width, size.height) * 0.18)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        ZStack {
            backdrop(size: size, isWider: size.width > film.width + 1)
            if phase == .ready, let player = playback.player {
                VideoPlayerView(player: player)
                    .transition(.opacity)
            } else {
                still(film: film, size: size, shape: shape)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phase)
        .task(id: PosterKey(url: file.media?.source.url() ?? video.localURL?.path, isPlayed: learntShape != nil)) {
            await loadPoster()
        }
    }

    // MARK: Before playing

    /// Behind the film: black, wherever the frame is wider than the film, as the player has it;
    /// before the still has come, the sender's blur, or a dark tile, as a film's frame would be.
    @ViewBuilder private func backdrop(size: CGSize, isWider: Bool) -> some View {
        if isWider {
            Color.black
        } else if let blur = video.blurhash.flatMap(BlurCache.image(for:)) {
            Image(decorative: blur, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            Color(white: 0.16)
        }
    }

    private func still(film: CGSize, size: CGSize, shape: RoundedRectangle) -> some View {
        ZStack {
            Button(action: play) {
                ZStack {
                    if let poster = shownPoster {
                        Image(nsImage: poster)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: film.width, height: film.height)
                            .clipped()
                            .transition(.opacity)
                    }
                }
                .frame(width: size.width, height: size.height)
                .contentShape(shape)
            }
            .buttonStyle(.plain)
            .allowsHitTesting(sendState == nil)
            .onHoverInFrontWindow { isHovering = $0 }
            .help(help)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(sendState == nil ? "Plays the video" : "")

            if let sendState {
                UploadOverlay(sendState: sendState, uploadProgress: uploadProgress, cancel: cancelUpload)
            } else if let failure {
                failureNote(failure)
            } else {
                playButton
                    .allowsHitTesting(false)
                if let duration = video.duration ?? file.media.flatMap({ playback.durations[$0.source.url()] }) {
                    Text(VideoDetails.durationText(duration))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeOut(duration: 0.2), value: shownPoster != nil)
    }

    /// Play, in a dark disc that reads over any picture; a spinner while it downloads, which a
    /// click calls off.
    private var playButton: some View {
        ZStack {
            Circle()
                .fill(.black.opacity(isHovering ? 0.6 : 0.45))
            Circle()
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.5)
            if phase == .loading {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
            }
        }
        .frame(width: 48, height: 48)
        .scaleEffect(isHovering && phase == nil && !reduceMotion ? 1.06 : 1)
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
    }

    private func failureNote(_ failure: VideoPlayError) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
            Text(failure == .unplayable ? "This video can’t play here" : "Couldn’t load video")
                .font(.caption.weight(.medium))
            Text(failure == .unplayable ? "Click to open it in another app" : "Click to try again")
                .font(.caption2)
                .opacity(0.8)
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.45))
        .allowsHitTesting(false)
    }

    private var help: String {
        switch failure {
        case .unplayable: "Open “\(file.filename)”"
        case .download: "Try again"
        case nil: phase == .loading ? "Stop loading" : "Play"
        }
    }

    private var accessibilityLabel: String {
        let name = file.caption ?? file.filename
        let length = video.duration.map {
            Duration.seconds($0.rounded()).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        }
        return [name.isEmpty ? "Video" : "Video: \(name)", length].compactMap { $0 }.joined(separator: ", ")
    }

    // MARK: Actions

    private func play() {
        guard sendState == nil else { return }
        if failure == .unplayable {
            guard !isOpening else { return }
            isOpening = true
            Task {
                try? await media.open(file)
                isOpening = false
            }
            return
        }
        playback.play(id: id, file: file, media: media, owner: owner)
    }

    /// How many pixels across the still is: sharp on this screen, with a little to spare.
    private var posterSide: Int {
        let size = filmSize
        return max(Int((max(size.width, size.height) * displayScale * 1.2).rounded(.up)), 64)
    }

    /// The still, from the cache in the first frame the message is drawn in, where it's there:
    /// left to `task`, it came a frame later, so a conversation drawn anew showed a dark tile for
    /// a moment first.
    private var shownPoster: NSImage? {
        poster ?? media.cachedVideoPoster(for: file, side: posterSide)
    }

    private func loadPoster() async {
        if let loaded = await media.videoPoster(for: file, side: posterSide), !Task.isCancelled {
            poster = loaded
        }
    }
}

/// macOS's own player, as QuickTime Player and Safari have it: inline controls along the bottom
/// on hover, with full screen.
struct VideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        // Let SwiftUI decide the size; otherwise the view insists on the film's own.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
