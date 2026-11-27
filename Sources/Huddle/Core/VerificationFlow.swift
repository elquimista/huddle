import Foundation
import MatrixRustSDK
import Observation

/// Emoji verification for one account, through the SDK's verification controller: this Mac
/// asking the account's other devices to vouch for it, and other devices, or other people,
/// asking to verify with it. Both sides show the same seven emoji; once the person checking
/// says they match on both, each side trusts the other.
@MainActor @Observable
final class VerificationFlow {
    enum Step: Equatable {
        case idle
        /// This Mac asked the account's other devices; waiting for one of them to accept.
        case requesting
        /// Another device, or another person, asks to verify; waiting for an answer here.
        case incoming
        /// Accepted; the two sides are working out the emoji.
        case starting
        /// The emoji, or numbers, to compare.
        case comparing(Code)
        /// They match here; waiting for the other side to say so too.
        case confirming(Code)
        case verified
        /// It stopped without verifying anything.
        case ended(Ending)

        /// Under way: closing the window that shows it stops it.
        var isActive: Bool {
            switch self {
            case .requesting, .incoming, .starting, .comparing, .confirming: true
            case .idle, .verified, .ended: false
            }
        }
    }

    enum Code: Equatable, Sendable {
        case emoji([Emoji])
        case numbers([UInt16])
    }

    struct Emoji: Equatable, Hashable, Sendable {
        let symbol: String
        let name: String
    }

    enum Ending: Equatable {
        /// Someone said the emoji didn't match, here or on the other side.
        case mismatch
        /// The other side stopped it.
        case cancelledThere
        case timedOut
        /// Another of this account's devices answered the request.
        case answeredElsewhere
        case failed(String)
    }

    /// What is being verified.
    enum Subject: Equatable {
        /// This Mac, by one of the account's devices that already is.
        case thisMac
        /// Another of the account's devices, by this one.
        case device(name: String?, id: String)
        /// Someone else.
        case person(id: String, name: String?)
    }

    /// A request from elsewhere: who sent it, from which device.
    struct Request: Equatable {
        let flowID: String
        let senderID: String
        let senderName: String?
        let senderAvatarURL: String?
        let deviceID: String
        let deviceName: String?
        /// When the server first saw that device.
        let firstSeen: Date?
    }

    private(set) var step: Step = .idle
    private(set) var subject: Subject = .thisMac
    private(set) var request: Request?
    /// A request from elsewhere, in a line: for a banner, or a notification.
    var requestSummary: String? {
        guard let request else { return nil }
        let device = "“\(request.deviceName ?? request.deviceID)”"
        switch subject {
        case .thisMac: return "\(device) wants to verify this Mac"
        case .device: return "\(device) asks to be verified"
        case .person(let id, let name): return "\(name ?? id) wants to verify with you"
        }
    }

    /// Whether a window is showing the flow; one coming in is announced otherwise.
    var isShown: Bool { shownCount > 0 }
    private var shownCount = 0

    /// Whether this Mac is verified: a request from the account's own device then asks to verify
    /// that device, not this one.
    @ObservationIgnored var isThisMacVerified: () -> Bool = { false }
    /// Called when a request comes in from elsewhere.
    @ObservationIgnored var onIncoming: () -> Void = {}
    /// Called with someone's user ID once they are verified.
    @ObservationIgnored var onVerifiedPerson: (String) -> Void = { _ in }

    @ObservationIgnored private let client: Client
    @ObservationIgnored private let userID: String
    @ObservationIgnored private var controller: SessionVerificationController?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    /// Whether the emoji exchange itself has begun, which decides whose reason for stopping counts.
    @ObservationIgnored private var sasStarted = false

    init(client: Client, userID: String) {
        self.client = client
        self.userID = userID
    }

    // MARK: Connecting

