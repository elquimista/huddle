import Foundation
import MatrixRustSDK

/// Requests to the homeserver's client API as an account, for what the SDK doesn't cover
/// (changing a password, Element's room list sections).
extension AccountSession {
    /// The reply's status and JSON. `path` follows `/_matrix/client/v3/`; one starting with
    /// "../" reaches the API's other versions ("../v1/…", "../unstable/…").
    func clientAPI(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil,
                   timeout: TimeInterval = 30) async throws -> (Int, [String: Any]) {
        let session = try client.session()
        guard var components = URLComponents(string: session.homeserverUrl) else { throw ClientAPIError.badAddress }
        let api = path.hasPrefix("../") ? "/_matrix/client/" + path.dropFirst(3) : "/_matrix/client/v3/" + path
        components.percentEncodedPath = components.path.trimmingSuffix("/") + api
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientAPIError.badAddress }
        var request = URLRequest(url: url, timeoutInterval: timeout)
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

    /// A user, room or tag ID made safe for a URL path.
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? value
    }
}

enum ClientAPIError: LocalizedError {
    case badAddress
    case refused(status: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .badAddress: "Your server's address isn't right."
        case .refused(_, let message): message ?? "Your server didn't accept the change."
        }
    }
}
