import AppKit
import MatrixRustSDK
import Observation
import WebKit

/// A call going on here: Element Call's, or a one-to-one call of the older kind.
@MainActor
protocol HuddleCall: AnyObject {
    var account: AccountSession { get }
    var roomID: String { get }
    var title: String { get }
    /// The web page the call's sound goes through, kept out of sight in Huddle's window: WebKit
    /// lets a page use the microphone only while its window can be seen.
    var page: WKWebView? { get }
    /// Called once the call is over, to take it out of the room list.
    var onEnded: (() -> Void)? { get set }
    func hangUp()
}

extension HuddleCall {
    /// Which call it is, for lists of them.
    var identity: ObjectIdentifier { ObjectIdentifier(self) }
}

/// A one-to-one voice call of the kind Element Web makes in a direct chat: Matrix's own VoIP
/// (m.call.invite, answer, candidates, hangup), which needs nothing more of the server than
/// messages do. The two Macs connect directly, with WebKit's WebRTC carrying the sound; the call's
/// events go through the SDK's widget driver, which encrypts and decrypts them as the room needs.
@MainActor @Observable
final class LegacyCall: HuddleCall {
    enum State: Equatable {
        /// Outgoing: getting the microphone ready, before the other person is rung.
        case starting
        /// Outgoing: ringing the other person.
        case calling
        /// Incoming: ringing here, not yet answered.
        case ringing
        /// Answered, the sound not yet through.
        case connecting
        case connected(since: Date)
        case ended(Ending)
    }

    enum Ending: Equatable {
        /// Hung up here.
        case hungUp
        case theyHungUp
        case noAnswer
        case declined
        /// Incoming: the caller gave up, or the ring ran out.
        case missed
        case answeredElsewhere
        case declinedElsewhere
        case couldNotConnect
        case failed(String)
    }

    let account: AccountSession
    let roomID: String
    let title: String
    let peerID: String?
    let peerAvatarURL: String?
    let isOutgoing: Bool
    let callID: String
    /// This device's part in the call: its device ID, as Element's clients use.
    let partyID: String
    /// The invite's event, for an incoming call.
    let inviteEventID: String?
    /// When an incoming call stops ringing.
    let expires: Date
    /// An incoming call offered with video: answered with voice only here.
    let offersVideo: Bool

    private(set) var state: State
    private(set) var isMuted = false
    private(set) var peerIsMuted = false

    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored let media = CallMedia()
    /// What the caller hears while the other person is rung.
    @ObservationIgnored private let ringback = Ringback()
    var page: WKWebView? { media.webView }
    @ObservationIgnored private let signals = CallSignals()
    @ObservationIgnored private var offerSDP: String?
    /// The other side's device in the call: the caller's, or the one that answered.
    @ObservationIgnored private var opponentPartyID: String?
    @ObservationIgnored private var hasRemoteDescription = false
    /// Their candidates, by device, until the one to connect to is known.
    @ObservationIgnored private var remoteCandidates: [String: [[String: Any]]] = [:]
    @ObservationIgnored private var localCandidates: [[String: Any]] = []
    /// The invite or answer has gone out, so candidates can follow it.
    @ObservationIgnored private var hasSignalled = false
    @ObservationIgnored private var wasAnswered = false
    @ObservationIgnored private var streamID: String?
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var seenEvents: Set<String> = []

    /// How long a call rings before it's given up, as Element's clients have it.
    private static let ringLifetime: TimeInterval = 60
    /// The longest an incoming call rings, whatever the caller sets.
    static let longestRing: TimeInterval = 120
    /// How long an answered call has to get its sound through.
    private static let connectTimeout: TimeInterval = 30

    var isRinging: Bool { state == .ringing }

    var isEnded: Bool {
        if case .ended = state { return true }
        return false
    }

    /// Calls someone: `start()` rings them.
    init(calling account: AccountSession, roomID: String, title: String, peerID: String?, peerAvatarURL: String?) {
        self.account = account
        self.roomID = roomID
        self.title = title
        self.peerID = peerID
        self.peerAvatarURL = peerAvatarURL
        isOutgoing = true
        callID = "\(Int(Date().timeIntervalSince1970 * 1000))\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))"
        partyID = account.currentDeviceID ?? UUID().uuidString
        inviteEventID = nil
        expires = .distantFuture
        offersVideo = false
        state = .starting
        wireMedia()
    }

