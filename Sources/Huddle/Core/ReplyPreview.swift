import Foundation
import MatrixRustSDK

/// The message a reply answers, summarised for the quote above the reply and for the composer.
struct ReplyPreview: Equatable {
    enum State: Equatable {
        case loading
        case ready
        /// Deleted, never received, or not something this account may read.
        case unavailable
    }

    /// The message being replied to.
    let eventID: String
    var state: State
    /// True while nobody has asked the server for the message yet.
    var needsFetch = false
    var sender = ""
    var senderName = ""
    /// One line of plain text standing for the message.
    var text = ""
    /// An SF Symbol for what the message is, when it isn't plain text.
    var icon: String?

    /// From a reply in the timeline: what the SDK knows about the message it answers.
    init(_ details: InReplyToDetails) {
        eventID = details.eventId()
        switch details.event() {
        case .unavailable:
            state = .loading
            needsFetch = true
        case .pending:
            state = .loading
        case .error:
            state = .unavailable
        case .ready(let content, let sender, let profile, _, _):
            state = .ready
            self.sender = sender
            senderName = profile.name(fallback: sender)
            (text, icon) = Self.describe(content, senderName: senderName)
        }
    }

    /// From a message on screen that the user is about to reply to. Nil for one that hasn't
    /// reached the server yet, which can't be replied to.
    init?(replyingTo message: MessageRow) {
        guard let eventID = message.eventID else { return nil }
        self.eventID = eventID
        state = .ready
        sender = message.sender
        senderName = message.senderName
        let formatted = message.html.map { FormattedBody(format: .html, body: $0) }
        switch message.body {
        case .text(let body):
            text = MessageFormatter.plainText(text: body, formatted: formatted)
        case .emote(let body):
            text = "* \(message.senderName) " + MessageFormatter.plainText(text: body, formatted: formatted)
        case .image(let image):
            (text, icon) = image.isSticker
                ? ("Sticker", "face.smiling")
                : (AttachmentText.line(name: image.filename, caption: image.caption, kind: "Image"), "photo")
        case .audio(let audio):
            (text, icon) = (audio.isVoice ? "Voice message"
                            : AttachmentText.line(name: audio.filename, caption: audio.caption, kind: "Audio"), "waveform")
        case .file(let file):
            (text, icon) = (AttachmentText.line(name: file.filename, caption: file.caption,
                                                kind: file.isVideo ? "Video" : "File"),
                            file.isVideo ? "film" : "doc")
        case .attachment(let symbol, let name):
            (text, icon) = (name, symbol)
        case .undecryptable:
            (text, icon) = ("Encrypted message", "lock")
        case .redacted:
            (text, icon) = ("Message deleted", "trash")
        case .unsupported(let description):
            text = description
        }
    }

    /// One line of plain text for a message's content, and an SF Symbol for what it is when it
    /// isn't plain text.
    static func describe(_ content: TimelineItemContent, senderName: String) -> (String, String?) {
        guard case .msgLike(let message) = content else {
            return (content.preview(sender: senderName) ?? "Message", nil)
        }
        switch message.kind {
        case .message(let content):
            switch content.msgType {
            case .text(let text):
                return (ReplyFallback.plainText(text.body, text.formatted), nil)
            case .notice(let notice):
                return (ReplyFallback.plainText(notice.body, notice.formatted), nil)
            case .emote(let emote):
                return ("* \(senderName) " + ReplyFallback.plainText(emote.body, emote.formatted), nil)
            case .image(let image):
                return (AttachmentText.line(name: image.filename, caption: image.caption, kind: "Image"), "photo")
            case .video(let video):
                return (AttachmentText.line(name: video.filename, caption: video.caption, kind: "Video"), "film")
            case .audio(let audio):
                return (audio.voice != nil ? "Voice message"
                        : AttachmentText.line(name: audio.filename, caption: audio.caption, kind: "Audio"), "waveform")
            case .file(let file):
                return (AttachmentText.line(name: file.filename, caption: file.caption, kind: "File"), "doc")
            case .gallery: return ("Images", "photo.on.rectangle")
            case .location: return ("Location", "mappin.and.ellipse")
            case .other(_, let body): return (body.replacingOccurrences(of: "\n", with: " "), nil)
            }
        case .sticker: return ("Sticker", "face.smiling")
        case .poll(let question, _, _, _, _, _, _): return ("Poll: \(question)", "chart.bar")
        case .redacted: return ("Message deleted", "trash")
        case .unableToDecrypt: return ("Encrypted message", "lock")
        case .other, .liveLocation: return ("Message", nil)
        }
    }
}

/// The quote of the message answered that a reply starts with, for clients that don't show
/// replies ("> <@bob:example.org> …" and, in HTML, an `<mx-reply>` block). Left out wherever a
/// message is shown as one line of its own words.
enum ReplyFallback {
    /// A message's plain text without the quote, from its HTML if it has any.
    static func plainText(_ body: String, _ formatted: FormattedBody?) -> String {
        let formatted = formatted.map { FormattedBody(format: $0.format, body: strip(html: $0.body)) }
        return MessageFormatter.plainText(text: strip(body: body), formatted: formatted)
    }

    static func strip(body: String) -> String {
        let lines = body.components(separatedBy: "\n")
        guard lines.first?.hasPrefix("> <") == true else { return body }
        return lines.drop { $0.hasPrefix(">") }
            .drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    static func strip(html: String) -> String {
        guard let end = html.range(of: "</mx-reply>") else { return html }
        return String(html[end.upperBound...])
    }
}
