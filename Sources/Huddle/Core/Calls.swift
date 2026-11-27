import AppKit
import MatrixRustSDK
import Observation
import WebKit

/// Element Call, the call screen: a web app bundled in Huddle (Scripts/fetch-element-call.sh),
/// run in a web view as Element X runs it. The SDK's widget driver does the Matrix side: the
/// call's membership in the room, its keys and the ring that goes out to the other person.
enum ElementCallApp {
    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ElementCall")
    }

    /// Whether a URL is Element Call's page itself, as bundled, whatever its query and fragment.
    static func isPage(_ url: URL?) -> Bool {
        guard let url, url.isFileURL, let index = indexURL else { return false }
        return url.standardizedFileURL.path == index.standardizedFileURL.path
    }

    /// Whether a URL is one of Element Call's own files, in the app.
    static func isOwnFile(_ url: URL) -> Bool {
        guard url.isFileURL, let folder = indexURL?.deletingLastPathComponent().standardizedFileURL.path else { return false }
        return url.standardizedFileURL.path.hasPrefix(folder + "/")
    }
}

/// One call: Element Call in a web view, joined to a room.
@MainActor @Observable
final class CallSession {
    let account: AccountSession
    let roomID: String
    let title: String
    /// A voice call: no camera.
    let isVoiceOnly: Bool
    let widgetID = UUID().uuidString

    /// The page to load, once the widget is set up.
    private(set) var url: URL?
    /// Element Call's page, kept out of sight in Huddle's window (`CallPages`): Huddle shows the
    /// call itself, in the room list.
    private(set) var page: WKWebView?
    private(set) var failure: String?
    /// Element Call has said it has loaded and is talking to the room.
    private(set) var hasLoaded = false
    /// When this device joined the call.
    private(set) var joined: Date?
    /// The microphone is off, here or from Element Call itself.
    private(set) var isMuted = false

    /// Called once the call is over (left from Element Call's own button, hung up, or failed to
    /// start).
    @ObservationIgnored var onEnded: (() -> Void)?
    @ObservationIgnored private var driver: WidgetDriverAndHandle?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private weak var webView: WKWebView?
    /// Messages for the page that came before it could take them.
    @ObservationIgnored private var pending: [String] = []
    @ObservationIgnored private var pageIsReady = false
    @ObservationIgnored private var hasEnded = false

    init(account: AccountSession, roomID: String, title: String, isVoiceOnly: Bool) {
        self.account = account
        self.roomID = roomID
        self.title = title
        self.isVoiceOnly = isVoiceOnly
    }

