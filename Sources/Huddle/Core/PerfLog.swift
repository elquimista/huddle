import Foundation
import QuartzCore

/// Dev build, with HUDDLE_DEV_PERF set: prints how long switching rooms takes, from the
/// selection changing to the new room's first frame reaching the screen.
@MainActor
enum PerfLog {
    static let isOn = AppEnvironment.isDev && ProcessInfo.processInfo.environment["HUDDLE_DEV_PERF"] != nil
    private static var start: CFTimeInterval = 0

    static func began(_ what: String) {
        guard isOn else { return }
        start = CACurrentMediaTime()
        fputs("DEV_PERF \(what)\n", stderr)
    }

    static func mark(_ what: String) {
        guard isOn else { return }
        fputs(String(format: "DEV_PERF %@ +%.0f ms\n", what, (CACurrentMediaTime() - start) * 1000), stderr)
    }

    /// Marks now, and again once what is being drawn has been handed to the screen: at the end of
    /// this pass of the run loop, after Core Animation has committed it. (A transaction's
    /// completion block, with nothing animating, can wait for a later one.)
    static func markDrawn(_ what: String) {
        guard isOn else { return }
        mark(what)
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            MainActor.assumeIsolated { mark("\(what), drawn") }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}
