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
    /// How the mention reads in the composer.
    var label: String { "@" + name }
}

/// A mention picked from the suggestions while writing. It counts only if its label is still
/// in the text when the message is sent.
struct ComposedMention: Equatable {
    let label: String
    /// Nil for "@room".
    let userID: String?
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
                    let name = String(mention.label.dropFirst())
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
