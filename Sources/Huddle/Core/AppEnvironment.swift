import Foundation

/// Separates the release app from "Huddle Dev" (bundle ID ending in ".dev"),
/// so test accounts and real accounts never share data or Keychain items.
enum AppEnvironment {
    /// True for the Dev bundle and for unbundled runs (`swift run`).
    static let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? true
    /// Folder name under Application Support and Caches.
    static let dataFolder = isDev ? "Huddle Dev" : "Huddle"
    static let keychainService = isDev ? "app.huddle.sessions.dev" : "app.huddle.sessions"
}
