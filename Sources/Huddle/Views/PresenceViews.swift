import SwiftUI

extension PresenceInfo.State {
    /// Green while online, amber while away. Offline has no colour: no dot at all.
    var color: Color? {
        switch self {
        case .online: Color(nsColor: .systemGreen)
        case .away: Color(nsColor: .systemOrange)
        case .offline: nil
        }
    }
}

extension View {
    /// A presence dot on the lower right of an avatar, set into it with a clear ring around it
    /// (cut out of the avatar, so it reads on any background: plain, selected or hovered).
    func presenceDot(_ presence: PresenceInfo?, avatarSize: CGFloat) -> some View {
        modifier(PresenceDot(presence: presence, avatarSize: avatarSize))
    }
}

private struct PresenceDot: ViewModifier {
    let presence: PresenceInfo?
    let avatarSize: CGFloat

    private var dot: CGFloat { max(8, (avatarSize * 0.28).rounded()) }
    private var gap: CGFloat { max(1.5, (avatarSize * 0.055).rounded()) }
    /// The dot's centre: on the avatar's edge, at the lower right.
    private var centre: CGPoint {
        let offset = avatarSize / 2 * (1 + 0.7071)       // 45° round from the middle, on the rim
        return CGPoint(x: offset, y: offset)
    }

    func body(content: Content) -> some View {
        let color = presence?.state.color
        content
            // The ring around the dot is cut out of the avatar with a mask, not painted over
            // it, so it shows whatever is behind: the sidebar, a selected row, a hovered one.
            .mask {
                if color != nil {
                    RingCutout(centre: centre, radius: dot / 2 + gap)
                        .fill(style: FillStyle(eoFill: true))
                } else {
                    Rectangle()
                }
            }
            .overlay(alignment: .topLeading) {
                if let color {
                    Circle()
                        .fill(color)
                        .frame(width: dot, height: dot)
                        .offset(x: centre.x - dot / 2, y: centre.y - dot / 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.25), value: presence?.state)
    }
}

/// Everything around a view, minus one circle: filled even-odd, a mask that hides the circle.
private struct RingCutout: Shape {
    let centre: CGPoint
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -radius * 2, dy: -radius * 2))
        path.addEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}
