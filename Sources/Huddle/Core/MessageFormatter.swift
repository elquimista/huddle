import Foundation
import MatrixRustSDK
import SwiftUI

/// Turns a message into styled text: Matrix's HTML formatting (bold, code, lists, quotes),
/// clickable links, and mentions drawn as pills with the person's name.
enum MessageFormatter {
    /// - Parameters:
    ///   - text: the plain body, used when there is no HTML.
    ///   - html: the formatted body, if the sender's client provided one.
    ///   - mentionsRoom: whether the message is flagged as mentioning the whole room.
    ///   - name: the display name for a user ID, if known.
    ///   - keepsLinkText: for plain text, where mentions read as the sender wrote them.
    static func render(text: String, html: String?, mentionsRoom: Bool, ownUserID: String,
                       keepsLinkText: Bool = false, name: @escaping (String) -> String?) -> AttributedString {
        var result: AttributedString
        if let html {
            var parser = HTMLParser(html: html, ownUserID: ownUserID, keepsLinkText: keepsLinkText, name: name)
            result = parser.parse()
            if result.characters.isEmpty { result = AttributedString(text) }
        } else {
            result = AttributedString(text)
        }
        pillBareUserIDs(in: &result, ownUserID: ownUserID, name: name)
        if mentionsRoom { pillRoomMention(in: &result) }
        linkBareURLs(in: &result)
        return result
    }

    /// `render`, remembered: a message is drawn again whenever anything about its row changes
    /// (a reaction, a read receipt, the pointer passing over it), and its text rarely has.
    /// - Parameter names: changes whenever the names `name` knows change, so text that named
    ///   someone by their ID is drawn again once their name is known.
    static func renderCached(text: String, html: String?, mentionsRoom: Bool, ownUserID: String,
                             names: Int, name: @escaping (String) -> String?) -> AttributedString {
        let key = "\(names)\u{1}\(ownUserID)\u{1}\(mentionsRoom)\u{1}\(html ?? "")\u{1}\(text)" as NSString
        if let cached = renderCache.object(forKey: key) { return cached.value }
        let rendered = render(text: text, html: html, mentionsRoom: mentionsRoom, ownUserID: ownUserID, name: name)
        renderCache.setObject(RenderedText(rendered), forKey: key)
        return rendered
    }

    private final class RenderedText {
        let value: AttributedString
        init(_ value: AttributedString) { self.value = value }
    }

    private static let renderCache: NSCache<NSString, RenderedText> = {
        let cache = NSCache<NSString, RenderedText>()
        cache.countLimit = 3000
        return cache
    }()

