import AppKit
import Foundation
import MatrixRustSDK
import Observation

/// Whether someone is around, as their homeserver last told us.
struct PresenceInfo: Equatable {
    enum State: Equatable {
        case online
        /// Signed in but idle, or away from the app.
        case away
        case offline
    }

    var state: State
    /// When they were last active, if the server says.
    var lastActive: Date?
    var statusMessage: String?

    /// "Online", "Away", "Last seen 5 min ago". Nil when there is nothing worth saying, which is
    /// also what a server with presence switched off gives: everyone offline, with no times.
    var description: String? {
        let base: String?
        switch state {
        case .online: base = "Online"
        case .away: base = lastActive.map { "Away · last active \(Self.ago($0))" } ?? "Away"
        case .offline: base = lastActive.map { "Last seen \(Self.ago($0))" }
        }
        let status = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (base, status.isEmpty) {
        case (let base?, false): return "\(base) · \(status)"
        case (let base?, true): return base
        case (nil, false): return status
        case (nil, true): return nil
        }
    }

    private static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 7 * 24 * 3600 {
            // Words in full ("5 minutes ago"); the abbreviations come with full stops.
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: date, relativeTo: Date())
        }
        return "on " + date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// Keeps track of the presence of the people Huddle is showing: the other person in each
/// direct chat on screen, and more closely the one whose chat is open.
///
/// Sliding sync doesn't carry presence, so it is asked for, person by person, and only while
/// the app is in front: about every 90 seconds for the room list, every 30 for the open chat.
@MainActor @Observable
final class PresenceTracker {
    private(set) var people: [String: PresenceInfo] = [:]

    @ObservationIgnored private let client: Client
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var focused: String?
    @ObservationIgnored private var fetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Set when the server says it doesn't do presence; nothing more is asked then.
    @ObservationIgnored private var isUnsupported = false

    private static let listInterval: TimeInterval = DevHooks.presenceInterval ?? 90
    private static let focusedInterval: TimeInterval = DevHooks.presenceInterval ?? 30
    private static let mostAtOnce = 4

    init(client: Client) {
        self.client = client
    }

    /// The people to keep up to date, and the one to watch most closely.
    func watch(_ users: Set<String>, focus: String?) {
        let refocused = focus != focused
        watched = users.union(focus.map { [$0] } ?? [])
        focused = focus
        if refocused, let focus { fetchedAt[focus] = nil }       // the chat just opened: ask now
        poll()
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(min(5, DevHooks.presenceInterval ?? 5)))
            }
        }
        let center = NotificationCenter.default
        observers = [
            // Coming back to the app, see who is around now rather than as of when it was left.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.fetchedAt.removeAll()
                    self?.poll()
                }
            },
        ]
    }

    func stop() {
        loop?.cancel()
        loop = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func poll() {
        guard !isUnsupported, NSApp.isActive || DevHooks.assumesActive else { return }
        let now = Date()
        let due = watched.filter { user in
            guard !inFlight.contains(user) else { return false }
            let interval = user == focused ? Self.focusedInterval : Self.listInterval
            return now.timeIntervalSince(fetchedAt[user] ?? .distantPast) >= interval
        }
        // The open chat first; then whoever has waited longest.
        let ordered = due.sorted { a, b in
            if a == focused { return true }
            if b == focused { return false }
            return (fetchedAt[a] ?? .distantPast) < (fetchedAt[b] ?? .distantPast)
        }
        for user in ordered.prefix(max(0, Self.mostAtOnce - inFlight.count)) {
            inFlight.insert(user)
            Task { [weak self] in
                guard let self else { return }
                let result = await self.fetch(user)
                self.inFlight.remove(user)
                self.fetchedAt[user] = Date()
                switch result {
                case .info(let info): if self.people[user] != info { self.people[user] = info }
                case .unsupported: self.isUnsupported = true
                case .failed: break
                }
            }
        }
    }

    private enum FetchResult {
        case info(PresenceInfo)
        case unsupported
        case failed
    }

    /// `GET /presence/{userId}/status`, made directly: the SDK has no call for reading it.
    private func fetch(_ user: String) async -> FetchResult {
        guard let session = try? client.session(), let base = URL(string: session.homeserverUrl) else { return .failed }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = user.addingPercentEncoding(withAllowedCharacters: allowed) else { return .failed }
        var request = URLRequest(url: base.appending(path: "_matrix/client/v3/presence/\(encoded)/status", directoryHint: .notDirectory))
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .failed }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            // Servers that don't do presence say so with one of these.
            let code = body["errcode"] as? String
            return status == 403 && code == "M_FORBIDDEN" || code == "M_UNRECOGNIZED" ? .unsupported : .failed
        }
        let state: PresenceInfo.State
        switch body["presence"] as? String {
        case "online": state = (body["currently_active"] as? Bool) == false ? .away : .online
        case "unavailable": state = .away
        default: state = .offline
        }
        let ago = (body["last_active_ago"] as? NSNumber)?.doubleValue
        // To the minute, as it is shown: worked out from "how long ago", it shifts by however
        // long each answer took, so it would never come out the same twice, and every check
        // would count as a change and redraw what shows it.
        let lastActive = ago.map { Date().addingTimeInterval(-$0 / 1000) }
            .map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 / 60).rounded() * 60) }
        return .info(PresenceInfo(state: state, lastActive: lastActive, statusMessage: body["status_msg"] as? String))
    }
}

