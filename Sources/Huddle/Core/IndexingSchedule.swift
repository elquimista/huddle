import AppKit
import Perception

/// When the passes that make message history searchable may run: while Huddle isn't the app in
/// front, or nobody has used it for a minute. They take the Mac's time, and they load history
/// into the SDK's event cache, which every view of a room shares; so they wait while you're
/// using Huddle, as Spotlight and Photos do their work when you aren't. New messages are
/// indexed as they arrive all the same.
@MainActor @Perceptible
final class IndexingSchedule {
    static let shared = IndexingSchedule()

    private(set) var isIdle = false

    /// How long Huddle has to go untouched, while in front, before indexing goes on.
    private static let quietFor: TimeInterval = 60

    @PerceptionIgnored private var lastUse = Date()
    @PerceptionIgnored private var monitor: Any?
    @PerceptionIgnored private var timer: Timer?
    @PerceptionIgnored private var observers: [NSObjectProtocol] = []

    func start() {
        guard monitor == nil else { return }
        // Using Huddle: typing, clicking, scrolling in it. (Only its own events reach this.)
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.used()
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.used() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
        ]
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    private func used() {
        lastUse = Date()
        update()
    }

    private func update() {
        let idle: Bool
        if let forced = DevHooks.indexingIdle {
            idle = forced
        } else {
            idle = !NSApp.isActive || Date().timeIntervalSince(lastUse) >= Self.quietFor
        }
        if idle != isIdle {
            isIdle = idle
            if AppEnvironment.isDev {
                print("DEV_INDEXING \(idle ? "may run" : "waits: Huddle is in use")")
                fflush(stdout)
            }
        }
    }

    /// Returns once indexing may go on (at once, if it may now).
    func waitUntilIdle() async {
        while !isIdle, !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
