import Foundation
import IssueReporting

/// Finds views that macOS 13 wouldn't redraw. There, a view only notices changes to the state
/// it reads inside `WithPerceptionTracking`; Perception reports a read outside it (in debug
/// builds, on any macOS). Its reports go to a log macOS doesn't show the words of, so Dev builds
/// also print each one, once, with the app's frames that made it, as "PERCEPTION_UNTRACKED".
enum PerceptionCheck {
    static func start() {
        #if DEBUG
        guard AppEnvironment.isDev else { return }
        IssueReporters.current.append(UntrackedReadPrinter())
        #endif
    }
}

#if DEBUG
private struct UntrackedReadPrinter: IssueReporter {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: Set<String> = []

    func reportIssue(_ message: @autoclosure () -> String?, severity: IssueSeverity,
                     fileID: StaticString, filePath: StaticString, line: UInt, column: UInt) {
        // Huddle's own frames, the state's getter first and the view that read it below.
        let frames = Thread.callStackSymbols
            .filter { $0.contains("Huddle") && !$0.contains("PerceptionCheck") }
            .prefix(12)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).first.map(String.init) ?? $0 }
        let key = frames.joined(separator: " ")
        let isNew = Self.lock.withLock { Self.seen.insert(key).inserted }
        guard isNew else { return }
        print("PERCEPTION_UNTRACKED \(fileID):\(line)\n  " + frames.joined(separator: "\n  "))
        fflush(stdout)
    }
}
#endif