    /// The same message as one line of plain text, for room list previews and notifications:
    /// mentions read "@Name" and formatting is dropped.
    /// - Parameter contactName: the user's own names for people (ContactNames.swift): a mention
    ///   of someone they've named reads by that name, as their pill does, rather than as the
    ///   sender wrote it.
    static func plainText(text: String, formatted: FormattedBody?,
                          contactName: (String) -> String? = { _ in nil }) -> String {
        let html = formatted.flatMap { $0.format == .html ? $0.body : nil }
        // Only used while rendering, which is over before this returns.
        let styled = withoutActuallyEscaping(contactName) { name in
            render(text: text, html: html, mentionsRoom: false, ownUserID: "", keepsLinkText: true, name: name)
        }
        return String(styled.characters)
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// Older clients begin a reply's plain text with the quoted message, each line prefixed
    /// with ">", then a blank line. Removes that, leaving what the sender wrote.
    static func strippingReplyFallback(_ body: String) -> String {
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first?.hasPrefix("> ") == true else { return body }
        while lines.first?.hasPrefix(">") == true { lines = lines.dropFirst() }
        if lines.first?.isEmpty == true { lines = lines.dropFirst() }
        return lines.isEmpty ? body : lines.joined(separator: "\n")
    }

    // MARK: Pills

    static func pill(_ label: String, isOwn: Bool) -> AttributedString {
        // Narrow no-break spaces pad the coloured background.
        var pill = AttributedString("\u{202F}\(label)\u{202F}")
        // Other people: coloured text, nothing more. A mention of you (or the room): bold on an
        // amber wash, so it is the one that stands out.
        if isOwn {
            pill.inlinePresentationIntent = .stronglyEmphasized
            pill.foregroundColor = Color(nsColor: .systemOrange)
            pill.backgroundColor = Color(nsColor: .systemYellow).opacity(0.28)
        } else {
            pill.foregroundColor = .accentColor
        }
        pill[MentionAttribute.self] = true
        return pill
    }

    /// A pill reads as the person it points to: their name in the room, else their username.
    /// Not the link's own text, which the sender wrote: `<a href="…/@mallory:evil">@Alice</a>`
    /// would otherwise pass for a mention of Alice. Plain text (`keepsLinkText`: previews and
    /// alerts) has no pill to pass off, so there the sender's words stand, as typed text would,
    /// unless the user has a name of their own for the person, which `name` then gives.
    static func mentionLabel(for userID: String, given label: String?, keepsLinkText: Bool = false,
                             name: (String) -> String?) -> String {
        if keepsLinkText, let own = name(userID)?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty {
            return "@" + own
        }
        var shown = keepsLinkText ? label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" : ""
        // Some clients put the raw ID in the link text; a name reads better.
        if shown.isEmpty || shown.hasPrefix("@") && shown.contains(":") {
            let known = name(userID)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            shown = known.isEmpty ? userID.matrixLocalpart : known
        }
        return shown.hasPrefix("@") ? shown : "@" + shown
    }

    private static let userIDPattern = try! NSRegularExpression(
        pattern: #"(?<![\w/@.])@[A-Za-z0-9._=\-/+]+:[A-Za-z0-9\-]+(\.[A-Za-z0-9\-]+)*(:\d+)?"#)

    /// "@alice:example.org" typed or pasted into plain text.
    private static func pillBareUserIDs(in text: inout AttributedString, ownUserID: String, name: (String) -> String?) {
        replaceMatches(of: userIDPattern, in: &text) { id in
            pill(mentionLabel(for: id, given: nil, name: name), isOwn: id == ownUserID)
        }
    }

    private static let roomPattern = try! NSRegularExpression(pattern: #"(?<![\w@])@room\b"#)

    private static func pillRoomMention(in text: inout AttributedString) {
        replaceMatches(of: roomPattern, in: &text) { _ in pill("@room", isOwn: true) }
    }

    private static func replaceMatches(of pattern: NSRegularExpression, in text: inout AttributedString,
                                       with replacement: (String) -> AttributedString) {
        let plain = String(text.characters)
        let matches = pattern.matches(in: plain, range: NSRange(plain.startIndex..., in: plain))
        // Back to front, so earlier ranges stay valid.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            // Leave existing pills, links and code alone.
            let slice = text[lower..<upper]
            if slice.runs.contains(where: { $0[MentionAttribute.self] == true || $0.link != nil
                || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
            text.replaceSubrange(lower..<upper, with: replacement(String(plain[range])))
        }
    }

    /// Made once: building a detector is costly, and every message on screen goes through one.
    private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func linkBareURLs(in text: inout AttributedString) {
        guard let detector = linkDetector else { return }
        let plain = String(text.characters)
        for match in detector.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let url = match.url,
                  let range = Range(match.range, in: plain),
                  let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            if text[lower..<upper].runs.contains(where: { $0.link != nil || $0[MentionAttribute.self] == true }) { continue }
            text[lower..<upper].link = url
        }
    }
}

/// How an attached file reads in one line of text: the room list, an alert, a reply's quote.
enum AttachmentText {
    /// The file's name, then its caption if it has one: "sunset.jpg · Look at this".
    ///
    /// - Parameter kind: what to call it if it has no name, such as "Image".
    static func line(name: String, caption: String?, kind: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = name.isEmpty ? kind : name
        let caption = caption?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return caption.isEmpty || caption == name ? shown : "\(shown) · \(caption)"
    }
}

/// Marks a run as a mention pill, so later passes leave it alone.
enum MentionAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "huddle.mention"
}

/// A small, forgiving reader for the subset of HTML that Matrix messages use.
private struct HTMLParser {
    let html: String
    let ownUserID: String
    /// Mentions read as the sender wrote them (plain text), not as the person's name.
    let keepsLinkText: Bool
    let name: (String) -> String?

    private var output = AttributedString()
    private var bold = 0, italic = 0, strike = 0, code = 0, pre = 0, quote = 0
    private var links: [URL?] = []
    /// Collects a mention link's text until its closing tag.
    private var mention: (userID: String, label: String)?
    private var lists: [Int?] = []          // nil for bullets, a counter for numbered lists
    private var skipDepth = 0               // inside <mx-reply>
    private var atLineStart = true
    private var paragraphJustEnded = false
    private static let quoteBar = "▎ "
    private static let deepestIndent = 6
    /// Where each open link's text began in `output`, in characters, to check the text against
    /// where the link goes once it ends.
    private var linkStarts: [Int] = []

    init(html: String, ownUserID: String, keepsLinkText: Bool, name: @escaping (String) -> String?) {
        self.html = html
        self.ownUserID = ownUserID
        self.keepsLinkText = keepsLinkText
        self.name = name
    }

    mutating func parse() -> AttributedString {
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                handleTag(String(html[html.index(after: index)..<close]))
                index = html.index(after: close)
            } else if html[index] == "<" {
                // No ">" anywhere after this "<", so none after any later one either: the rest
                // is text. (Looking again from each "<" would take time growing with the square
                // of the message's length, which a message of nothing but "<" could use to hang
                // the app.)
                handleText(String(html[index...]))
                break
            } else {
                let next = html[html.index(after: index)...].firstIndex(of: "<") ?? html.endIndex
                handleText(String(html[index..<next]))
                index = next
            }
        }
        // Drop trailing line breaks left by closing block tags.
        while let last = output.characters.last, last.isNewline {
            output.removeSubrange(output.index(beforeCharacter: output.endIndex)..<output.endIndex)
        }
        return output
    }

