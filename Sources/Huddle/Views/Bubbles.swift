import AppKit
import SwiftUI

/// The bubble layout's colours and measures.
enum Bubble {
    /// Others' messages: white on the window's grey, a soft grey in the dark.
    static let others = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.1) : .white
    })

    /// Others' messages where the backdrop is white already (the thread panel): a light grey.
    static let othersOnContent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0.915, alpha: 1)
    })

    /// Yours: a pale wash of the accent colour, so text, links and mentions keep their own
    /// colours on it, as they would not on a solid one.
    static let own = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.controlAccentColor.withAlphaComponent(0.3)
            : NSColor.controlAccentColor.blended(withFraction: 0.8, of: .white) ?? .white
    })

    /// How far the tail reaches out past the bubble's side. Every bubble keeps the room for it,
    /// so the bubbles of a run line up whether or not they have one.
    static let tailWidth: CGFloat = 6
    /// Between a bubble's edge and its text.
    static let textInset = EdgeInsets(top: 6, leading: 11, bottom: 7, trailing: 11)
    /// The avatar beside the last of a run, in rooms of more than two.
    static let avatarSize: CGFloat = 28
    static let avatarGap: CGFloat = 8
}

extension EnvironmentValues {
    /// Set where messages are drawn on the content background (white in the light) rather than
    /// the window's grey, so others' bubbles take a colour that shows on it.
    @Entry var bubblesOnContentBackground = false
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

/// A chat bubble. Its corners are tighter on the sender's side where it runs on from the one
/// above or into the one below, and the last of a run has a tail at its foot.
struct BubbleShape: Shape {
    /// Yours: on the right, the tail on the right.
    let isOwn: Bool
    /// Runs on from a bubble of the same sender's above.
    let joinsAbove: Bool
    /// Runs on into one below: no tail.
    let joinsBelow: Bool

    private static let radius: CGFloat = 16
    private static let tight: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var body = rect
        body.size.width -= Bubble.tailWidth
        if !isOwn { body.origin.x += Bubble.tailWidth }
        let r = min(Self.radius, body.height / 2)
        let t = min(Self.tight, r)
        let top = joinsAbove ? t : r
        // On the sender's side at the foot: tight where the next bubble runs on, square where
        // the tail takes over.
        let bottom = joinsBelow ? t : 0
        let radii = isOwn
            ? RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: bottom, topTrailing: top)
            : RectangleCornerRadii(topLeading: top, bottomLeading: bottom, bottomTrailing: r, topTrailing: r)
        var path = UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: body)
        if !joinsBelow { path.addPath(tail(in: rect, body: body)) }
        return path
    }

    /// Curves out of the bubble's side and down to a point level with its foot, its underside
    /// running on along the foot. It meets the bubble edge to edge rather than overlapping it:
    /// drawn the other way round, an overlap would cancel out and leave a hole. Drawn for the
    /// left and mirrored for the right.
    private func tail(in rect: CGRect, body: CGRect) -> Path {
        let edge = rect.minX + Bubble.tailWidth
        let foot = rect.maxY
        let reach = min(17, body.height - 2)
        var tail = Path()
        tail.move(to: CGPoint(x: edge, y: foot - reach))
        tail.addCurve(to: CGPoint(x: rect.minX + 0.8, y: foot - 0.4),
                      control1: CGPoint(x: edge, y: foot - reach * 0.35),
                      control2: CGPoint(x: rect.minX + 2.5, y: foot - 1.4))
        tail.addQuadCurve(to: CGPoint(x: rect.minX + 2.2, y: foot), control: CGPoint(x: rect.minX, y: foot))
        tail.addLine(to: CGPoint(x: edge, y: foot))
        tail.closeSubpath()
        guard isOwn else { return tail }
        return tail.applying(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: rect.minX + rect.maxX, ty: 0))
    }
}

/// Lines things up with a bubble's foot: the avatar beside the last of a run sits level with it,
/// not with the reactions hanging under it.
extension VerticalAlignment {
    private enum BubbleFoot: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.bottom] }
    }

    static let bubbleFoot = VerticalAlignment(BubbleFoot.self)
}

extension View {
    /// At most this wide, and no wider than the content needs.
    func widthCap(_ maxWidth: CGFloat) -> some View {
        WidthCap(maxWidth: maxWidth) { self }
    }
}

/// Offers its content no more than a given width, and takes only what the content uses: a
/// bubble hugs a short message and wraps a long one at the cap. (A frame with a maximum width
/// would take the whole of it.)
struct WidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width.map { min($0, maxWidth) } ?? maxWidth
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// One of the bubble layout's hover actions: small and round, standing on its own beside the
/// bubble rather than in a bar.
struct RoundActionButton<Label: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? .primary : .secondary)
                .frame(width: 26, height: 26)
                .background(.background, in: Circle())
                .overlay { Circle().fill(Color.primary.opacity(isHovering ? 0.07 : 0)) }
                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 0.5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHoverInFrontWindow { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The emoji picker with the quick reactions along its top, one click away, whatever the
/// layout: in bubbles, which have none of their own beside the message, these are the only ones.
struct QuickReactionPicker: View {
    /// Your reactions to the message, marked in the picker: picking one again takes it back.
    var reacted: [String] = []
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var marked: Set<String> { Set(reacted.map(EmojiCatalog.canonical)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(QuickReactions.shared.emoji, id: \.self) { emoji in
                    QuickReactionButton(emoji: emoji, isMarked: marked.contains(emoji)) {
                        EmojiCatalog.noteUse(of: emoji)
                        onPick(emoji)
                    }
                    .contextMenu { CustomizeQuickReactionsButton(before: { dismiss() }) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            EmojiPicker(marked: marked, onPick: onPick)
        }
    }
}

private struct QuickReactionButton: View {
    let emoji: String
    var isMarked = false
    let action: () -> Void
    @State private var isHovering = false

    private var fill: Color {
        isMarked ? Color.accentColor.opacity(isHovering ? 0.3 : 0.2) : Color.primary.opacity(isHovering ? 0.08 : 0)
    }

    var body: some View {
        Button(action: action) {
            Text(emoji)
                .font(.system(size: 21))
                .frame(width: 44, height: 36)
                .background(fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isMarked ? "Remove your \(emoji)" : "React with \(emoji)")
        .accessibilityLabel(isMarked ? "Remove your \(emoji)" : "React with \(emoji)")
    }
}
