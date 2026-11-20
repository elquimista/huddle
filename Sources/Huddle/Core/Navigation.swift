import AppKit
import Perception

/// The rooms visited, across accounts and spaces, for Go ▸ Back and Forward (⌘[ and ⌘]), as a
/// browser keeps the pages visited.
@MainActor @Perceptible
final class RoomHistory {
    static let shared = RoomHistory()

    struct Visit: Equatable {
        let accountID: String
        let roomID: String
    }

    private(set) var visits: [Visit] = []
    private(set) var index = -1

    @PerceptionIgnored weak var store: AccountStore?
    @PerceptionIgnored private var isPending = false
    @PerceptionIgnored private var isMoving = false

    private static let mostVisits = 100

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index < visits.count - 1 }

    /// The room showing may have changed. Noted once things settle: switching accounts and the
    /// room that account shows come one after the other, and are one move.
    func noteChange() {
        guard !isPending else { return }
        isPending = true
        DispatchQueue.main.async { [self] in
            isPending = false
            note()
        }
    }

    private func note() {
        guard !isMoving, let account = store?.selected, let roomID = account.selectedRoomID else { return }
        let visit = Visit(accountID: account.id, roomID: roomID)
        if visits.indices.contains(index), visits[index] == visit { return }
        // A new way from here: what was ahead is gone, as in a browser.
        if index + 1 < visits.count { visits.removeSubrange((index + 1)...) }
        visits.append(visit)
        if visits.count > Self.mostVisits { visits.removeFirst(visits.count - Self.mostVisits) }
        index = visits.count - 1
    }

    /// Back (-1) or forward (1), passing over rooms since left or accounts since signed out.
    func go(_ step: Int) {
        var target = index + step
        while visits.indices.contains(target) {
            let visit = visits[target]
            if let account = store?.accounts.first(where: { $0.id == visit.accountID }),
               account.allRooms.contains(where: { $0.id == visit.roomID }) {
                index = target
                isMoving = true
                Notifier.shared.show(accountID: visit.accountID, roomID: visit.roomID, thread: nil)
                // After the moves it makes have been noted (and let go).
                DispatchQueue.main.async { self.isMoving = false }
                return
            }
            target += step
        }
    }

    /// The rooms visited, newest first and each once, for Go to Room's list before anything
    /// is typed.
    var recent: [Visit] {
        var seen = Set<String>()
        return visits.reversed().filter { seen.insert("\($0.accountID)|\($0.roomID)").inserted }
    }
}

/// Keys that move between accounts and have no menu item of their own: ⌥⌘→ and ⌥⌘←, as well
/// as Go ▸ Next and Previous Account (⌃Tab, ⌃⇧Tab), which a menu item can show only one of.
@MainActor
final class NavigationKeys {
    static let shared = NavigationKeys()

    private var monitor: Any?
    private weak var store: AccountStore?

    func start(store: AccountStore) {
        self.store = store
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        guard modifiers == [.command, .option], let store, !store.navigationPaused,
              event.window?.identifier?.rawValue.hasPrefix(MainWindow.id) == true else { return false }
        switch event.keyCode {
        case 124: store.selectAccount(step: 1)     // →
        case 123: store.selectAccount(step: -1)    // ←
        default: return false
        }
        return true
    }
}
