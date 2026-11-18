import Foundation
import MatrixRustSDK

/// The homeserver's own message search (`/_matrix/client/v3/search`). The server has every
/// message it can read already indexed, so this covers the whole history of unencrypted rooms
/// at once, with nothing to download; it can't read encrypted ones. The SDK doesn't wrap
/// the endpoint, so it is called here with the account's own session.
struct ServerSearch {
    let client: Client

    struct Page {
        let hits: [SearchHit]
        /// Where the next page starts; nil at the end.
        let nextBatch: String?
        /// The words the server matched, which can be forms of the ones searched for
        /// ("wrap" for "wraps").
        let highlights: [String]
    }

    enum Failure: Error {
        /// The server doesn't offer message search.
        case unsupported
        case server(String)
    }

    private static let pageSize = 20

    /// One page of messages matching `term`, newest first: in `roomIDs` if given, else in
    /// every room.
    func search(_ term: String, in roomIDs: [String]?, from nextBatch: String?) async throws -> Page {
        do {
            return try await request(term, roomIDs: roomIDs, nextBatch: nextBatch)
        } catch Failure.server(let message) where message == "M_UNKNOWN_TOKEN" {
            // An access token that has just expired: the SDK refreshes it on its next request
            // of its own (sync makes one every few seconds), so try once more after that.
            try await Task.sleep(for: .seconds(3))
            return try await request(term, roomIDs: roomIDs, nextBatch: nextBatch)
        }
    }

    private func request(_ term: String, roomIDs: [String]?, nextBatch: String?) async throws -> Page {
        let session = try client.session()
        var components = URLComponents(string: session.homeserverUrl)
        let basePath = components?.path ?? ""
        components?.path = basePath.trimmingSuffix("/") + "/_matrix/client/v3/search"
        if let nextBatch { components?.queryItems = [URLQueryItem(name: "next_batch", value: nextBatch)] }
        guard let url = components?.url else { throw Failure.unsupported }

        var filter: [String: Any] = ["limit": Self.pageSize]
        if let roomIDs { filter["rooms"] = roomIDs }
        let body: [String: Any] = [
            "search_categories": [
                "room_events": [
                    "search_term": term,
                    "keys": ["content.body"],
                    "order_by": "recent",
                    "filter": filter,
                    // No surrounding messages, only who sent each one.
                    "event_context": ["before_limit": 0, "after_limit": 0, "include_profile": true],
                ],
            ],
        ]
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard status == 200 else {
            let code = json["errcode"] as? String ?? ""
            if status == 404 || status == 405 || code == "M_UNRECOGNIZED" { throw Failure.unsupported }
            throw Failure.server(code.isEmpty ? "HTTP \(status)" : code)
        }

        let events = ((json["search_categories"] as? [String: Any])?["room_events"] as? [String: Any]) ?? [:]
        let results = events["results"] as? [[String: Any]] ?? []
        var hits: [SearchHit] = []
        // Newest first, so the first version of a message seen is its latest: an edit made
        // later, or the message itself. Older versions are left out.
        var seen = Set<String>()
        for result in results {
            guard let event = result["result"] as? [String: Any] else { continue }
            let profiles = (result["context"] as? [String: Any])?["profile_info"] as? [String: [String: Any]]
            guard let hit = Self.hit(from: event, profiles: profiles ?? [:]),
                  seen.insert(hit.jumpEventID ?? hit.eventID).inserted else { continue }
            hits.append(hit)
        }
        #if DEBUG
        print("DEV_SERVER_SEARCH results=\(results.count) hits=\(hits.count) more=\(events["next_batch"] != nil) highlights=\(events["highlights"] ?? "none")")
        fflush(stdout)
        #endif
        return Page(hits: hits, nextBatch: events["next_batch"] as? String,
                    highlights: events["highlights"] as? [String] ?? [])
    }

