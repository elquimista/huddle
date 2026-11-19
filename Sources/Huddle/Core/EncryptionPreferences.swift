import AppKit
import Foundation
import MatrixRustSDK

/// How strictly encrypted messages treat devices their owners haven't verified (Element's
/// "exclude insecure devices", after MSC4153). Off by default, as in Element: on, people whose
/// apps don't cross-sign their devices can't read what this account sends.
enum EncryptionPreferences {
    static let excludesInsecureDevicesKey = "excludeInsecureDevices"

    static var excludesInsecureDevices: Bool {
        UserDefaults.standard.bool(forKey: excludesInsecureDevicesKey)
    }

    /// As it was when Huddle opened: the SDK takes it when an account's client is built, so a
    /// change reaches the accounts already signed in at the next launch.
    static let excludedInsecureDevicesAtLaunch = excludesInsecureDevices

    /// Who new message keys go to: every device, or only those signed by their owner.
    static var keyRecipients: CollectStrategy {
        excludesInsecureDevices ? .identityBasedStrategy : .allDevices
    }

    /// Whose messages are decrypted: anyone's, or only those sent from devices signed by their
    /// owner (and sessions from before cross-signing existed).
    static var decryption: DecryptionSettings {
        DecryptionSettings(senderDeviceTrustRequirement: excludesInsecureDevices ? .crossSignedOrLegacy : .untrusted)
    }
}

/// Quits and opens Huddle again, for a setting that applies at launch. The new copy waits for
/// this one to have gone, so the two never share the accounts' stores.
@MainActor
enum AppRelauncher {
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try task.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
