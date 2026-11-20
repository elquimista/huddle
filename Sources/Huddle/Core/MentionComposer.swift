import Foundation
import MatrixRustSDK

/// Someone who can be mentioned, or the whole room.
struct MentionCandidate: Identifiable, Equatable {
    static let room = MentionCandidate(id: "@room", name: "room", avatarURL: nil)

    /// The user ID, or "@room".
    let id: String
    let name: String
    let avatarURL: String?

    var isRoom: Bool { id == "@room" }
}

/// A mention picked from the suggestions while writing. It counts only if its label is still
/// in the text when the message is sent.
struct ComposedMention: Equatable {
    /// How it reads in the composer: "@" and the user's own name for the person
    /// (ContactNames.swift), where they've given one, or else the person's name in the room.
    let label: String
    /// Nil for "@room".
    let userID: String?
    /// The person's name in the room, which is what's sent: the user's own name for them is
    /// theirs alone. Nil for "@room".
    var name: String? = nil

    init(label: String, userID: String?, name: String? = nil) {
        self.label = label
        self.userID = userID
        self.name = name
    }

    /// Someone picked from the suggestions, shown by the user's name for them if there is one.
    init(_ candidate: MentionCandidate, contactName: String?) {
        if candidate.isRoom {
            self.init(label: "@room", userID: nil)
        } else {
            self.init(label: "@" + (contactName ?? candidate.name), userID: candidate.id, name: candidate.name)
        }
    }
}

enum MentionComposer {
    /// The event to send: plain markdown when nobody is mentioned; otherwise a message whose
    /// HTML links each mentioned person and which names them, so their client notifies them.
    static func content(for text: String, mentions: [ComposedMention]) -> RoomMessageEventContentWithoutRelation {
        guard mentions.contains(where: { text.contains($0.label) }) else {
            return messageEventContentFromMarkdown(md: text)
        }
        let parts = parts(for: text, mentions: mentions)
        let html = parts.html ?? escape(parts.plain).replacingOccurrences(of: "\n", with: "<br>")
        return messageEventContentFromHtml(body: parts.plain, htmlBody: html)
            .withMentions(mentions: parts.mentions ?? Mentions(userIds: [], room: false))
    }

    /// A sent message as it would have been typed: each mention back as "@Name", with the
    /// person it names, so that editing the message keeps its mentions. A person the user has
    /// named reads by that name, as they would have been picked; the name sent stays theirs.
    static func draft(body: String, html: String?, mentionsRoom: Bool,
                      contactName: (String) -> String? = { _ in nil }) -> (text: String, mentions: [ComposedMention]) {
        var text = body
        var mentions: [ComposedMention] = []
        if let html {
            let pattern = #/<a\s+href="([^"]*)"\s*>([^<]*)<\/a>/#
            var cursor = text.startIndex
            for match in html.matches(of: pattern) {
                let href = String(match.output.1).removingPercentEncoding ?? String(match.output.1)
                guard let range = href.range(of: "matrix.to/#/@") else { continue }
                let userID = String(href[href.index(before: range.upperBound)...])
                    .split(separator: "?").first.map(String.init) ?? ""
                let name = decodeEntities(String(match.output.2))
                guard !userID.isEmpty, !name.isEmpty,
                      let found = text.range(of: name, range: cursor..<text.endIndex) else { continue }
                let sent = name.hasPrefix("@") ? String(name.dropFirst()) : name
                let label = "@" + (contactName(userID) ?? sent)
                let alreadyAt = found.lowerBound > text.startIndex && text[text.index(before: found.lowerBound)] == "@"
                // "@Bob" or "Bob" in the text, whichever it has, becomes the label.
                let start = alreadyAt ? text.index(before: found.lowerBound) : found.lowerBound
                text.replaceSubrange(start..<found.upperBound, with: label)
                cursor = text.index(start, offsetBy: label.count)
                let mention = ComposedMention(label: label, userID: userID, name: sent)
                if !mentions.contains(mention) { mentions.append(mention) }
            }
        }
        if mentionsRoom, text.contains("@room") { mentions.append(ComposedMention(label: "@room", userID: nil)) }
        return (text, mentions)
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The same text as the pieces an attachment's caption needs: plain text, HTML if any
    /// formatting or mention calls for it, and who is mentioned.
    static func parts(for text: String, mentions: [ComposedMention]) -> (plain: String, html: String?, mentions: Mentions?) {
        // Longest label first, so "@Ann" doesn't claim the start of "@Anna".
        let used = mentions.filter { text.contains($0.label) }.sorted { $0.label.count > $1.label.count }
        var plain = ""
        var html = ""
        var userIDs: [String] = []
        var mentionsRoom = false
        var pending = ""        // ordinary text since the last mention
        func flush() {
            plain += pending
            html += inlineHTML(fromMarkdown: pending)
            pending = ""
        }
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@", let mention = used.first(where: { text[index...].hasPrefix($0.label) }) {
                flush()
                if let userID = mention.userID {
                    let name = mention.name ?? String(mention.label.dropFirst())
                    plain += name
                    html += "<a href=\"https://matrix.to/#/\(userID)\">\(escape(name))</a>"
                    if !userIDs.contains(userID) { userIDs.append(userID) }
                } else {
                    plain += "@room"
                    html += "@room"
                    mentionsRoom = true
                }
                index = text.index(index, offsetBy: mention.label.count)
            } else {
                pending.append(text[index])
                index = text.index(after: index)
            }
        }
        flush()
        // HTML that says nothing the plain text doesn't is left out.
        let plainAsHTML = escape(plain).replacingOccurrences(of: "\n", with: "<br>")
        let hasMentions = !userIDs.isEmpty || mentionsRoom
        return (plain, html == plainAsHTML ? nil : html, hasMentions ? Mentions(userIds: userIDs, room: mentionsRoom) : nil)
    }

    /// Bold, italic, code, strikethrough and links from markdown, as HTML. Line breaks are kept.
    private static func inlineHTML(fromMarkdown markdown: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return escape(markdown).replacingOccurrences(of: "\n", with: "<br>")
        }
        var html = ""
        for run in parsed.runs {
            var piece = escape(String(parsed[run.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) { piece = "<code>\(piece)</code>" }
            if intent.contains(.strikethrough) { piece = "<del>\(piece)</del>" }
            if intent.contains(.emphasized) { piece = "<em>\(piece)</em>" }
            if intent.contains(.stronglyEmphasized) { piece = "<strong>\(piece)</strong>" }
            if let link = run.link { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            html += piece
        }
        return html
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
