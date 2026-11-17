import AppKit
import SwiftUI

/// One thing that can be done to a message, as a menu item. The same list makes the message's
/// context menu and the menu behind its "More" button, so the two always agree.
struct MessageMenuItem: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// A message's items as a context menu: one group after another, with a line between groups.
struct MessageContextMenu: View {
    let sections: [[MessageMenuItem]]

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { index, section in
            if index > 0 { Divider() }
            ForEach(section) { item in
                Button(item.title, action: item.action)
            }
        }
    }
}

/// The "More" button at the end of a message's hover actions. Its menu is an AppKit menu
/// rather than a SwiftUI one so that the hover actions can stay up while it is open: the
/// pointer leaves the message for the menu, and SwiftUI doesn't say when its menus open.
struct MoreActionsButton: View {
    /// Built when the button is clicked, so the menu matches the message as it is then.
    let sections: () -> [[MessageMenuItem]]
    /// True while the menu is open.
    @Binding var isOpen: Bool
    @State private var anchor = MenuAnchor()

    var body: some View {
        ActionButton(help: "More actions", action: open) {
            Image(systemName: "ellipsis")
        }
        .background(MenuAnchorView(anchor: anchor))
        .accessibilityLabel("More actions")
    }

    private func open() {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, section) in sections().enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for item in section { menu.addItem(ClosureMenuItem(title: item.title, handler: item.action)) }
        }
        isOpen = true
        // Hangs from the button's bottom edge, lined up with its left side. Returns once the
        // menu has closed.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        isOpen = false
    }
}

/// Holds the AppKit view the menu is shown from.
private final class MenuAnchor {
    weak var view: NSView?
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }

    /// Measured from the top, like the SwiftUI view around it.
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
