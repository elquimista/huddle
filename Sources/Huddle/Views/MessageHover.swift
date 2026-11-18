import Observation
import SwiftUI

/// Which message in a conversation shows its hover actions: one at a time, the one under the
/// pointer, unless the pointer is on a message's action bar, when that message keeps them.
///
/// The bar rides the top edge of its message, its upper half over the message above. On that
/// half the pointer is over the message above as well, and on its own each message would take
/// it as being hovered: the bar would jump to the message above just as the pointer reached for
/// one of its buttons. Here the bar's own message wins, and the message above only gets its
/// actions once the pointer leaves the bar.
///
/// Each message watches only its own flag, so a move from one message to the next redraws those
/// two and no others.
final class MessageHoverState {
    @Observable final class Row {
        fileprivate(set) var isActive = false
    }

    /// For views shown outside a conversation, which have no actions to show.
    static let unattached = MessageHoverState()

    private var rows: [String: Row] = [:]
    /// The messages under the pointer, the one it came to last at the end.
    private var hovered: [String] = []
    /// The message whose action bar is under the pointer.
    private var barOwner: String?
    private var active: String?
    private var isResolving = false

    func row(_ id: String) -> Row {
        if let row = rows[id] { return row }
        let row = Row()
        rows[id] = row
        return row
    }

    func pointer(isOver hovering: Bool, message id: String) {
        hovered.removeAll { $0 == id }
        if hovering { hovered.append(id) }
        resolveSoon()
    }

    func pointer(isOverBar hovering: Bool, of id: String) {
        if hovering {
            barOwner = id
        } else if barOwner == id {
            barOwner = nil
        }
        resolveSoon()
    }

    /// A message scrolled out of the drawn rows.
    func forget(_ id: String) {
        hovered.removeAll { $0 == id }
        if barOwner == id { barOwner = nil }
        if active == id { active = nil }
        rows[id] = nil
    }

    /// Once every change a single pointer move brings has arrived: leaving one message, coming
    /// to the next and onto a bar come one by one, and judged one by one the bar would go before
    /// the news that the pointer is on it.
    private func resolveSoon() {
        guard !isResolving else { return }
        isResolving = true
        DispatchQueue.main.async { [self] in
            isResolving = false
            let next = barOwner ?? hovered.last
            guard next != active else { return }
            if let active { rows[active]?.isActive = false }
            if let next { row(next).isActive = true }
            active = next
        }
    }
}

extension EnvironmentValues {
    @Entry var messageHover: MessageHoverState = .unattached
}
