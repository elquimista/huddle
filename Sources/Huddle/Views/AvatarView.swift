import SwiftUI

/// Round avatar that falls back to a coloured initial. Spaces' are rounded squares, so they
/// read apart from people and rooms at a glance.
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

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Self.color(for: seed)
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
    }

    private var initial: String {
        let trimmed = name.drop { "@#!".contains($0) }
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    private static let palette: [Color] = [.blue, .teal, .green, .orange, .pink, .purple, .indigo, .brown]

    static func color(for seed: String) -> Color {
        let hash = seed.utf8.reduce(UInt(5381)) { ($0 << 5) &+ $0 &+ UInt($1) }
        return palette[Int(hash % UInt(palette.count))]
    }
}
