import SwiftUI
import Perception

/// Round avatar that falls back to an initial in the person's or room's colour (Decorative), as
/// Element has it. Spaces' are rounded squares, so they read apart from people and rooms at a
/// glance.
struct AvatarView: View {
    let media: MediaLoader
    let url: String?
    let name: String
    /// Stable identifier (user or room ID) that picks the fallback colour.
    let seed: String
    var size: CGFloat = 32
    /// A space's: a rounded square rather than a circle.
    var isSquare = false

    @State private var image: NSImage?
    /// In a room, a person's colour is the room's for them (NameColors). A room's own ID isn't
    /// among its people, so a room's avatar keeps its own colour.
    @Environment(\.nameColorRoom) private var room

    var body: some View { WithPerceptionTracking {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                let index = room == nil ? Decorative.index(for: seed) : NameColors.shared.index(for: seed, inRoom: room)
                Decorative.avatarBackground[index]
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(isSquare ? AnyShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
                            : AnyShape(Circle()))
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = media.cached(url: url, size: Int(size))
            if image == nil {
                image = await media.thumbnail(url: url, size: Int(size))
            }
        }
    } }

    private var initial: String {
        let trimmed = name.drop { "@#!".contains($0) }
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }
}
