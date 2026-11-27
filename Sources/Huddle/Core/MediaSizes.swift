import Foundation
import MatrixRustSDK

/// How large files on the server really are, asked of the server before anything is downloaded
/// unasked.
///
/// The size a message gives for its picture, thumbnail or video is only its sender's word: a
/// "small" one can be the largest file the server takes. And once the SDK has started a
/// download, nothing stops it. So the server is asked first, with a HEAD request that fetches
/// the size and none of the file. Files on the server never change, so each is asked about once.
actor MediaSizes {
    private var known: [String: UInt64] = [:]
    private var asking: [String: Task<UInt64?, Never>] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        // What the SDK's own requests say (ClientFactory), not this Mac's system and build.
        configuration.httpAdditionalHeaders = ["User-Agent": "Huddle/0.1 (macOS)"]
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    /// The file's size in bytes, or nil if the server didn't say or couldn't be reached.
    func size(of source: MediaSource, client: Client) async -> UInt64? {
        let address = source.url()
        if let size = known[address] { return size }
        if let pending = asking[address] { return await pending.value }
        guard let request = Self.request(for: address, client: client) else { return nil }
        let pending = Task { [session] in await Self.ask(session, request) }
        asking[address] = pending
        let size = await pending.value
        asking[address] = nil
        if let size { known[address] = size }
        return size
    }

    /// A HEAD request for the file at `mxc://<server>/<id>`, through this account's server, as
    /// the SDK itself downloads it (authenticated media, Matrix 1.11).
    static func request(for address: String, client: Client) -> URLRequest? {
        guard address.hasPrefix("mxc://") else { return nil }
        let parts = address.dropFirst("mxc://".count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, isServerName(parts[0]), isMediaID(parts[1]),
              let token = try? client.session().accessToken else { return nil }
        var base = client.homeserver()
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/_matrix/client/v1/media/download/" + escaped(parts[0]) + "/" + escaped(parts[1])),
              url.scheme == "https" || url.scheme == "http" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func ask(_ session: URLSession, _ request: URLRequest) async -> UInt64? {
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let length = http.value(forHTTPHeaderField: "Content-Length") else { return nil }
        return UInt64(length.trimmingCharacters(in: .whitespaces))
    }

    /// As Matrix has them: a DNS name, IPv4 address or bracketed IPv6 address, and maybe a port.
    private static func isServerName(_ name: Substring) -> Bool {
        !name.isEmpty && name.count <= 255
            && name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.:[]".unicodeScalars.contains($0)) }
    }

    private static func isMediaID(_ id: Substring) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_") }
    }

    private static func escaped(_ part: Substring) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~:")
        return part.addingPercentEncoding(withAllowedCharacters: allowed) ?? String(part)
    }
}

/// Redirects keep the account's token only on the server it was meant for, and never leave
/// HTTPS for plain HTTP.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let from = task.originalRequest?.url, let to = request.url else { return nil }
        if from.scheme == "https", to.scheme != "https" { return nil }
        var request = request
        if from.scheme != to.scheme || from.host != to.host || from.port != to.port {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return request
    }
}