    private mutating func handleText(_ raw: String) {
        guard skipDepth == 0 else { return }
        var text = Self.decodeEntities(raw)
        if pre == 0 {
            // HTML treats any run of whitespace, line breaks included, as one space.
            text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if atLineStart { text = String(text.drop(while: { $0 == " " })) }
        }
        guard !text.isEmpty else { return }
        if mention != nil {
            mention?.label += text
            return
        }
        append(text)
    }

    private mutating func append(_ text: String) {
        // Every quoted line starts with a bar.
        if quote > 0, atLineStart, text != Self.quoteBar {
            atLineStart = false
            append(Self.quoteBar)
        }
        var piece = AttributedString(text)
        var intent: InlinePresentationIntent = []
        if bold > 0 { intent.insert(.stronglyEmphasized) }
        if italic > 0 { intent.insert(.emphasized) }
        if strike > 0 { intent.insert(.strikethrough) }
        if code > 0 || pre > 0 { intent.insert(.code) }
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if quote > 0 { piece.foregroundColor = .secondary }
        if let link = links.last, let link { piece.link = link }
        output.append(piece)
        atLineStart = text.last?.isNewline == true
        paragraphJustEnded = false
    }

    /// Makes sure the output ends with at least `count` line breaks, unless it is empty.
    private mutating func breakLine(_ count: Int = 1) {
        guard !output.characters.isEmpty else { return }
        var existing = 0
        for character in output.characters.reversed() {
            guard character == "\n" else { break }
            existing += 1
        }
        if existing < count { output.append(AttributedString(String(repeating: "\n", count: count - existing))) }
        atLineStart = true
    }