/// Tells the server whether this account is around: online while Huddle is in front, away a
/// couple of minutes after it isn't, and nothing at all if the user has chosen not to share it.
@MainActor
final class OwnPresence {
    static let sharingKey = "sharesPresence"

    private let client: Client
    private var observers: [NSObjectProtocol] = []
    private var awayTask: Task<Void, Never>?

    init(client: Client) {
        self.client = client
    }

    static var isSharing: Bool {
        UserDefaults.standard.object(forKey: sharingKey) as? Bool ?? true
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.update() }
            },
            center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.sharingMayHaveChanged() }
            },
        ]
        lastSharing = Self.isSharing
        update()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        awayTask?.cancel()
    }

    private var lastSharing = true

    private func sharingMayHaveChanged() {
        guard Self.isSharing != lastSharing else { return }
        lastSharing = Self.isSharing
        update()
    }

    private func update() {
        awayTask?.cancel()
        guard Self.isSharing else { return set(.offline) }
        if NSApp.isActive || DevHooks.assumesActive {
            set(.online)
        } else {
            // Not straight away: switching to another app for a moment isn't being away.
            awayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                self?.set(.unavailable)
            }
        }
    }

    /// Tells the SDK, which sends it with every sync from now on, and the server straight away.
    ///
    /// The SDK's own "straight away" would also wipe any status message set elsewhere (it has no
    /// way to pass one), so the server is told here instead, keeping the message as it is.
    private func set(_ state: PresenceState) {
        let client = client
        Task.detached {
            try? await client.setPresence(presence: state, immediate: false)
            guard let session = try? client.session(), let base = URL(string: session.homeserverUrl) else { return }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/?#")
            guard let user = session.userId.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
            let url = base.appending(path: "_matrix/client/v3/presence/\(user)/status", directoryHint: .notDirectory)
            func request(_ method: String, _ body: [String: Any]? = nil) -> URLRequest {
                var request = URLRequest(url: url)
                request.httpMethod = method
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 20
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try? JSONSerialization.data(withJSONObject: body)
                }
                return request
            }
            var body: [String: Any] = ["presence": Self.wireName(state)]
            if let (data, _) = try? await URLSession.shared.data(for: request("GET")),
               let current = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let message = current["status_msg"] as? String {
                body["status_msg"] = message
            }
            _ = try? await URLSession.shared.data(for: request("PUT", body))
        }
    }

    private nonisolated static func wireName(_ state: PresenceState) -> String {
        switch state {
        case .online: "online"
        case .unavailable: "unavailable"
        case .offline: "offline"
        }
    }
}