    /// A call ringing in, from its invite event (as the SDK decrypted it); nil if it isn't one to
    /// ring for: for someone else, run out, or not understood.
    init?(invite raw: String, account: AccountSession, roomID: String, title: String,
          callerID: String, callerAvatarURL: String?) {
        guard let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = event["content"] as? [String: Any],
              let callID = content["call_id"] as? String,
              let offer = content["offer"] as? [String: Any],
              let sdp = offer["sdp"] as? String else { return nil }
        if let invitee = content["invitee"] as? String, invitee != account.userID { return nil }
        // When it was sent, as near as this Mac can tell: how old the server said it was, if it
        // did, rather than the server's clock against this one.
        // No longer than two minutes, whatever the caller asks: it's theirs to say, and a ring
        // that never ends would be a nuisance anyone in the room could make.
        let lifetime = min(((content["lifetime"] as? NSNumber)?.doubleValue ?? Self.ringLifetime * 1000) / 1000,
                           Self.longestRing)
        let sent: Date
        if let age = (event["unsigned"] as? [String: Any])?["age"] as? NSNumber {
            sent = Date().addingTimeInterval(-age.doubleValue / 1000)
        } else if let timestamp = event["origin_server_ts"] as? NSNumber {
            sent = Date(timeIntervalSince1970: timestamp.doubleValue / 1000)
        } else {
            sent = .now
        }
        let expires = sent.addingTimeInterval(lifetime)
        guard expires > Date().addingTimeInterval(1) else { return nil }

        self.account = account
        self.roomID = roomID
        self.title = title
        peerID = callerID
        peerAvatarURL = callerAvatarURL
        isOutgoing = false
        self.callID = callID
        partyID = account.currentDeviceID ?? UUID().uuidString
        inviteEventID = event["event_id"] as? String
        self.expires = expires
        offersVideo = sdp.contains("\nm=video") || sdp.hasPrefix("m=video")
        offerSDP = sdp
        opponentPartyID = content["party_id"] as? String
        state = .ringing
        peerIsMuted = Self.isAudioMuted(in: content) ?? false
        wireMedia()
    }

    private func wireMedia() {
        media.onCandidate = { [weak self] candidate in self?.queue(candidate) }
        media.onConnection = { [weak self] state in self?.connectionChanged(state) }
    }

    // MARK: Calling

