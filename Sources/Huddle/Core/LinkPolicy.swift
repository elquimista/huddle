import AppKit
import SwiftUI
import Perception

/// What a click on a link may open. Links in messages are written by whoever sent them: one
/// can name any app's URL scheme (smb:, file:, ssh:, a settings pane, another app's), or read as
/// one address while going to another. So links open only to web pages and email; anything else
/// is refused, saying what it was. A link whose text is itself an address, and a different one
/// from where it goes, asks first.
enum LinkPolicy {
    /// Schemes a link may open in their usual app.
    private static let openable: Set<String> = ["http", "https", "mailto"]
    /// Stands in for a link that reads as one address and goes to another, until it is clicked.
    private static let checkScheme = "x-huddle-check"

    /// For `.environment(\.openURL, ...)` over everything that shows other people's text.
    @MainActor
    static let action = OpenURLAction { url in
        if url.scheme == checkScheme { return confirmMisleading(url) }
        guard isOpenable(url) else {
            refuse(url)
            return .discarded
        }
        return .systemAction
    }

    static func isOpenable(_ url: URL) -> Bool {
        openable.contains(url.scheme?.lowercased() ?? "")
    }

    /// A web page from the server (its sign-in or account page): https only, and plain http
    /// only for a server on this Mac, as in testing.
    static func isSafeServerPage(_ url: URL) -> Bool {
        switch url.scheme?.lowercased() {
        case "https": return true
        case "http": return ["localhost", "127.0.0.1", "::1"].contains(url.host?.lowercased() ?? "")
        default: return false
        }
    }

    // MARK: Links that say one thing and do another

    /// The link to put on text that reads `shown` and goes to `target`: the target itself, or,
    /// when the text is an address of somewhere else, a stand-in that asks before going there.
    static func link(to target: URL, shown: String) -> URL {
        guard let named = host(namedBy: shown), let real = target.host.map(normalized), named != real else { return target }
        var components = URLComponents()
        components.scheme = checkScheme
        components.queryItems = [URLQueryItem(name: "to", value: target.absoluteString),
                                 URLQueryItem(name: "shown", value: shown)]
        return components.url ?? target
    }

    /// The host the text names, when the whole text is a web address ("docs.example.com/x",
    /// "https://example.com").
    private static func host(namedBy text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" "), let detector else { return nil }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: range), match.range == range,
              let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host else { return nil }
        return normalized(host)
    }

    private static func normalized(_ host: String) -> String {
        let lowered = host.lowercased()
        return lowered.hasPrefix("www.") ? String(lowered.dropFirst(4)) : lowered
    }

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    @MainActor
    private static func confirmMisleading(_ check: URL) -> OpenURLAction.Result {
        let items = URLComponents(url: check, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let target = items.first(where: { $0.name == "to" })?.value.flatMap(URL.init(string:)) else {
            return .discarded
        }
        let shown = items.first(where: { $0.name == "shown" })?.value ?? ""
        guard isOpenable(target) else {
            refuse(target)
            return .discarded
        }
        let alert = NSAlert()
        alert.messageText = "Open This Link?"
        alert.informativeText = "It reads “\(shown)” but goes to a different place:\n\n\(target.absoluteString)"
        // The safe choice is the default one.
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        return alert.runModal() == .alertSecondButtonReturn ? .systemAction(target) : .handled
    }

    @MainActor
    private static func refuse(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Huddle Doesn’t Open This Kind of Link"
        alert.informativeText = "It would open another app:\n\n\(url.absoluteString)\n\n"
            + "Links in messages open only web pages and email."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Copy Link")
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
    }
}
