import AppKit
import SwiftUI
import Perception

extension View {
    /// Turns off AppKit's title-bar separator. SwiftUI counts a bar along the top of a scroll
    /// view (the pinned-message banner) as part of the title bar, so AppKit draws its
    /// separator under that bar instead, the whole width of the detail column: straight across
    /// the side panel beside the conversation. The detail column draws its own line under the
    /// toolbar instead, and the banner has its own. (No SwiftUI modifier does this
    /// before macOS 26.)
    func detailTitlebarSeparatorHidden() -> some View {
        background(TitlebarSeparatorRemover())
    }
}

private struct TitlebarSeparatorRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> RemoverView { RemoverView() }
    func updateNSView(_ view: RemoverView, context: Context) { view.apply() }

    final class RemoverView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        // SwiftUI can rebuild the split view's items (showing or hiding the sidebar), so check
        // again whenever the window lays out.
        override func layout() {
            super.layout()
            apply()
        }

        func apply() {
            guard let window, let root = window.contentView else { return }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if let detail = Self.splitViewController(in: root)?.splitViewItems.last,
               detail.titlebarSeparatorStyle != .none {
                detail.titlebarSeparatorStyle = .none
            }
        }

        private static func splitViewController(in view: NSView) -> NSSplitViewController? {
            if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController {
                return controller
            }
            for subview in view.subviews {
                if let found = splitViewController(in: subview) { return found }
            }
            return nil
        }
    }
}
