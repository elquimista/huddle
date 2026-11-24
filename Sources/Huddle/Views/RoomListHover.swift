import AppKit
import Perception
import SwiftUI

/// Which room's row in the list the pointer is on, for its wash (`RoomListRow`): one row at most,
/// worked out from where the pointer is each time it moves over the list or leaves it, the list
/// scrolls or its rooms change places, a row comes or goes, or the window comes to the front or
/// goes behind.
///
/// Each row hearing for itself that the pointer had come and gone (SwiftUI's `onHover`, AppKit's
/// tracking areas underneath) left washes behind, sometimes on more than one row: a row hears of
/// the pointer leaving only as it happens, so one that moves away from under a still pointer
/// (rooms reordering as messages come in, the list scrolling) or that the pointer leaves while a
/// menu or a drag has the mouse never does.
///
/// Each row watches only its own flag, so a move from one row to the next redraws those two.
@MainActor
final class RoomListHover: NSObject {
    @Perceptible final class Row {
        fileprivate(set) var isPointedAt = false
    }

    private var rows: [String: Row] = [:]
    /// Each drawn row's stand-in among AppKit's views, which knows where the row is on screen.
    private let probes = NSMapTable<NSString, NSView>.strongToWeakObjects()
    private var active: String?
    private weak var window: NSWindow?
    private weak var clipView: NSClipView?
    private var isResolving = false

    /// Where the pointer is taken to be, in window coordinates, for tests that can't move the real
    /// one (HUDDLE_DEV_POINTER).
    static var devPointer: NSPoint?
    static let devPointerMoved = Notification.Name("RoomListHover.devPointerMoved")

    override init() {
        super.init()
        if AppEnvironment.isDev {
            NotificationCenter.default.addObserver(self, selector: #selector(changed), name: Self.devPointerMoved, object: nil)
        }
        let app = NotificationCenter.default
        app.addObserver(self, selector: #selector(changed), name: NSApplication.didBecomeActiveNotification, object: nil)
        app.addObserver(self, selector: #selector(changed), name: NSApplication.didResignActiveNotification, object: nil)
    }

    func row(_ id: String) -> Row {
        if let row = rows[id] { return row }
        let row = Row()
        rows[id] = row
        return row
    }

    /// Looks again once what moved the rows has settled: rooms changing places slide there.
    func rowsMoved() {
        resolveSoon(after: 0.35)
    }

    fileprivate func attach(_ probe: NSView, id: String) {
        probes.setObject(probe, forKey: id as NSString)
        watch(probe)
        resolveSoon()
    }

    fileprivate func detach(_ probe: NSView, id: String) {
        if probes.object(forKey: id as NSString) === probe { probes.removeObject(forKey: id as NSString) }
        resolveSoon()
    }

    /// The list's scrolling, and its window coming to the front and going behind, found from a
    /// row drawn in it.
    private func watch(_ probe: NSView) {
        let center = NotificationCenter.default
        if let clip = probe.enclosingScrollView?.contentView, clip !== clipView {
            if let clipView { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: clipView) }
            clipView = clip
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(changed), name: NSView.boundsDidChangeNotification, object: clip)
        }
        if let window = probe.window, window !== self.window {
            if let old = self.window {
                for name in Self.windowNotifications { center.removeObserver(self, name: name, object: old) }
            }
            self.window = window
            for name in Self.windowNotifications {
                center.addObserver(self, selector: #selector(changed), name: name, object: window)
            }
        }
    }

    private static let windowNotifications: [Notification.Name] = [
        NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
        NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification,
    ]

    @objc private func changed(_ note: Notification) {
        resolveSoon()
    }

    /// Once AppKit has done what the news is of: scrolled, laid out, moved the pointer.
    fileprivate func resolveSoon(after delay: TimeInterval = 0) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.resolve() }
            return
        }
        guard !isResolving else { return }
        isResolving = true
        DispatchQueue.main.async { [weak self] in
            self?.isResolving = false
            self?.resolve()
        }
    }

    private func resolve() {
        let next = pointedAt()
        guard next != active else { return }
        if let active { rows[active]?.isPointedAt = false }
        if let next { row(next).isPointedAt = true }
        active = next
    }

    private func pointedAt() -> String? {
        // A Mac window behind another doesn't answer the pointer.
        guard let window, window.isVisible,
              DevHooks.assumesActive || (NSApp.isActive && (window.isKeyWindow || window.isMainWindow)) else { return nil }
        let location = Self.devPointer ?? window.mouseLocationOutsideOfEventStream
        // Where two rows' reach meets, the one already pointed at keeps it.
        if let active, contains(active, location) { return active }
        for case let id as NSString in probes.keyEnumerator() where contains(id as String, location) {
            return id as String
        }
        return nil
    }

    private func contains(_ id: String, _ location: NSPoint) -> Bool {
        guard let probe = probes.object(forKey: id as NSString), probe.window === window,
              !probe.isHiddenOrHasHiddenAncestor else { return false }
        // Only what shows of it: not the part of a row scrolled out of the list.
        return probe.visibleRect.contains(probe.convert(location, from: nil))
    }
}

extension EnvironmentValues {
    @Entry var roomListHover: RoomListHover? = nil
}

/// A row's stand-in among AppKit's views, covering what the row's wash does: where it is, for
/// `RoomListHover`. Clicks, drags and menus go through it to the row.
struct RoomHoverProbe: NSViewRepresentable {
    let id: String
    let hover: RoomListHover?

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.attach(id: id, to: hover)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.attach(id: nil, to: nil)
    }

    final class ProbeView: NSView {
        private var id: String?
        private weak var hover: RoomListHover?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func attach(id: String?, to hover: RoomListHover?) {
            if let old = self.id, old != id || hover !== self.hover { self.hover?.detach(self, id: old) }
            self.id = id
            self.hover = hover
            if let id, window != nil { hover?.attach(self, id: id) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let id else { return }
            if window != nil { hover?.attach(self, id: id) } else { hover?.detach(self, id: id) }
        }
    }
}

/// Behind the list, as big as it is: tells `RoomListHover` each time the pointer moves over the
/// list, comes onto it or leaves it. The list itself doesn't move as its rows do, so it always
/// hears the pointer leave.
struct RoomListPointerArea: NSViewRepresentable {
    let hover: RoomListHover

    func makeNSView(context: Context) -> AreaView {
        let view = AreaView()
        view.hover = hover
        return view
    }

    func updateNSView(_ view: AreaView, context: Context) {
        view.hover = hover
    }

    final class AreaView: NSView {
        weak var hover: RoomListHover?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            guard trackingAreas.isEmpty else { return }
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        override func mouseMoved(with event: NSEvent) { hover?.resolveSoon() }
        override func mouseEntered(with event: NSEvent) { hover?.resolveSoon() }
        override func mouseExited(with event: NSEvent) { hover?.resolveSoon() }
    }
}