    /// Rings the other person: the microphone, the offer, and the invite with it.
    func start() async {
        Self.log("\(account.userID) calls in \(roomID), call \(callID)")
        guard let room = account.room(id: roomID) else { return finish(.failed("The room isn’t available.")) }
        do {
            try signals.start(in: room) { [weak self] event in self?.handle(event) }
        } catch {
            return finish(.failed(error.actionMessage))
        }
        let servers = await Self.iceServers(for: account)
        do {
            streamID = try await media.open(iceServers: servers)
            guard state == .starting else { return }
            let sdp = try await media.makeOffer()
            guard state == .starting else { return }
            var content = base
            content["lifetime"] = Int(Self.ringLifetime * 1000)
            content["offer"] = ["type": "offer", "sdp": sdp]
            if let peerID { content["invitee"] = peerID }
            content.merge(metadata) { $1 }
            try await signals.send("m.call.invite", content: content)
            // Hung up while the invite went out: take it back.
            guard state == .starting else {
                Task { [signals, base] in try? await signals.send("m.call.hangup", content: base.merging(["reason": "user_hangup"]) { $1 }) }
                return
            }
            state = .calling
            ringback.start()
            hasSignalled = true
            flushCandidates()
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.ringLifetime))
                guard let self, !Task.isCancelled, self.state == .calling else { return }
                self.finish(.noAnswer, sending: self.hangupEvent("invite_timeout"))
            }
        } catch {
            finish(.failed(Self.message(for: error)))
        }
    }

    // MARK: Answering

    /// Listens for the call's events while it rings: the caller giving up, or another of this
    /// account's devices answering.
    func startRinging() {
        Self.log("\(account.userID) rung in \(roomID), call \(callID)")
        guard let room = account.room(id: roomID) else { return finish(.missed) }
        do {
            try signals.start(in: room) { [weak self] event in self?.handle(event) }
        } catch {
            return finish(.missed)
        }
        timeoutTask = Task { [weak self, expires] in
            try? await Task.sleep(for: .seconds(max(0, expires.timeIntervalSinceNow)))
            guard let self, !Task.isCancelled, self.state == .ringing else { return }
            self.finish(.missed)
        }
        // What came between the invite and listening, where the server can find it (in a room
        // that isn't encrypted; in one that is, the offer carries what candidates it needs).
        Task { [weak self, signals] in
            var events: [[String: Any]] = []
            for type in ["m.call.candidates", "m.call.hangup", "m.call.answer", "m.call.reject"] {
                events += (try? await signals.read(type, limit: 20)) ?? []
            }
            events.sort { (($0["origin_server_ts"] as? NSNumber)?.doubleValue ?? 0) < (($1["origin_server_ts"] as? NSNumber)?.doubleValue ?? 0) }
            for event in events { self?.handle(event) }
        }
    }

    func answer() {
        guard state == .ringing, let offerSDP else { return }
        state = .connecting
        wasAnswered = true
        timeoutTask?.cancel()
        Task {
            let servers = await Self.iceServers(for: account)
            do {
                streamID = try await media.open(iceServers: servers)
                guard !isEnded else { return }
                let sdp = try await media.makeAnswer(to: offerSDP)
                hasRemoteDescription = true
                // The sound may be through already (the caller's side answers checks before it has
                // the answer): only a call that's over goes no further.
                guard !isEnded else { return }
                await applyCandidates(from: opponentPartyID)
                var content = base
                content["answer"] = ["type": "answer", "sdp": sdp]
                content.merge(metadata) { $1 }
                try await signals.send("m.call.answer", content: content)
                hasSignalled = true
                flushCandidates()
                watchConnection()
            } catch {
                // The caller is still ringing: tell them it's not going to be answered.
                finish(.failed(Self.message(for: error)), sending: hasSignalled ? hangupEvent("user_media_failed") : rejectEvent)
            }
        }
    }

    /// Declines a call ringing here.
    func reject() {
        guard state == .ringing else { return }
        finish(.hungUp, sending: rejectEvent)
    }

    /// Stops listening for a call that rang here without being answered, saying nothing to anyone:
    /// another device of this account may still answer it.
    func abandon() {
        guard state == .ringing else { return }
        finish(.missed)
    }

    // MARK: During the call

    func hangUp() {
        switch state {
        case .ended:
            onEnded?()
        case .starting:
            finish(.hungUp)
        case .ringing:
            reject()
        case .calling, .connecting, .connected:
            finish(.hungUp, sending: hangupEvent("user_hangup"))
        }
    }

    func toggleMute() {
        isMuted.toggle()
        media.setMuted(isMuted)
        guard hasSignalled, !isEnded else { return }
        Task { [signals, base, metadata] in
            do {
                try await signals.send("m.call.sdp_stream_metadata_changed", content: base.merging(metadata) { $1 })
            } catch {
                Self.log("mute not sent: \(error)")
            }
        }
    }

    /// Whether the microphone can be muted yet.
    var canMute: Bool {
        switch state {
        case .calling, .connecting, .connected: true
        default: false
        }
    }

    // MARK: Their events

    private func handle(_ event: [String: Any]) {
        guard let type = event["type"] as? String,
              let content = event["content"] as? [String: Any],
              content["call_id"] as? String == callID, !isEnded else { return }
        if let id = event["event_id"] as? String, !seenEvents.insert(id).inserted { return }
        let sender = event["sender"] as? String ?? ""
        let party = content["party_id"] as? String
        let fromThisAccount = sender == account.userID
        // This device's own, back from the server.
        if fromThisAccount, party == partyID { return }
        Self.log("\(account.userID) got \(type) from \(sender) \(party ?? "-") in state \(state)")

        switch type {
        case "m.call.answer":
            if fromThisAccount {
                if state == .ringing { finish(.answeredElsewhere) }
            } else if isOutgoing, state == .calling,
                      let answer = content["answer"] as? [String: Any], let sdp = answer["sdp"] as? String {
                accept(sdp, from: party, content: content)
            }
        case "m.call.select_answer":
            if !isOutgoing, wasAnswered, let selected = content["selected_party_id"] as? String, selected != partyID {
                finish(.answeredElsewhere)
            }
        case "m.call.reject":
            if isOutgoing, state == .calling {
                finish(.declined)
            } else if fromThisAccount, state == .ringing {
                finish(.declinedElsewhere)
            }
        case "m.call.hangup":
            switch state {
            case .ringing:
                finish(fromThisAccount ? .declinedElsewhere : .missed)
            case .calling:
                finish(.declined)
            default:
                if opponentPartyID == nil || party == opponentPartyID { finish(.theyHungUp) }
            }
        case "m.call.candidates":
            let list = content["candidates"] as? [[String: Any]] ?? []
            let key = party ?? ""
            if hasRemoteDescription, key == (opponentPartyID ?? "") {
                Task { await media.addCandidates(list) }
            } else {
                remoteCandidates[key, default: []] += list
            }
        case "m.call.negotiate":
            guard party == opponentPartyID, let description = content["description"] as? [String: Any],
                  let kind = description["type"] as? String, let sdp = description["sdp"] as? String else { return }
            if let muted = Self.isAudioMuted(in: content) { peerIsMuted = muted }
            Task {
                guard let answer = try? await media.renegotiate(kind, sdp: sdp) else { return }
                var reply = base
                reply["lifetime"] = 10_000
                reply["description"] = ["type": "answer", "sdp": answer]
                reply.merge(metadata) { $1 }
                try? await signals.send("m.call.negotiate", content: reply)
            }
        case "m.call.sdp_stream_metadata_changed", "org.matrix.call.sdp_stream_metadata_changed":
            if party == opponentPartyID, let muted = Self.isAudioMuted(in: content) { peerIsMuted = muted }
        default:
            break
        }
    }

    /// The first answer to an outgoing call: the one connected to, the others told so.
    private func accept(_ sdp: String, from party: String?, content: [String: Any]) {
        opponentPartyID = party
        state = .connecting
        ringback.stop()
        timeoutTask?.cancel()
        if let muted = Self.isAudioMuted(in: content) { peerIsMuted = muted }
        Task {
            do {
                try await media.accept(answer: sdp)
                hasRemoteDescription = true
                await applyCandidates(from: party)
                watchConnection()
                var selection = base
                selection["selected_party_id"] = party ?? ""
                try? await signals.send("m.call.select_answer", content: selection)
            } catch {
                finish(.couldNotConnect, sending: hangupEvent("ice_failed"))
            }
        }
    }

    private func applyCandidates(from party: String?) async {
        let list = remoteCandidates[party ?? ""] ?? []
        remoteCandidates = [:]
        if !list.isEmpty { await media.addCandidates(list) }
    }

    // MARK: The connection

    private func queue(_ candidate: [String: Any]) {
        localCandidates.append(candidate)
        flushCandidates()
    }

    /// Sends this side's candidates in batches, as Element's clients do, once the invite or answer
    /// is out (those already carry the ones found before them).
    private func flushCandidates() {
        guard hasSignalled, flushTask == nil, !localCandidates.isEmpty, !isEnded else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            let batch = self.localCandidates
            self.localCandidates = []
            var content = self.base
            content["candidates"] = batch
            try? await self.signals.send("m.call.candidates", content: content)
            self.flushTask = nil
            self.flushCandidates()
        }
    }

    private func connectionChanged(_ connection: String) {
        switch connection {
        case "connected":
            if state == .connecting {
                state = .connected(since: .now)
                timeoutTask?.cancel()
                if AppEnvironment.isDev {
                    // Dev: whether sound is going both ways, a moment in and every so often after.
                    Task { [weak self] in
                        var delay = 4.0
                        while true {
                            try? await Task.sleep(for: .seconds(delay))
                            guard let self, !self.isEnded else { return }
                            let stats = await self.media.stats()
                            Self.log("\(self.account.userID) sound: \(stats)")
                            delay = 10
                        }
                    }
                }
            }
        case "failed":
            if !isEnded { finish(.couldNotConnect, sending: hangupEvent("ice_failed")) }
        default:
            break
        }
    }

    /// Gives up on an answered call whose sound never gets through.
    private func watchConnection() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeout))
            guard let self, !Task.isCancelled, self.state == .connecting else { return }
            self.finish(.couldNotConnect, sending: self.hangupEvent("ice_failed"))
        }
    }

    // MARK: Ending

    private func finish(_ ending: Ending, sending event: (type: String, content: [String: Any])? = nil) {
        guard !isEnded else { return }
        Self.log("\(account.userID) ended: \(ending)\(event.map { ", sending \($0.type)" } ?? "")")
        state = .ended(ending)
        ringback.stop()
        timeoutTask?.cancel()
        flushTask?.cancel()
        media.close()
        let sent = Task { [signals] in
            if let event { try? await signals.send(event.type, content: event.content) }
        }
        Task { [signals] in
            await sent.value
            signals.stop()
        }
        // Hung up here, or never answered: gone once the other side has been told (or a moment
        // has passed trying; the app waits that long to quit). Ended by the other side: said so
        // for a moment first. A failure stays until it's closed.
        if case .failed = ending, isOutgoing || wasAnswered { return }
        let lingers = ending != .hungUp && (isOutgoing || wasAnswered)
        Task { [weak self] in
            if lingers {
                try? await Task.sleep(for: .seconds(1.5))
            } else if event != nil {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await sent.value }
                    group.addTask { try? await Task.sleep(for: .seconds(1.8)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            self?.onEnded?()
        }
    }

    // MARK: Event content

    private var base: [String: Any] {
        ["call_id": callID, "party_id": partyID, "version": "1"]
    }

    /// Dev: how the call goes, in the log.
    static func log(_ text: @autoclosure () -> String) {
        guard AppEnvironment.isDev else { return }
        print("LEGACYCALL", text())
        fflush(stdout)
    }

    private func hangupEvent(_ reason: String) -> (type: String, content: [String: Any]) {
        ("m.call.hangup", base.merging(["reason": reason]) { $1 })
    }

    private var rejectEvent: (type: String, content: [String: Any]) {
        ("m.call.reject", base)
    }

    /// Where the streams' metadata goes: the spec's name, which Element's clients have used since
    /// 2026, and MSC3077's, which they used before (and still read).
    private static let metadataKeys = ["sdp_stream_metadata", "org.matrix.msc3077.sdp_stream_metadata"]

    /// What this side sends, for the other side to show: voice, muted or not. Under both names,
    /// for clients that know only one.
    private var metadata: [String: Any] {
        guard let streamID else { return [:] }
        let streams = [streamID: ["purpose": "m.usermedia", "audio_muted": isMuted, "video_muted": true]]
        return Dictionary(uniqueKeysWithValues: Self.metadataKeys.map { ($0, streams) })
    }

    private static func isAudioMuted(in content: [String: Any]) -> Bool? {
        guard let streams = metadataKeys.lazy.compactMap({ content[$0] as? [String: [String: Any]] }).first
        else { return nil }
        let voice = streams.values.filter { $0["purpose"] as? String == "m.usermedia" }
        guard !voice.isEmpty else { return nil }
        return voice.allSatisfy { $0["audio_muted"] as? Bool == true }
    }

    private static func message(for error: Error) -> String {
        log("failed: \(error)")
        if CallMedia.isMicrophoneError(error) {
            return "Huddle can’t use the microphone. You can allow it in System Settings › Privacy & Security › Microphone."
        }
        return "The call couldn’t be set up."
    }

    /// Settings ▸ Privacy: whether matrix.org's STUN server may help when the homeserver has none.
    static let matrixOrgFallbackKey = "callsUseMatrixOrgFallback"

    static var usesMatrixOrgFallback: Bool {
        UserDefaults.standard.object(forKey: matrixOrgFallbackKey) as? Bool ?? true
    }

    /// Where the call can find a way between the two Macs: the homeserver's TURN server if it has
    /// one; otherwise, unless turned off in Settings, the fallback Element offers, matrix.org's
    /// STUN server, which sees this Mac's address while the call connects. (Not in Dev, whose
    /// test calls stay on this Mac.)
    static func iceServers(for account: AccountSession) async -> [[String: Any]] {
        var servers: [[String: Any]] = []
        if let session = try? account.client.session(), var url = URL(string: session.homeserverUrl) {
            url.append(path: "_matrix/client/v3/voip/turnServer")
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let uris = object["uris"] as? [String], !uris.isEmpty {
                var server: [String: Any] = ["urls": uris]
                if let username = object["username"] as? String { server["username"] = username }
                if let password = object["password"] as? String { server["credential"] = password }
                servers.append(server)
            }
        }
        let fallsBack = servers.isEmpty && usesMatrixOrgFallback
        if AppEnvironment.isDev {
            // Dev's test calls stay on this Mac: whether matrix.org would be asked is only noted.
            print("DEV_ICE_SERVERS \(servers.flatMap { $0["urls"] as? [String] ?? [] }) matrixOrg=\(fallsBack)")
            fflush(stdout)
        } else if fallsBack {
            servers.append(["urls": ["stun:turn.matrix.org"]])
        }
        return servers
    }
}

// MARK: - Signalling

/// A call's events in its room, sent and received through the SDK's widget driver, with Huddle as
/// the "widget": allowed the call's own event types and nothing else.
@MainActor
final class CallSignals {
    enum Failure: Error {
        case notConnected
        case refused(String)
    }

    /// Their stable names: the driver takes an older name it knows as the stable one, and, patched
    /// (Scripts/sdk-patches), lets through events sent under either, as Element's clients sent
    /// org.matrix.call.sdp_stream_metadata_changed until 2026.
    private static let eventTypes = [
        "m.call.invite", "m.call.candidates", "m.call.answer", "m.call.select_answer", "m.call.reject",
        "m.call.hangup", "m.call.negotiate", "m.call.sdp_stream_metadata_changed",
    ]

    private static let capabilities = eventTypes.flatMap {
        ["org.matrix.msc2762.send.event:\($0)", "org.matrix.msc2762.receive.event:\($0)"]
    }

    private let widgetID = "huddle-call-\(UUID().uuidString)"
    private var driver: WidgetDriverAndHandle?
    private var tasks: [Task<Void, Never>] = []
    private var replies: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var readiness: [CheckedContinuation<Bool, Never>] = []
    private var isReady = false
    private var isStopped = false
    private var hasGivenUp = false
    private var onEvent: (([String: Any]) -> Void)?

    func start(in room: Room, onEvent: @escaping ([String: Any]) -> Void) throws {
        self.onEvent = onEvent
        let driver = try makeWidgetDriver(settings: WidgetSettings(
            widgetId: widgetID, initAfterContentLoad: false, rawUrl: "https://huddle.invalid/call"))
        self.driver = driver
        let widget = driver.driver
        let provider = CallSignalCapabilities()
        tasks.append(Task.detached {
            await widget.run(room: room, capabilitiesProvider: provider)
        })
        let handle = driver.handle
        tasks.append(Task { [weak self] in
            while let message = await handle.recv() {
                guard let self, !Task.isCancelled else { return }
                self.received(message)
            }
        })
        // The driver asks what's wanted, then says what's allowed; if that doesn't happen, nothing
        // will be sent.
        tasks.append(Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, !self.isReady else { return }
            LegacyCall.log("signals: no capabilities from the driver")
            self.hasGivenUp = true
            self.settle(ready: false)
        })
    }

    @discardableResult
    func send(_ type: String, content: [String: Any]) async throws -> String? {
        let response = try await request("send_event", data: ["type": type, "content": content])
        return response["event_id"] as? String
    }

    /// The room's latest events of a type, newest first, as far as the server can tell them apart
    /// (not in an encrypted room).
    func read(_ type: String, limit: Int) async throws -> [[String: Any]] {
        let response = try await request("org.matrix.msc2876.read_events", data: ["type": type, "limit": limit])
        return response["events"] as? [[String: Any]] ?? []
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for task in tasks { task.cancel() }
        tasks = []
        driver = nil
        settle(ready: false)
        let waiting = replies
        replies = [:]
        for continuation in waiting.values { continuation.resume(throwing: Failure.notConnected) }
    }

    private func request(_ action: String, data: [String: Any]) async throws -> [String: Any] {
        guard await ready(), let handle = driver?.handle else { throw Failure.notConnected }
        let id = UUID().uuidString
        let message: [String: Any] = [
            "api": "fromWidget", "widgetId": widgetID, "requestId": id, "action": action, "data": data,
        ]
        // In key order: the driver reads the event inside `data` only if `action` has come first.
        let json = String(decoding: try JSONSerialization.data(withJSONObject: message, options: .sortedKeys), as: UTF8.self)
        let response = try await withCheckedThrowingContinuation { continuation in
            replies[id] = continuation
            if !handle.send(msg: json) {
                replies.removeValue(forKey: id)?.resume(throwing: Failure.notConnected)
            }
        }
        if let error = response["error"] as? [String: Any] {
            LegacyCall.log("signals \(widgetID.suffix(6)): \(action) \((data["type"] as? String) ?? "") refused: \(error)")
            throw Failure.refused(error["message"] as? String ?? "")
        }
        LegacyCall.log("signals \(widgetID.suffix(6)): \(action) \((data["type"] as? String) ?? "") done")
        return response
    }

    private func ready() async -> Bool {
        if isReady { return true }
        if isStopped || hasGivenUp { return false }
        return await withCheckedContinuation { readiness.append($0) }
    }

    private func settle(ready: Bool) {
        if ready { isReady = true }
        let waiting = readiness
        readiness = []
        for continuation in waiting { continuation.resume(returning: ready) }
    }

    /// A message from the driver: its answer to a request of ours, or a request of its own.
    private func received(_ message: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any] else { return }
        if object["api"] as? String == "fromWidget" {
            if let id = object["requestId"] as? String, let response = object["response"] as? [String: Any] {
                replies.removeValue(forKey: id)?.resume(returning: response)
            }
            return
        }
        guard object["api"] as? String == "toWidget", object["response"] == nil else { return }
        LegacyCall.log("signals \(widgetID.suffix(6)): driver asks \(object["action"] as? String ?? "?")")
        var response: [String: Any] = [:]
        switch object["action"] as? String {
        case "capabilities":
            response = ["capabilities": Self.capabilities]
        case "notify_capabilities":
            settle(ready: true)
        case "send_event":
            if let event = object["data"] as? [String: Any] { onEvent?(event) }
        default:
            break
        }
        var reply = object
        reply["response"] = response
        if let data = try? JSONSerialization.data(withJSONObject: reply, options: .sortedKeys) {
            _ = driver?.handle.send(msg: String(decoding: data, as: UTF8.self))
        }
    }
}

