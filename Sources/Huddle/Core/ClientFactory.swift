import Foundation
import MatrixRustSDK

enum ClientFactory {
    enum Server {
        /// A server name or URL typed by the user; sliding sync support is discovered.
        case discover(String)
        /// A known homeserver from a stored session.
        case known(url: String, nativeSlidingSync: Bool)
    }

    private static let platformSetup: Void = {
        let config = TracingConfiguration(logLevel: .warn,
                                          traceLogPacks: [],
                                          extraTargets: [],
                                          writeToStdoutOrSystem: true,
                                          writeToFiles: nil,
                                          sentryConfig: nil)
        try? initPlatform(config: config, useLightweightTokioRuntime: false)
    }()

    static func makeClient(storeID: String, passphrase: String, server: Server) async throws -> Client {
        _ = platformSetup
        let paths = StorePaths(storeID: storeID)
        try paths.create()

        let store = SqliteStoreBuilder(dataPath: paths.data.path, cachePath: paths.cache.path)
            .passphrase(passphrase: passphrase)

        var builder = ClientBuilder()
            .sqliteStore(config: store)
            .setSessionDelegate(sessionDelegate: SessionVault.shared)
            .userAgent(userAgent: "Huddle/0.1 (macOS)")
            .autoEnableCrossSigning(autoEnableCrossSigning: true)
            .autoEnableBackups(autoEnableBackups: true)
            .backupDownloadStrategy(backupDownloadStrategy: .afterDecryptionFailure)
            // The SDK's own thread mode stays off: with it on, thread replies never count toward
            // a room's unread badge. Huddle instead hides replies from the room timeline and
            // opens thread-focused timelines itself (see RoomTimeline).
            .threadsEnabled(enabled: false, threadSubscriptions: false)

        switch server {
        case .discover(let input):
            builder = builder
                .serverNameOrHomeserverUrl(serverNameOrUrl: input)
                .slidingSyncVersionBuilder(versionBuilder: .discoverNative)
        case .known(let url, let nativeSlidingSync):
            builder = builder
                .homeserverUrl(url: url)
                .slidingSyncVersionBuilder(versionBuilder: nativeSlidingSync ? .native : .none)
        }
        return try await builder.build()
    }
}

/// On-disk locations of one account's SDK stores.
struct StorePaths {
    let data: URL
    let cache: URL

    init(storeID: String) {
        let fm = FileManager.default
        data = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppEnvironment.dataFolder)/\(storeID)", isDirectory: true)
        cache = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(AppEnvironment.dataFolder)/\(storeID)", isDirectory: true)
    }

    func create() throws {
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    func delete() {
        try? FileManager.default.removeItem(at: data)
        try? FileManager.default.removeItem(at: cache)
    }
}

/// Random passphrase for a new account's encrypted store.
func makeStorePassphrase() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    return Data(bytes).base64EncodedString()
}