    /// Gets the SDK's controller, which only exists once the account's identity is known: right
    /// after signing in to a new account it isn't yet, so this keeps trying, less often each time.
    /// Requests from elsewhere reach this Mac only once it has one.
    func connect() {
        guard connectTask == nil else { return }
        connectTask = Task { [weak self, client] in
            var delay = 2.0
            while !Task.isCancelled {
                if let controller = try? await client.getSessionVerificationController() {
                    self?.attach(controller)
                    return
                }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 60)
            }
        }
    }

    func disconnect() {
        connectTask?.cancel()
        eventsTask?.cancel()
        startTask?.cancel()
        connectTask = nil
        eventsTask = nil
        controller?.setDelegate(delegate: nil)
        controller = nil
    }

    private func attach(_ controller: SessionVerificationController) {
        guard self.controller == nil else { return }
        self.controller = controller
        // Through a stream, so the callbacks, which come on the SDK's threads, are handled here
        // in the order they came.
        let (events, continuation) = AsyncStream.makeStream(of: Event.self)
        controller.setDelegate(delegate: ControllerDelegate(continuation))
        eventsTask = Task { [weak self] in
            for await event in events { self?.handle(event) }
        }
    }

    private func ensureController() async throws -> SessionVerificationController {
        if let controller { return controller }
        let controller = try await client.getSessionVerificationController()
        attach(controller)
        return self.controller ?? controller
    }

    // MARK: What the person does

    /// Asks the account's other devices to verify this Mac.
    func verifyThisMac() {
        begin(.requesting, subject: .thisMac, request: nil)
        Task {
            do {
                try await ensureController().requestDeviceVerification()
            } catch {
                if step == .requesting { step = .ended(.failed(Self.failureMessage(error))) }
            }
        }
    }

    /// Asks someone else to verify with this account. The request goes to them in a direct
    /// chat (made if there isn't one); once they accept, both see the same emoji.
    func verifyPerson(_ userID: String, name: String?) {
        begin(.requesting, subject: .person(id: userID, name: name), request: nil)
        Task { [client] in
            do {
                // This Mac may not have looked them up yet (in a room that has only just been
                // encrypted, say): the SDK asks only what it knows.
                let identity = (try? await client.encryption().userIdentity(userId: userID, fallbackToServer: true)) ?? nil
                guard identity != nil else {
                    if step == .requesting {
                        step = .ended(.failed("\(name ?? userID) can’t be verified yet: their app hasn’t set up the keys verifying needs."))
                    }
                    return
                }
                try await ensureController().requestUserVerification(userId: userID)
            } catch {
                guard step == .requesting else { return }
                let who = name ?? userID
                if let error = error as? ClientError, case .Generic(let message, _) = error {
                    if message.contains("Unknown user identity") {
                        step = .ended(.failed("\(who) can’t be verified yet: their app hasn’t set up the keys verifying needs."))
                        return
                    }
                    if message.contains("already verified") {
                        step = .verified
                        return
                    }
                }
                step = .ended(.failed(Self.failureMessage(error)))
            }
        }
    }

    /// Starts again what this Mac asked for and didn't get.
    func retry() {
        switch subject {
        case .thisMac: verifyThisMac()
        case .person(let id, let name): verifyPerson(id, name: name)
        case .device: break
        }
    }

    /// Accepts the request that came in; whoever sent it, or this Mac if they don't, then starts
    /// the emoji exchange.
    func accept() {
        guard step == .incoming, let controller else { return }
        step = .starting
        Task {
            do {
                try await controller.acceptVerificationRequest()
            } catch {
                if step == .starting { step = .ended(.failed(Self.failureMessage(error))) }
                return
            }
            // The side that asked usually starts the exchange as soon as the request is
            // accepted. If it hasn't after a moment, start it from here.
            startTask?.cancel()
            startTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, step == .starting, !sasStarted else { return }
                try? await controller.startSasVerification()
            }
        }
    }

    /// The emoji match on this side.
    func confirm() {
        guard case .comparing(let code) = step, let controller else { return }
        step = .confirming(code)
        Task {
            do {
                try await controller.approveVerification()
            } catch {
                if case .confirming = step { step = .ended(.failed(Self.failureMessage(error))) }
            }
        }
    }

    /// They don't: nothing is verified, and the other side is told why.
    func reject() {
        guard case .comparing = step, let controller else { return }
        step = .ended(.mismatch)
        Task { try? await controller.declineVerification() }
    }

    /// Stops what is under way, telling the other side; afterwards, back to the start.
    func cancel() {
        let wasActive = step.isActive
        step = .idle
        request = nil
        startTask?.cancel()
        guard wasActive, let controller else { return }
        Task { try? await controller.cancelVerification() }
    }

    /// A window showing the flow opened or closed. When the last one closes, whatever is under
    /// way stops, and a finished flow is cleared away.
    func windowOpened() { shownCount += 1 }

    func windowClosed() {
        shownCount = max(shownCount - 1, 0)
        if shownCount == 0 { cancel() }
    }

    private func begin(_ step: Step, subject: Subject, request: Request?) {
        startTask?.cancel()
        sasStarted = false
        self.subject = subject
        self.request = request
        self.step = step
    }

    // MARK: What the SDK says

    fileprivate enum Event: Sendable {
        case request(SessionVerificationRequestDetails)
        case accepted
        case started
        case code(Code)
        case failed
        case cancelled
        case finished
    }

    private func handle(_ event: Event) {
        switch event {
        case .request(let details):
            received(details)
        case .accepted:
            // The other side accepted this Mac's request: start the exchange.
            guard step == .requesting, let controller else { return }
            step = .starting
            Task {
                do {
                    try await controller.startSasVerification()
                } catch {
                    if step == .starting { step = .ended(.failed(Self.failureMessage(error))) }
                }
            }
        case .started:
            sasStarted = true
            startTask?.cancel()
            if step == .requesting || step == .incoming { step = .starting }
        case .code(let code):
            // The SDK can say so twice; the first stands.
            switch step {
            case .requesting, .incoming, .starting: step = .comparing(code)
            default: break
            }
        case .failed:
            guard step.isActive else { return }
            step = .ended(.failed("The devices couldn’t agree on how to verify. Try again."))
        case .cancelled:
            guard step.isActive else { return }
            let info = (sasStarted ? controller?.sasCancelInfo() : nil) ?? controller?.requestCancelInfo()
            switch info?.cancelCode {
            case "m.user" where info?.cancelledByUs == true:
                step = .idle
            case "m.mismatched_sas", "m.key_mismatch", "m.mismatched_commitment":
                step = .ended(.mismatch)
            case "m.timeout":
                step = .ended(.timedOut)
            case "m.accepted":
                step = .ended(.answeredElsewhere)
            default:
                step = info?.cancelledByUs == true
                    ? .ended(.failed("Something went wrong on this Mac. Try again."))
                    : .ended(.cancelledThere)
            }
        case .finished:
            guard step.isActive else { return }
            step = .verified
            if case .person(let id, _) = subject { onVerifiedPerson(id) }
        }
    }

    private func received(_ details: SessionVerificationRequestDetails) {
        // One at a time: a request while another is under way goes unanswered.
        guard !step.isActive, let controller else { return }
        let senderID = details.senderProfile.userId
        let request = Request(flowID: details.flowId,
                              senderID: senderID,
                              senderName: ShownName.clean(details.senderProfile.displayName),
                              senderAvatarURL: details.senderProfile.avatarUrl,
                              deviceID: details.deviceId,
                              deviceName: ShownName.clean(details.deviceDisplayName),
                              firstSeen: details.firstSeenTimestamp > 0
                                ? Date(timeIntervalSince1970: TimeInterval(details.firstSeenTimestamp) / 1000) : nil)
        let subject: Subject = senderID != userID ? .person(id: senderID, name: request.senderName)
            : isThisMacVerified() ? .device(name: request.deviceName, id: request.deviceID) : .thisMac
        begin(.incoming, subject: subject, request: request)
        Task {
            // Made the current flow straight away, so if the other side gives up first it shows.
            do {
                try await controller.acknowledgeVerificationRequest(senderId: senderID, flowId: details.flowId)
            } catch {
                if step == .incoming, self.request == request { step = .idle; self.request = nil }
                return
            }
            onIncoming()
        }
    }

    private static func failureMessage(_ error: Error) -> String {
        if let error = error as? ClientError, case .Generic(let message, _) = error,
           message.contains("another verification flow ongoing") {
            return "Another verification is still under way. Wait a moment and try again."
        }
        return error.actionMessage
    }
}

/// Passes the controller's callbacks, which come on the SDK's threads, to the flow.
private final class ControllerDelegate: SessionVerificationControllerDelegate, @unchecked Sendable {
    private let continuation: AsyncStream<VerificationFlow.Event>.Continuation

    init(_ continuation: AsyncStream<VerificationFlow.Event>.Continuation) {
        self.continuation = continuation
    }

    deinit { continuation.finish() }

    func didReceiveVerificationRequest(details: SessionVerificationRequestDetails) {
        continuation.yield(.request(details))
    }

    func didAcceptVerificationRequest() { continuation.yield(.accepted) }
    func didStartSasVerification() { continuation.yield(.started) }

    func didReceiveVerificationData(data: SessionVerificationData) {
        switch data {
        case .emojis(let emojis, _):
            continuation.yield(.code(.emoji(emojis.map { .init(symbol: $0.symbol(), name: $0.description()) })))
        case .decimals(let values):
            continuation.yield(.code(.numbers(values)))
        }
    }

    func didFail() { continuation.yield(.failed) }
    func didCancel() { continuation.yield(.cancelled) }
    func didFinish() { continuation.yield(.finished) }
}