/// The call's own events, which it asks for, are all it gets.
private final class CallSignalCapabilities: WidgetCapabilitiesProvider, @unchecked Sendable {
    func acquireCapabilities(capabilities: WidgetCapabilities) async -> WidgetCapabilities {
        capabilities
    }
}

// MARK: - Sound

/// The call's sound: WebKit's WebRTC, in a web view kept out of sight in Huddle's window.
@MainActor
final class CallMedia: NSObject, WKNavigationDelegate, WKUIDelegate {
    var onCandidate: (([String: Any]) -> Void)?
    var onConnection: ((String) -> Void)?

    private(set) lazy var webView: WKWebView = makeWebView()
    private var isLoaded = false
    private var loading: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false

    static func isMicrophoneError(_ error: Error) -> Bool {
        let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
        return message?.contains("huddle:microphone") == true
    }

    /// The microphone and the connection, set up; the stream's ID, for Element's clients to know
    /// it by.
    func open(iceServers: [[String: Any]]) async throws -> String {
        try await run("return await huddle.open(iceServers, silent, muted)", [
            "iceServers": iceServers,
            // Dev, without a microphone: a silent stand-in, so the call still connects.
            "silent": DevHooks.deniesMicrophone,
            "muted": DevHooks.mutesAudio,
        ]) as? String ?? ""
    }

