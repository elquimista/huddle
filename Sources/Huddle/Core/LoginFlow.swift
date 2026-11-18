import AppKit
import Foundation
import MatrixRustSDK
import Network
import Observation

/// Drives adding an account: server discovery, then password login in the app where the
/// homeserver accepts it, with OAuth in the browser as the alternative (or the only way).
@MainActor @Observable
final class LoginFlow {
    enum Step: Equatable {
        case server
        case password
        case waitingForBrowser
    }

    var server = "matrix.org"
    var username = ""
    var password = ""
    private(set) var step: Step = .server
    private(set) var isBusy = false
    private(set) var error: String?
    private(set) var homeserverURL = ""
    /// The homeserver accepts a username and password directly.
    private(set) var supportsPassword = false
    /// The homeserver offers OAuth sign-in in the browser.
    private(set) var supportsBrowser = false

    @ObservationIgnored private var client: Client?
    @ObservationIgnored private var storeID = UUID().uuidString
    @ObservationIgnored private var passphrase = makeStorePassphrase()
    @ObservationIgnored private var loopback: LoopbackServer?
    @ObservationIgnored private var oauthTask: Task<Void, Never>?

    private static let deviceName = "Huddle (macOS)"

    /// Discovers the homeserver and picks the login method it supports.
    func continueWithServer(store: AccountStore) async {
        await perform {
            self.discardClient()
            let client = try await ClientFactory.makeClient(
                storeID: self.storeID,
                passphrase: self.passphrase,
                server: .discover(self.server.trimmingCharacters(in: .whitespaces)))
            self.client = client
            let details = await client.homeserverLoginDetails()
            self.homeserverURL = details.url()
            guard details.slidingSyncVersion() == .native else { throw LoginError.slidingSyncUnsupported }

            self.supportsPassword = details.supportsPasswordLogin()
            self.supportsBrowser = details.supportsOauthLogin()

            if self.supportsPassword {
                self.step = .password
            } else if self.supportsBrowser {
                try await self.startOAuth(client: client, store: store)
            } else {
                throw LoginError.noSupportedLoginMethod
            }
        }
    }

    func logInWithPassword(store: AccountStore) async {
        guard let client else { return }
        await perform {
            try await client.login(username: self.username,
                                   password: self.password,
                                   initialDeviceName: Self.deviceName,
                                   deviceId: nil)
            try self.finish(client: client, store: store)
        }
    }

    /// Switches from the password form to OAuth in the browser.
    func continueInBrowser(store: AccountStore) async {
        guard let client, supportsBrowser else { return }
        await perform {
            try await self.startOAuth(client: client, store: store)
        }
    }

    /// Leaves the browser step: back to the password form if there is one, else to the server step.
    func leaveBrowser() {
        guard supportsPassword, client != nil else {
            cancel()
            return
        }
        // Ending the loopback listener also aborts the pending authorization.
        loopback?.stop()
        step = .password
        error = nil
    }

    private func startOAuth(client: Client, store: AccountStore) async throws {
        let loopback = try LoopbackServer()
        self.loopback = loopback
        let port = try await loopback.start()
        let configuration = OAuthConfiguration(clientName: "Huddle",
                                               redirectUri: "http://127.0.0.1:\(port)/",
                                               clientUri: AppInfo.clientURI,
                                               logoUri: nil,
                                               tosUri: nil,
                                               policyUri: nil,
                                               staticRegistrations: [:])
        let data = try await client.urlForOauth(oauthConfiguration: configuration,
                                                prompt: nil,
                                                loginHint: nil,
                                                deviceId: nil,
                                                additionalScopes: nil)
        // A web page, from the server the user typed: not any other kind of link it may give.
        guard let url = URL(string: data.loginUrl()), LinkPolicy.isSafeServerPage(url) else {
            throw LoginError.noSupportedLoginMethod
        }
        if AppEnvironment.isDev, ProcessInfo.processInfo.environment["HUDDLE_DEV_NO_BROWSER"] != nil {
            // Dev testing: print the sign-in URL instead of taking over the default browser.
            print("DEV_OAUTH_URL \(url.absoluteString)")
            fflush(stdout)
        } else {
            NSWorkspace.shared.open(url)
        }
        step = .waitingForBrowser

        oauthTask = Task {
            guard let callback = await loopback.callback() else {
                await client.abortOauthAuth(authorizationData: data)
                return
            }
            await self.perform {
                defer { loopback.stop() }
                do {
                    try await client.loginWithOauthCallback(callbackUrl: callback)
                } catch {
                    self.step = self.supportsPassword ? .password : .server
                    throw error
                }
                try self.finish(client: client, store: store)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private func finish(client: Client, store: AccountStore) throws {
        let userID = try client.userId()
        if store.isLoggedIn(userID: userID) {
            Task { try? await client.logout() }
            discardClient()
            step = .server
            throw LoginError.alreadyLoggedIn(userID)
        }
        try store.add(client: client, storeID: storeID, passphrase: passphrase)
        self.client = nil
        store.isAddingAccount = false
    }

    /// Returns to the server step, dropping any half-finished attempt.
    func cancel() {
        loopback?.stop()
        oauthTask?.cancel()
        discardClient()
        step = .server
        error = nil
    }

    private func discardClient() {
        guard client != nil else { return }
        client = nil
        StorePaths(storeID: storeID).delete()
        storeID = UUID().uuidString
        passphrase = makeStorePassphrase()
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        isBusy = true
        error = nil
        defer { isBusy = false }
        do {
            try await work()
        } catch {
            self.error = error.userMessage
        }
    }
}

enum AppInfo {
    /// Sent to homeservers when registering Huddle as an OAuth client.
    /// Replace with your project's website before distributing the app.
    static let clientURI = "https://huddle.invalid"
}

/// One-shot localhost HTTP listener that receives the OAuth redirect.
final class LoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.huddle.loopback")
    private let callbacks: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        (callbacks, continuation) = AsyncStream.makeStream(of: String.self)
    }

    /// Starts listening and returns the chosen port.
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        return try await withCheckedThrowingContinuation { ready in
            nonisolated(unsafe) var resumed = false  // only touched on the listener queue
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    self.port = self.listener.port?.rawValue ?? 0
                    ready.resume(returning: self.port)
                case .failed(let error):
                    resumed = true
                    ready.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// The full redirect URL, or nil if the server was stopped first.
    func callback() async -> String? {
        for await url in callbacks { return url }
        return nil
    }

    func stop() {
        listener.cancel()
        continuation.finish()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self,
                  let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n").first else {
                connection.cancel()
                return
            }
            let parts = line.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : "/"
            let isCallback = path.contains("code=") || path.contains("error=")
            let body = isCallback
                ? "<html><body style='font:16px -apple-system;text-align:center;margin-top:20vh'><h2>Signed in</h2><p>You can close this tab and return to Huddle.</p></body></html>"
                : ""
            let status = isCallback ? "200 OK" : "404 Not Found"
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if isCallback {
                self.continuation.yield("http://127.0.0.1:\(self.port)\(path)")
            }
        }
    }
}
