import Foundation
import Sparkle

/// Huddle's updates, through Sparkle: checking (from the app menu or Settings, and once a day by
/// itself unless turned off), then showing what's new, downloading, checking the archive's
/// signature against the key in Info.plist, installing and relaunching. The release workflow
/// publishes each release with the appcast that lists them (see README, Releases).
///
/// The Dev build never updates itself from releases, which would replace it with the release
/// app: it looks for updates only when HUDDLE_DEV_UPDATE_FEED names a test feed.
@MainActor @Observable
final class AppUpdater: NSObject {
    static let shared = AppUpdater()

    /// False in the Dev build without a test feed.
    let isAvailable: Bool
    /// False while a check or an update is under way.
    private(set) var canCheck = false
    private(set) var lastChecked: Date?

    var checksAutomatically = false {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }

    /// Downloads updates as they're found and installs them when Huddle quits, without asking.
    var installsAutomatically = false {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != installsAutomatically else { return }
            updater.automaticallyDownloadsUpdates = installsAutomatically
        }
    }

    /// Offers pre-releases too: those the appcast puts in the "beta" channel.
    var includesBetas = UserDefaults.standard.bool(forKey: AppUpdater.betaKey) {
        didSet { UserDefaults.standard.set(includesBetas, forKey: Self.betaKey) }
    }

    nonisolated static let betaKey = "updatesIncludeBetas"

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private var updater: SPUUpdater? { controller?.updater }

    override private init() {
        isAvailable = !AppEnvironment.isDev || DevHooks.updateFeed != nil
        super.init()
        guard isAvailable else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                      userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        checksAutomatically = updater.automaticallyChecksForUpdates
        installsAutomatically = updater.automaticallyDownloadsUpdates
        lastChecked = updater.lastUpdateCheckDate
        // Sparkle changes it on the main thread.
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    /// Looks for an update now, showing what it finds (or that Huddle is up to date).
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// "0.2.0 (45)": the version, and the build number updates are compared by.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info?["CFBundleVersion"] as? String else { return version }
        return "\(version) (\(build))"
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: Self.betaKey) ? ["beta"] : []
    }

    /// The Dev build's test feed; the release app's is SUFeedURL in Info.plist.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        DevHooks.updateFeed
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: (any Error)?) {
        // Sparkle calls its delegate on the main thread.
        MainActor.assumeIsolated { lastChecked = updater.lastUpdateCheckDate }
    }
}
