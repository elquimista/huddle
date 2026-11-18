import AppKit
import Foundation
import MatrixRustSDK

/// Changing this account's own name, picture and password.
extension AccountSession {
    /// What the server lets an account change about itself, from its capabilities. All of it
    /// unless the server says otherwise.
    struct ProfileCapabilities {
        var canSetName = true
        var canSetPicture = true
        var canChangePassword = true
    }

    /// Signed in through OAuth: the password, if any, belongs to the sign-in server, and is
    /// changed on its account page.
    var signsInWithOAuth: Bool {
        (try? client.session())?.oauthData != nil
    }

    func profileCapabilities() async -> ProfileCapabilities {
        var result = ProfileCapabilities()
        guard let (status, json) = try? await accountRequest("GET", "capabilities"), status == 200,
              let capabilities = json["capabilities"] as? [String: Any] else { return result }
        func enabled(_ key: String) -> Bool {
            (capabilities[key] as? [String: Any])?["enabled"] as? Bool ?? true
        }
        result.canChangePassword = enabled("m.change_password")
        result.canSetName = enabled("m.set_displayname")
        result.canSetPicture = enabled("m.set_avatar_url")
        // Newer servers say it per profile field.
        if let fields = capabilities["m.profile_fields"] as? [String: Any] {
            func allowed(_ field: String) -> Bool {
                if fields["enabled"] as? Bool == false { return false }
                if let allowed = fields["allowed"] as? [String] { return allowed.contains(field) }
                if let disallowed = fields["disallowed"] as? [String] { return !disallowed.contains(field) }
                return true
            }
            result.canSetName = result.canSetName && allowed("displayname")
            result.canSetPicture = result.canSetPicture && allowed("avatar_url")
        }
        return result
    }

    func setDisplayName(_ name: String) async throws {
        try await client.setDisplayName(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        await loadProfile()
    }

    func setPicture(_ image: AvatarImage) async throws {
        try await client.uploadAvatar(mimeType: image.mimeType, data: image.data)
        await loadProfile()
    }

    func removePicture() async throws {
        try await client.removeAvatar()
        await loadProfile()
    }

    /// The sign-in server's page for this account, where its password and the rest are managed,
    /// on a server that hands signing in to one (as Matrix Authentication Service does). The SDK
    /// knows it for an account signed in through OAuth; one signed in with a password through such
    /// a server's compatibility layer finds it in the homeserver's published sign-in details.
    func accountPageURL() async -> URL? {
        if let address = try? await client.accountUrl(action: .profile), let url = URL(string: address) {
            return url
        }
        for path in ["../v1/auth_metadata", "../unstable/org.matrix.msc2965/auth_metadata"] {
            if let (status, json) = try? await accountRequest("GET", path), status == 200,
               let address = json["account_management_uri"] as? String, let url = URL(string: address) {
                return url
            }
        }
        return nil
    }

    /// Opens the account's page on its sign-in server. In the Dev build with
    /// HUDDLE_DEV_NO_BROWSER, prints it instead.
    func openAccountPage() async throws {
        guard let url = await accountPageURL() else { throw PasswordChangeError.noAccountPage }
        if AppEnvironment.isDev, ProcessInfo.processInfo.environment["HUDDLE_DEV_NO_BROWSER"] != nil {
            print("DEV_ACCOUNT_URL \(url.absoluteString)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Changes the account's password, proving who it is with the current one. Signing out the
    /// other devices revokes their sessions; this one stays signed in either way.
    func changePassword(from current: String, to new: String, signingOutOtherDevices: Bool) async throws {
        var body: [String: Any] = ["new_password": new, "logout_devices": signingOutOtherDevices]
        var auth: [String: Any] = [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": userID],
            "password": current,
        ]
        // The current password goes with the first request. A server that wants its own session
        // for that answers 401 with one, and is asked again with it.
        for attempt in 0..<2 {
            body["auth"] = auth
            let (status, json) = try await accountRequest("POST", "account/password", body: body)
            switch status {
            case 200:
                return
            case 401:
                let completed = json["completed"] as? [String] ?? []
                if json["errcode"] as? String == "M_FORBIDDEN" { throw PasswordChangeError.wrongPassword }
                let flows = (json["flows"] as? [[String: Any]])?.compactMap { $0["stages"] as? [String] } ?? []
                guard attempt == 0, completed.isEmpty, flows.contains(["m.login.password"]),
                      let session = json["session"] as? String else {
                    throw PasswordChangeError.needsMoreThanPassword
                }
                auth["session"] = session
            default:
                throw PasswordChangeError.refused(json["error"] as? String)
            }
        }
        throw PasswordChangeError.needsMoreThanPassword
    }

    /// A request to the homeserver's client API as this account: its status and JSON reply.
    private func accountRequest(_ method: String, _ path: String,
                                body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        let session = try client.session()
        guard var components = URLComponents(string: session.homeserverUrl) else {
            throw PasswordChangeError.refused(nil)
        }
        // "../v1/…" reaches the API's other versions.
        let api = path.hasPrefix("../") ? "/_matrix/client/" + path.dropFirst(3) : "/_matrix/client/v3/" + path
        components.percentEncodedPath = components.path.trimmingSuffix("/") + api
        guard let url = components.url else { throw PasswordChangeError.refused(nil) }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, json)
    }
}

enum PasswordChangeError: LocalizedError {
    case wrongPassword
    case needsMoreThanPassword
    case noAccountPage
    case refused(String?)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:
            "Your current password isn't right."
        case .needsMoreThanPassword:
            "Your server asks for more than your password to change it. Change it on your server's website instead."
        case .noAccountPage:
            "Your server doesn't have an account page."
        case .refused(let message):
            message.map { "Your server didn't accept it: \($0)" } ?? "Your password couldn't be changed."
        }
    }
}
