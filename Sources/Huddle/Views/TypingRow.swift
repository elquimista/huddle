import SwiftUI
import Perception

/// Under the newest message while others are writing: three dots where a sender's avatar would
/// be (or their name, in the IRC layout), and who it is where the text would be.
struct TypingRow: View {
    let typists: [Typist]
    /// A direct chat between two: in the bubble layout, the bubble alone says who.
    var isOneToOne = false
    @Environment(\.messageLayout) private var layout
    @Environment(\.ircNameWidth) private var nameWidth
    @State private var isShown = false

    var body: some View { WithPerceptionTracking {
        HStack(alignment: .center, spacing: layout == .irc ? 8 : 10) {
            switch layout {
            case .irc:
                // The time column, then the names'.
                Color.clear.frame(width: IRCNameColumn.leading - 8, height: 1)
                TypingDots().frame(width: nameWidth, alignment: .trailing)
            case .bubbles:
                // Where the next bubble will be: an incoming one, its dots for text.
                if !isOneToOne { Color.clear.frame(width: Bubble.avatarSize, height: 1) }
                TypingDots(isBubbled: true)
                    .padding(.leading, isOneToOne ? 0 : Bubble.avatarGap - 10)
            case .modern:
                TypingDots()
            }
            if layout != .bubbles || !isOneToOne {
                Text(Self.sentence(for: typists))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .opacity(isShown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.25 * Motion.slowdown)) { isShown = true } }
        .help(typists.count > 3 ? typists.map(\.name).formatted(.list(type: .and)) : "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.sentence(for: typists))
    } }

    /// “Alice is typing”, “Alice and Bob are typing”; past three, the first two and how many more.
    static func sentence(for typists: [Typist]) -> String {
        let names = typists.map(\.name)
        let named = names.count <= 3 ? names : Array(names.prefix(2)) + ["\(names.count - 2) others"]
        let list = named.formatted(.list(type: .and))
        return names.count == 1 ? "\(list) is typing" : "\(list) are typing"
    }
}

/// Three dots in a little bubble, brightening one after another.
private struct TypingDots: View {
    /// In a chat bubble of the bubble layout's, rather than a capsule of its own.
    var isBubbled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View { WithPerceptionTracking {
        SwiftUI.TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in WithPerceptionTracking {
            let time = context.date.timeIntervalSinceReferenceDate / Motion.slowdown
            // As wide as an avatar: 3 × 5 + 2 × 2.5 + 2 × 6 = 32.
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { index in WithPerceptionTracking {
                    let lift = reduceMotion ? 0.5 : Self.lift(at: time, dot: index)
                    Circle()
                        .frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * lift)
                        .scaleEffect(0.85 + 0.15 * lift)
                } }
            }
        } }
        .foregroundStyle(.secondary)
        .modifier(DotsFrame(isBubbled: isBubbled))
    } }

    /// 0 to 1: a pulse that runs across the dots every 1.2 seconds, each a fifth behind the last.
    private static func lift(at time: TimeInterval, dot: Int) -> Double {
        let phase = (time / 1.2 - Double(dot) * 0.2).truncatingRemainder(dividingBy: 1)
        let wave = sin((phase < 0 ? phase + 1 : phase) * 2 * .pi)
        return max(0, wave)
    }
}

private struct DotsFrame: ViewModifier {
    let isBubbled: Bool

    func body(content: Content) -> some View { WithPerceptionTracking {
        if isBubbled {
            content
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .padding(.leading, Bubble.tailWidth)
                .background { BubbleShape(isOwn: false, joinsAbove: false, joinsBelow: false).fill(Bubble.others) }
        } else {
            content
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
                .background(.quaternary, in: Capsule())
        }
    } }
}