    func makeOffer() async throws -> String {
        try await run("return await huddle.offer()") as? String ?? ""
    }

    func makeAnswer(to offer: String) async throws -> String {
        try await run("return await huddle.answer(sdp)", ["sdp": offer]) as? String ?? ""
    }

    func accept(answer: String) async throws {
        _ = try await run("return await huddle.accept(sdp)", ["sdp": answer])
    }

    /// The other side changing the call: their new offer answered, or their answer taken.
    func renegotiate(_ type: String, sdp: String) async throws -> String? {
        try await run("return await huddle.renegotiate(type, sdp)", ["type": type, "sdp": sdp]) as? String
    }

    func addCandidates(_ candidates: [[String: Any]]) async {
        _ = try? await run("return await huddle.candidates(list)", ["list": candidates])
    }

    /// Bytes of sound sent and received so far, for the Dev log.
    func stats() async -> String {
        (try? await run("return await huddle.stats()")).map { "\($0)" } ?? "none"
    }

    func setMuted(_ muted: Bool) {
        guard isLoaded, !isClosed else { return }
        Task { _ = try? await run("huddle.mute(on)", ["on": muted]) }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        guard isLoaded else { return }
        webView.evaluateJavaScript("huddle.close()")
    }

    private func run(_ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
        await load()
        return try await webView.callAsyncJavaScript(body, arguments: arguments, contentWorld: .page)
    }

