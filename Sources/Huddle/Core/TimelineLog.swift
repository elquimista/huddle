import Foundation
import os

/// A few notes on how a room's conversation was scrolled, in the system log (Console, or
/// `log show --predicate 'subsystem == "app.huddle.Huddle" && category == "timeline"'`), for
/// finding out why a room didn't open at its newest message. No message content or room names.
enum TimelineLog {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.huddle.Huddle", category: "timeline")
}