    private mutating func handleTag(_ raw: String) {
        let isClosing = raw.hasPrefix("/")
        let body = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let tag = body.prefix { !$0.isWhitespace }.lowercased()

        if tag == "mx-reply" {
            skipDepth = max(0, skipDepth + (isClosing ? -1 : 1))
            return
        }
        guard skipDepth == 0 else { return }

        defer { if tag != "p" && tag != "div" || !isClosing { paragraphJustEnded = false } }
        switch tag {
        case "b", "strong": bold = max(0, bold + (isClosing ? -1 : 1))
        case "i", "em": italic = max(0, italic + (isClosing ? -1 : 1))
        case "del", "s", "strike": strike = max(0, strike + (isClosing ? -1 : 1))
        case "code": code = max(0, code + (isClosing ? -1 : 1))
        case "pre":
            breakLine()
            pre = max(0, pre + (isClosing ? -1 : 1))
        case "br":
            output.append(AttributedString("\n"))
            atLineStart = true
        case "p", "div":
            // A blank line between two paragraphs, but not between a paragraph and a list,
            // quote or code block next to it.
            if isClosing {
                breakLine()
                paragraphJustEnded = true
                return
            }
            breakLine(paragraphJustEnded ? 2 : 1)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            breakLine(2)
            bold = max(0, bold + (isClosing ? -1 : 1))
        case "blockquote":
            breakLine()
            quote = max(0, quote + (isClosing ? -1 : 1))
        case "ul":
            breakLine()
            if isClosing { _ = lists.popLast() } else { lists.append(nil) }
        case "ol":
            breakLine()
            if isClosing { _ = lists.popLast() } else { lists.append(1) }
        case "li":
            breakLine()
            guard !isClosing else { return }
            // Indented no deeper than a few levels: a message nesting thousands of lists would
            // otherwise grow to hundreds of millions of characters.
            let indent = String(repeating: "    ", count: min(max(0, lists.count - 1), Self.deepestIndent))
            if let last = lists.indices.last, let number = lists[last] {
                append("\(indent)\(number). ")
                lists[last] = number + 1
            } else {
                append("\(indent)•  ")
            }
            atLineStart = true
        case "hr":
            breakLine()
            append("———")
            breakLine()
        case "a":
            if isClosing {
                if let mention {
                    self.mention = nil
                    output.append(MessageFormatter.pill(
                        MessageFormatter.mentionLabel(for: mention.userID, given: mention.label,
                                                      keepsLinkText: keepsLinkText, name: name),
                        isOwn: mention.userID == ownUserID))
                    atLineStart = false
                } else if let start = linkStarts.popLast(), let link = links.popLast() {
                    // Text that is itself an address, of somewhere other than where the link
                    // goes, asks before going there (LinkPolicy).
                    if let link, start < output.characters.count {
                        let lower = output.characters.index(output.startIndex, offsetBy: start)
                        let shown = String(output.characters[lower...])
                        let checked = LinkPolicy.link(to: link, shown: shown)
                        if checked != link { output[lower...].link = checked }
                    }
                }
            } else {
                let href = Self.attribute("href", in: body).map(Self.decodeEntities)
                if let userID = href.flatMap(Self.mentionedUser) {
                    mention = (userID, "")
                } else {
                    links.append(href.flatMap { URL(string: $0) })
                    linkStarts.append(output.characters.count)
                }
            }
        case "img":
            if let alt = Self.attribute("alt", in: body), !alt.isEmpty { handleText(alt) }
        default:
            break   // span, font, u and anything unknown: keep the text, drop the tag
        }
    }

    /// The user ID in a matrix.to (or matrix:) link to a person, if that is what it is.
    private static func mentionedUser(_ href: String) -> String? {
        let decoded = href.removingPercentEncoding ?? href
        if let range = decoded.range(of: "matrix.to/#/") {
            let target = decoded[range.upperBound...].prefix { $0 != "?" && $0 != "/" }
            return target.hasPrefix("@") ? String(target) : nil
        }
        if decoded.hasPrefix("matrix:u/") {
            return "@" + decoded.dropFirst("matrix:u/".count).prefix { $0 != "?" }
        }
        return nil
    }

    /// Made once each, rather than for every tag of every message.
    private static let attributePatterns: [String: NSRegularExpression] = Dictionary(uniqueKeysWithValues:
        ["href", "alt"].compactMap { name in
            (try? NSRegularExpression(pattern: "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)')", options: .caseInsensitive))
                .map { (name, $0) }
        })

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let regex = attributePatterns[name],
              let match = regex.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)) else { return nil }
        for group in [2, 3] {
            if let range = Range(match.range(at: group), in: tag) { return String(tag[range]) }
        }
        return nil
    }

    private static let entities = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                                   "&nbsp;": "\u{00A0}", "&amp;": "&"]

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        // "&amp;" goes last (it is last in the list below) so "&amp;lt;" stays "&lt;".
        for key in ["&lt;", "&gt;", "&quot;", "&#39;", "&apos;", "&nbsp;", "&amp;"] {
            result = result.replacingOccurrences(of: key, with: entities[key]!)
        }
        // Numeric forms: &#8217; and &#x2019;
        guard let regex = try? NSRegularExpression(pattern: "&#(x[0-9A-Fa-f]+|[0-9]+);") else { return result }
        for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 1), in: result) else { continue }
            let token = result[digits]
            let value = token.hasPrefix("x") ? UInt32(token.dropFirst(), radix: 16) : UInt32(token)
            if let value, let scalar = Unicode.Scalar(value) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result
    }
}