    private func load() async {
        _ = webView
        if isLoaded { return }
        await withCheckedContinuation { loading.append($0) }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // The call goes on at full speed with Huddle's window covered, in the Dock or closed.
        configuration.preferences.inactiveSchedulingPolicy = .none
        configuration.userContentController.add(CallMediaMessages(self), name: "legacyCall")
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        if AppEnvironment.isDev { view.isInspectable = true }
        // A file origin, as Element Call's: WebKit counts it secure, so it may ask for the microphone.
        view.loadHTMLString(Self.page, baseURL: Bundle.main.bundleURL)
        return view
    }

    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], !isClosed else { return }
        switch message["kind"] as? String {
        case "candidate":
            if let candidate = message["candidate"] as? [String: Any] { onCandidate?(candidate) }
        case "connection":
            if let state = message["state"] as? String {
                LegacyCall.log("connection \(state)")
                onConnection?(state)
            }
        case "log":
            LegacyCall.log(message["text"] as? String ?? "")
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        let waiting = loading
        loading = []
        for continuation in waiting { continuation.resume() }
    }

    /// Only the page itself loads: nothing into frames, and nothing in place of it.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let isPage = action.targetFrame?.isMainFrame == true && action.request.url.map(Self.isPage) == true
        decisionHandler(isPage ? .allow : .cancel)
    }

    /// The page's address: the app's folder, where it's loaded from, or the blank page.
    fileprivate static func isPage(_ url: URL) -> Bool {
        url.absoluteString == "about:blank"
            || (url.isFileURL && url.standardizedFileURL.path == Bundle.main.bundleURL.standardizedFileURL.path)
    }

    /// The microphone, for the call's own page only; never the camera.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let allowed = origin.protocol == "file" && type == .microphone && !DevHooks.deniesMicrophone
        LegacyCall.log("page asks for \(type == .microphone ? "the microphone" : "a camera") from \(origin.protocol): \(allowed ? "granted" : "denied")")
        decisionHandler(allowed ? .grant : .deny)
    }

    /// The page: a connection to the other Mac, the microphone into it and their sound out.
    private static let page = """
    <!doctype html>
    <html><head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; media-src mediastream: blob:"></head>
    <body><audio id="sound" autoplay></audio>
    <script>
    "use strict";
    const post = (message) => window.webkit.messageHandlers.legacyCall.postMessage(message);
    const sound = document.getElementById("sound");
    let peer = null, local = null, context = null, trickling = false, reported = null;

    // Waits a moment for candidates to be found, so the offer or answer carries them.
    function gathered(limit) {
        return new Promise((resolve) => {
            if (peer.iceGatheringState === "complete") return resolve();
            const finish = () => {
                clearTimeout(timer);
                peer && peer.removeEventListener("icegatheringstatechange", changed);
                resolve();
            };
            const changed = () => { if (peer.iceGatheringState === "complete") finish(); };
            const timer = setTimeout(finish, limit);
            peer.addEventListener("icegatheringstatechange", changed);
        });
    }

    async function microphone(silent) {
        // Dev, without a microphone: a silent stand-in, not asked for (WebKit holds back asking
        // until the page is in sight, and Dev's window is kept behind during tests).
        if (silent) {
            context = new AudioContext();
            const destination = context.createMediaStreamDestination();
            const tone = context.createOscillator();
            const gain = context.createGain();
            gain.gain.value = 0;
            tone.connect(gain);
            gain.connect(destination);
            tone.start();
            return destination.stream;
        }
        try {
            return await navigator.mediaDevices.getUserMedia({
                audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }, video: false,
            });
        } catch (error) {
            post({ kind: "log", text: "microphone: " + error.name + " (secure context: " + window.isSecureContext + ")" });
            throw new Error("huddle:microphone");
        }
    }

    function report(state) {
        if (state === reported) return;
        reported = state;
        post({ kind: "connection", state });
    }

    window.huddle = {
        async open(iceServers, silent, muted) {
            sound.muted = muted;
            local = await microphone(silent);
            peer = new RTCPeerConnection({ iceServers });
            for (const track of local.getAudioTracks()) peer.addTrack(track, local);
            peer.onicecandidate = (event) => {
                const c = event.candidate;
                if (!trickling || !c || !c.candidate) return;
                post({ kind: "candidate", candidate: { candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex } });
            };
            peer.onconnectionstatechange = () => {
                const state = peer.connectionState;
                if (state === "connected" || state === "failed") report(state);
            };
            peer.oniceconnectionstatechange = () => {
                const state = peer.iceConnectionState;
                if (state === "connected" || state === "completed") report("connected");
                else if (state === "failed") report("failed");
            };
            peer.ontrack = (event) => {
                if (event.track.kind !== "audio") return;
                sound.srcObject = event.streams[0] || new MediaStream([event.track]);
                sound.play().catch(() => {});
            };
            return local.id;
        },
        async offer() {
            await peer.setLocalDescription(await peer.createOffer());
            await gathered(1500);
            trickling = true;
            return peer.localDescription.sdp;
        },
        async answer(sdp) {
            await peer.setRemoteDescription({ type: "offer", sdp });
            await peer.setLocalDescription(await peer.createAnswer());
            await gathered(1500);
            trickling = true;
            return peer.localDescription.sdp;
        },
        async accept(sdp) {
            await peer.setRemoteDescription({ type: "answer", sdp });
        },
        async renegotiate(type, sdp) {
            await peer.setRemoteDescription({ type, sdp });
            if (type !== "offer") return null;
            await peer.setLocalDescription(await peer.createAnswer());
            return peer.localDescription.sdp;
        },
        async candidates(list) {
            for (const candidate of list) {
                if (!candidate || !candidate.candidate) continue;
                try { await peer.addIceCandidate(candidate); } catch (error) {}
            }
        },
        mute(on) {
            if (local) for (const track of local.getAudioTracks()) track.enabled = !on;
        },
        async stats() {
            if (!peer) return null;
            let sent = 0, received = 0;
            (await peer.getStats()).forEach((report) => {
                if (report.type === "outbound-rtp" && report.kind === "audio") sent += report.bytesSent || 0;
                if (report.type === "inbound-rtp" && report.kind === "audio") received += report.bytesReceived || 0;
            });
            return "sent " + sent + " bytes, received " + received + " bytes";
        },
        close() {
            try { if (peer) peer.close(); } catch (error) {}
            if (local) for (const track of local.getTracks()) track.stop();
            if (context) context.close();
            sound.srcObject = null;
            peer = null;
            local = null;
        },
    };
    </script></body></html>
    """
}

/// Passes the page's messages on without keeping the page alive.
private final class CallMediaMessages: NSObject, WKScriptMessageHandler {
    private weak var media: CallMedia?

    @MainActor init(_ media: CallMedia) {
        self.media = media
    }

    /// Only from the page itself, in the main frame: the handler is there for every frame.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "file",
              message.frameInfo.request.url.map(CallMedia.isPage) == true else { return }
        let body = message.body
        MainActor.assumeIsolated { media?.received(body) }
    }
}