    /// Sets up the widget and its driver, and loads Element Call's page.
    func start() async {
        guard let room = account.room(id: roomID) else { return fail("The room isn’t available.") }
        guard let base = ElementCallApp.indexURL else { return fail("This copy of Huddle is missing its call screen.") }
        // Element Call would only say it can't connect, out of sight; this says why.
        if (try? await account.client.isLivekitRtcSupported()) == false {
            return fail("Your server doesn’t support Element Call, which calls in rooms need.")
        }
        // Element Call joins by posting this account's call membership; without the right, the
        // call would drop as soon as it began.
        if let levels = try? await room.getPowerLevels(), !levels.canOwnUserSendState(stateEvent: .callMember) {
            return fail("This room’s settings don’t let you take part in calls. Its admins can change that.")
        }
        let isEncrypted = (try? await room.latestEncryptionState()) == .encrypted
        let intent = await Self.intent(for: room, voiceOnly: isVoiceOnly)
        do {
            let settings = try newVirtualElementCallWidget(
                props: VirtualElementCallWidgetProperties(
                    elementCallUrl: base.absoluteString, widgetId: widgetID, parentUrl: nil,
                    fontScale: nil, font: nil, encryption: isEncrypted ? .perParticipantKeys : .unencrypted,
                    posthogUserId: nil, posthogApiHost: nil, posthogApiKey: nil,
                    rageshakeSubmitUrl: nil, sentryDsn: nil, sentryEnvironment: nil),
                config: VirtualElementCallWidgetConfig(intent: intent))
            let isDark = NSApp.effectiveAppearance.isDark
            let props = ClientProperties(clientId: Bundle.main.bundleIdentifier ?? "app.huddle.Huddle",
                                         languageTag: Locale.current.identifier(.bcp47),
                                         theme: isDark ? "dark" : "light")
            let address = try await generateWebviewUrl(widgetSettings: settings, room: room, props: props)
            guard let url = URL(string: address) else { return fail("The call screen couldn’t be set up.") }
            let driver = try makeWidgetDriver(settings: settings)
            self.driver = driver
            run(driver, in: room)
            self.url = url
            page = makeWebView()
            // Element Call shows what went wrong on its own screen, which isn't shown: given time
            // to join, a call that hasn't is taken as failed.
            tasks.append(Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, self.joined == nil, !self.hasEnded else { return }
                self.fail("The call couldn’t be joined.")
                self.webView?.loadHTMLString("", baseURL: nil)
            })
        } catch {
            fail(error.actionMessage)
        }
    }

    /// Element Call's intent: start or join, a direct chat's (ringing the other person) or a
    /// room's, voice only where it can be.
    private static func intent(for room: Room, voiceOnly: Bool) async -> Intent {
        let isDirect = await room.isDirect()
        let hasCall = room.hasActiveRoomCall()
        if isDirect {
            if hasCall { return voiceOnly ? .joinExistingDmVoice : .joinExistingDm }
            return voiceOnly ? .startCallDmVoice : .startCallDm
        }
        return hasCall ? .joinExisting : .startCall
    }

    private func run(_ driver: WidgetDriverAndHandle, in room: Room) {
        let provider = CallCapabilities(userID: account.userID, deviceID: account.currentDeviceID ?? "")
        let widget = driver.driver
        tasks.append(Task.detached {
            await widget.run(room: room, capabilitiesProvider: provider)
        })
        let handle = driver.handle
        tasks.append(Task { [weak self] in
            while let message = await handle.recv() {
                guard let self, !Task.isCancelled else { return }
                self.toPage(message)
            }
        })
    }

    // MARK: The page

    /// The web view for the call, set up to talk to the driver.
    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Out of sight, it goes on at full speed all the same.
        configuration.preferences.inactiveSchedulingPolicy = .none
        let content = configuration.userContentController
        let bridge = CallBridge(session: self)
        content.add(bridge, name: CallBridge.name)
        content.addUserScript(WKUserScript(source: CallBridge.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if DevHooks.mutesAudio {
            content.addUserScript(WKUserScript(source: CallBridge.muteScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if AppEnvironment.isDev {
            // Element Call's console, in the Dev log.
            content.add(bridge, name: CallBridge.logName)
            content.addUserScript(WKUserScript(source: CallBridge.logScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = bridge
        webView.uiDelegate = bridge
        if AppEnvironment.isDev { webView.isInspectable = true }
        bridge.webView = webView
        self.webView = webView
        if let url, let folder = ElementCallApp.indexURL?.deletingLastPathComponent() {
            webView.loadFileURL(url, allowingReadAccessTo: folder)
        }
        return webView
    }

    fileprivate func pageDidLoad() {
        pageIsReady = true
        let queued = pending
        pending = []
        for message in queued { toPage(message) }
    }

    /// A message from the driver for Element Call.
    private func toPage(_ message: String) {
        guard pageIsReady, let webView else {
            pending.append(message)
            return
        }
        // The driver's messages are JSON, which is JavaScript as it stands.
        webView.evaluateJavaScript("postMessage(\(message), '*')")
    }

    /// Element Call's requests that are for the app embedding it rather than for the room: the
    /// driver doesn't know them, and would answer with an error. They're answered here.
    private static let appActions: Set<String> = [
        "io.element.join", "io.element.device_mute", "set_always_on_screen", "io.element.close",
    ]

    /// A message from Element Call: for the driver, or for the app.
    fileprivate func fromPage(_ message: String) {
        let object = message.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        // Its answer to Huddle's own request (muting, hanging up), which the driver didn't make.
        if let object, object["api"] as? String == "toWidget",
           (object["requestId"] as? String)?.hasPrefix(Self.requestPrefix) == true {
            if object["action"] as? String == "io.element.device_mute",
               let enabled = (object["response"] as? [String: Any])?["audio_enabled"] as? Bool {
                isMuted = !enabled
            }
            return
        }
        guard let object, object["api"] as? String == "fromWidget", object["response"] == nil,
              let action = object["action"] as? String else {
            _ = driver?.handle.send(msg: message)
            return
        }
        guard Self.appActions.contains(action) else {
            _ = driver?.handle.send(msg: message)
            if action == "content_loaded" { hasLoaded = true }
            return
        }
        answer(object)
        switch action {
        case "io.element.join":
            hasLoaded = true
            if joined == nil { joined = .now }
        case "io.element.device_mute":
            // Element Call's microphone, as it stands.
            if let enabled = (object["data"] as? [String: Any])?["audio_enabled"] as? Bool { isMuted = !enabled }
        case "io.element.close":
            // Left from Element Call's own button, or after hanging up.
            end()
        default:
            break
        }
    }

    /// Tells Element Call its request was taken: the request itself, with an empty response.
    private func answer(_ request: [String: Any]) {
        var reply = request
        reply["response"] = [String: Any]()
        guard let data = try? JSONSerialization.data(withJSONObject: reply),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("postMessage(\(json), '*')")
    }

    /// Huddle's own requests to Element Call, told apart from the driver's by this.
    private static let requestPrefix = "huddle-"

    private func request(_ action: String, data: [String: Any] = [:]) {
        let request: [String: Any] = [
            "api": "toWidget", "widgetId": widgetID,
            "requestId": "\(Self.requestPrefix)\(UUID().uuidString)",
            "action": action, "data": data,
        ]
        guard let webView, let json = try? JSONSerialization.data(withJSONObject: request),
              let text = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("postMessage(\(text), '*')")
    }

    var canMute: Bool { joined != nil && !hasEnded && failure == nil }

    /// Turns the microphone off or on, in Element Call; it says back how it stands.
    func toggleMute() {
        guard canMute else { return }
        isMuted.toggle()
        request("io.element.device_mute", data: ["audio_enabled": !isMuted])
    }

    // MARK: Ending

    /// Leaves the call: Element Call hangs up, which takes this device out of it in the room, and
    /// then says it's done. If it doesn't within a few seconds, the call is ended here anyway.
    func hangUp() {
        guard !hasEnded else { return }
        guard hasLoaded, webView != nil, failure == nil else { return end() }
        request("im.vector.hangup")
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.end()
        }
    }

    private func end() {
        guard !hasEnded else { return }
        hasEnded = true
        for task in tasks { task.cancel() }
        tasks = []
        driver = nil
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        page = nil
        onEnded?()
    }

    private func fail(_ message: String) {
        failure = message
    }
}

extension CallSession: HuddleCall {}

/// What Element Call may do in the room: what it needs, as the SDK knows it.
private final class CallCapabilities: WidgetCapabilitiesProvider, @unchecked Sendable {
    private let userID: String
    private let deviceID: String

    init(userID: String, deviceID: String) {
        self.userID = userID
        self.deviceID = deviceID
    }

    func acquireCapabilities(capabilities: WidgetCapabilities) async -> WidgetCapabilities {
        getElementCallRequiredPermissions(ownUserId: userID, ownDeviceId: deviceID)
    }
}

/// Between the web view and the session: Element Call's messages out of the page, its loading,
/// the microphone, and links it opens.
private final class CallBridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    static let name = "elementCall"

    /// Element Call talks to the app it's embedded in with `postMessage` to itself. Its requests,
    /// and its answers to the driver's, go out to the app; the driver's own, posted back into
    /// the page, are left alone.
    static let script = """
    window.addEventListener("message", (event) => {
        const data = event.data;
        if (!data || typeof data !== "object") return;
        if ((data.api === "fromWidget" && !data.response) || (data.api === "toWidget" && data.response)) {
            window.webkit.messageHandlers.\(name).postMessage(JSON.stringify(data));
        }
    }, false);
    """

    /// Dev: the call's sound stays silent (HUDDLE_DEV_MUTE_AUDIO), as the other test audio does.
    static let muteScript = """
    (() => {
        const mute = (element) => { element.muted = true; element.volume = 0; };
        document.addEventListener("play", (event) => mute(event.target), true);
        new MutationObserver(() => document.querySelectorAll("audio, video").forEach(mute))
            .observe(document, { childList: true, subtree: true });
    })();
    """

    static let logName = "elementCallLog"

    /// Dev: Element Call's console messages, sent out to the log.
    static let logScript = """
    (() => {
        for (const level of ["log", "info", "warn", "error", "debug"]) {
            const original = console[level];
            console[level] = (...args) => {
                try {
                    const text = args.map((a) => typeof a === "string" ? a : (a instanceof Error ? a.name + ": " + a.message + " | " + (a.cause ? String(a.cause) : "") + " | " + a.stack : JSON.stringify(a))).join(" ");
                    window.webkit.messageHandlers.\(logName).postMessage(level + ": " + text.slice(0, 2000));
                } catch (e) {}
                original.apply(console, args);
            };
        }
        window.addEventListener("error", (e) => window.webkit.messageHandlers.\(logName).postMessage("uncaught: " + e.message));
        window.addEventListener("unhandledrejection", (e) => window.webkit.messageHandlers.\(logName).postMessage("unhandled: " + String(e.reason)));
        // What the page's content security policy stopped (Scripts/element-call-csp.py).
        document.addEventListener("securitypolicyviolation", (e) => window.webkit.messageHandlers.\(logName).postMessage("csp: " + e.effectiveDirective + " blocked " + e.blockedURI));
    })();
    """

    private weak var session: CallSession?
    weak var webView: WKWebView?

    @MainActor init(session: CallSession) {
        self.session = session
    }

    /// Only from Element Call's own page, in the web view's main frame. The handler is there
    /// for every frame of whatever the web view shows; the bridge sends what it's given into the
    /// room, as this account.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let text = message.body as? String, message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.protocol == "file",
              ElementCallApp.isPage(message.frameInfo.request.url) else { return }
        if message.name == Self.logName {
            print("ELEMENTCALL", text)
            fflush(stdout)
            return
        }
        MainActor.assumeIsolated { session?.fromPage(text) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { session?.pageDidLoad() }
    }

    /// Only the call screen itself loads here: its page, or the blank one a call is cleared to.
    /// Nothing loads into frames (Element Call makes none but blank ones of its own); other
    /// files, and pages made in the page itself (data: and blob:), don't load at all. A link it
    /// opens goes to the browser.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        let isBlank = url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
        if let frame = action.targetFrame, !frame.isMainFrame {
            return decisionHandler(isBlank ? .allow : .cancel)
        }
        if ElementCallApp.isOwnFile(url) || (isBlank && action.targetFrame != nil) {
            return decisionHandler(.allow)
        }
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    /// The microphone, for the call screen only. Not the camera: these are voice calls.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let allowed = origin.protocol == "file" && type == .microphone && !DevHooks.deniesMicrophone
        decisionHandler(allowed ? .grant : .deny)
    }
}