    /// A result as the panel shows it. An edit has its new words, and goes to the message it
    /// edits; a reply in a thread goes to the thread's first message. Anything that isn't a
    /// message is left out.
    private static func hit(from event: [String: Any], profiles: [String: [String: Any]]) -> SearchHit? {
        guard event["type"] as? String == "m.room.message",
              let roomID = event["room_id"] as? String,
              let eventID = event["event_id"] as? String,
              let sender = event["sender"] as? String,
              var content = event["content"] as? [String: Any] else { return nil }
        var jumpEventID: String?
        if let relation = content["m.relates_to"] as? [String: Any] {
            switch relation["rel_type"] as? String {
            case "m.replace":
                guard let newContent = content["m.new_content"] as? [String: Any] else { return nil }
                jumpEventID = relation["event_id"] as? String
                content = newContent
            case "m.thread":
                jumpEventID = relation["event_id"] as? String
            default:
                break
            }
        }
        let profile = profiles[sender]
        let senderName = (profile?["displayname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? sender
        let timestamp = (event["origin_server_ts"] as? NSNumber)?.doubleValue ?? 0
        let (text, icon) = describe(content, senderName: senderName)
        return SearchHit(roomID: roomID, eventID: eventID, sender: sender, senderName: senderName,
                         senderAvatarURL: profile?["avatar_url"] as? String,
                         date: Date(timeIntervalSince1970: timestamp / 1000), text: text, icon: icon,
                         jumpEventID: jumpEventID)
    }

    /// One line of text for a message's raw content, as `ReplyPreview.describe` makes for the
    /// SDK's: its words, or what kind of thing it is.
    private static func describe(_ content: [String: Any], senderName: String) -> (String, String?) {
        // A reply's quote of what it answers is left out: the message's own words come after it.
        let body = ReplyFallback.strip(body: content["body"] as? String ?? "")
        let html = content["format"] as? String == "org.matrix.custom.html" ? content["formatted_body"] as? String : nil
        let formatted = html.map { FormattedBody(format: .html, body: ReplyFallback.strip(html: $0)) }
        let caption = content["filename"] as? String != nil && content["filename"] as? String != body ? body : nil
        let name = content["filename"] as? String ?? body
        switch content["msgtype"] as? String {
        case "m.emote":
            return ("* \(senderName) " + MessageFormatter.plainText(text: body, formatted: formatted), nil)
        case "m.image":
            return (AttachmentText.line(name: name, caption: caption, kind: "Image"), "photo")
        case "m.video":
            return (AttachmentText.line(name: name, caption: caption, kind: "Video"), "film")
        case "m.audio":
            return (AttachmentText.line(name: name, caption: caption, kind: "Audio"), "waveform")
        case "m.file":
            return (AttachmentText.line(name: name, caption: caption, kind: "File"), "doc")
        case "m.location":
            return ("Location", "mappin.and.ellipse")
        default:
            return (MessageFormatter.plainText(text: body, formatted: formatted), nil)
        }
    }

    /// The message an event belongs to as the room shows it, if that's another one: what an
    /// edit changed, or the first message of a reply's thread. Relations stay readable in
    /// encrypted rooms.
    func relatedEventID(of eventID: String, in roomID: String) async -> String? {
        guard let session = try? client.session(),
              var components = URLComponents(string: session.homeserverUrl) else { return nil }
        let basePath = components.path.trimmingSuffix("/")
        components.percentEncodedPath = basePath + "/_matrix/client/v3/rooms/"
            + roomID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))!
            + "/event/"
            + eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))!
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let relation = (event["content"] as? [String: Any])?["m.relates_to"] as? [String: Any],
              ["m.replace", "m.thread"].contains(relation["rel_type"] as? String ?? "") else { return nil }
        return relation["event_id"] as? String
    }

    /// Whether anyone has a Matrix ID: false only when the server says nobody does (404).
    /// A refusal (some servers only show profiles of people who share a room) means
    /// they may well exist, so it's nil, as is any other failure.
    func userExists(_ userID: String) async -> Bool? {
        guard let session = try? client.session(),
              var components = URLComponents(string: session.homeserverUrl),
              let encoded = userID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#")))
        else { return nil }
        components.percentEncodedPath = components.path.trimmingSuffix("/") + "/_matrix/client/v3/profile/" + encoded
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return nil }
        switch status {
        case 200: return true
        case 404: return false
        default: return nil
        }
    }

    /// Whether the server offers message search at all, asked with a search that finds
    /// nothing.
    func isSupported() async -> Bool {
        do {
            _ = try await request("huddle-probe-\(UUID().uuidString.prefix(8))", roomIDs: nil, nextBatch: nil)
            return true
        } catch Failure.unsupported {
            return false
        } catch {
            // Down or refusing for now: assume it does, and let a real search find out.
            return true
        }
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
