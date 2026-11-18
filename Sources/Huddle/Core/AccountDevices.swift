import Foundation
import MatrixRustSDK

/// One of the devices (sessions) signed in to an account, as the server lists them.
struct AccountDevice: Identifiable, Equatable {
    enum Trust: Equatable {
        /// Signed by the account's self-signing key: verified from one of its trusted devices.
        case verified
        case unverified
        /// It never set up encryption, so it can't read encrypted messages.
        case noEncryption
        /// The account has no cross-signing set up to tell.
        case unknown
    }

    let id: String
    var name: String?
    let lastSeen: Date?
    let lastSeenIP: String?
    var trust: Trust

    /// Not seen for 90 days, as Element marks them: likely forgotten.
    var isInactive: Bool {
        lastSeen.map { $0.timeIntervalSinceNow < -90 * 24 * 3600 } ?? false
    }
}

/// Seeing and managing the devices signed in to this account: the server's own API, as the SDK
/// doesn't cover it.
extension AccountSession {
    /// This Mac's device ID for the account.
    var currentDeviceID: String? { try? client.deviceId() }

    /// Every device signed in to the account, with whether each is verified, read from the
    /// server's device list and its record of their encryption keys and signatures.
    func devices() async throws -> [AccountDevice] {
        let (status, json) = try await clientAPI("GET", "devices")
        guard status == 200 else { throw ClientAPIError.refused(status: status, message: json["error"] as? String) }
        var devices = (json["devices"] as? [[String: Any]] ?? []).compactMap { entry -> AccountDevice? in
            guard let id = entry["device_id"] as? String else { return nil }
            let seen = (entry["last_seen_ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return AccountDevice(id: id, name: (entry["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                 lastSeen: seen, lastSeenIP: entry["last_seen_ip"] as? String, trust: .unknown)
        }
        // Verified: the device's keys carry a signature by the account's self-signing key.
        if let (keysStatus, keys) = try? await clientAPI("POST", "keys/query", body: ["device_keys": [userID: [String]()]]),
           keysStatus == 200 {
            let deviceKeys = (keys["device_keys"] as? [String: Any])?[userID] as? [String: Any] ?? [:]
            let selfSigning = ((keys["self_signing_keys"] as? [String: Any])?[userID] as? [String: Any])?["keys"]
                as? [String: Any]
            let signingKeyIDs = Set(selfSigning?.keys.map { $0 } ?? [])
            for index in devices.indices {
                guard let entry = deviceKeys[devices[index].id] as? [String: Any] else {
                    devices[index].trust = .noEncryption
                    continue
                }
                guard !signingKeyIDs.isEmpty else { continue }
                let signatures = (entry["signatures"] as? [String: Any])?[userID] as? [String: Any] ?? [:]
                devices[index].trust = signingKeyIDs.isDisjoint(with: signatures.keys) ? .unverified : .verified
            }
        }
        return devices.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }

    func renameDevice(_ deviceID: String, to name: String) async throws {
        let (status, json) = try await clientAPI("PUT", "devices/\(Self.pathComponent(deviceID))",
                                                 body: ["display_name": name.trimmingCharacters(in: .whitespacesAndNewlines)])
        guard status == 200 else { throw ClientAPIError.refused(status: status, message: json["error"] as? String) }
    }

    /// Signs devices out, confirmed with the account's password: their sessions end, and with
    /// them their encryption keys.
    func signOut(devices deviceIDs: [String], password: String) async throws {
        try await clientAPI("POST", "delete_devices", body: ["devices": deviceIDs], password: password)
    }

    /// For an account whose server hands sign-in to its own service: the page there for one of
    /// its devices (or all of them), where it is signed out. Nil for a server that doesn't.
    func devicePageURL(for deviceID: String?) async -> URL? {
        let action: AccountManagementAction = deviceID.map { .deviceView(deviceId: $0) } ?? .devicesList
        if let address = try? await client.accountUrl(action: action), let url = URL(string: address) {
            return url
        }
        guard let base = await accountPageURL(), var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }
        var query = components.queryItems ?? []
        if let deviceID {
            query += [URLQueryItem(name: "action", value: "org.matrix.device_view"),
                      URLQueryItem(name: "device_id", value: deviceID)]
        } else {
            query.append(URLQueryItem(name: "action", value: "org.matrix.devices_list"))
        }
        components.queryItems = query
        return components.url
    }
}
