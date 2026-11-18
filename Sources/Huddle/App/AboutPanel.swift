import AppKit

/// About Huddle: AppKit's panel laid out as MailMate's, its version naming the build and the
/// commit it's from, then the credits and the copyright (Info.plist's, from Scripts/build-app.sh).
@MainActor
enum AboutPanel {
    static func show() {
        let info = Bundle.main.infoDictionary ?? [:]
        let build = [info["CFBundleVersion"] as? String, info["HuddleCommit"] as? String]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        NSApp.orderFrontStandardAboutPanel(options: [.version: build, .credits: credits()])
        // Scrolled to the end, the credits' last line would sit on the box's edge: room above
        // and below them alike.
        func textView(in view: NSView) -> NSTextView? {
            view as? NSTextView ?? view.subviews.lazy.compactMap(textView(in:)).first
        }
        for window in NSApp.windows where window.isVisible {
            guard let text = window.contentView.flatMap(textView(in:)),
                  text.string.hasPrefix(Self.tagline) else { continue }
            text.textContainerInset = NSSize(width: 0, height: 5)
        }
    }

    private static let tagline = "A native Matrix client for macOS"

    /// As MailMate's credits (measured at 1x): centred, SF 11, a heading's line medium, each line
    /// 27 pt under the last, "—" between parts; the libraries with links to them and to their
    /// licenses, which the app carries.
    private static func credits() -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 27 - ceil(font.ascender - font.descender)
        let credits = NSMutableAttributedString()
        // A line's parts, " · " between them (`joined`: run together, as one phrase).
        func line(_ parts: [(text: String, link: URL?)], heading: Bool = false, joined: Bool = false) {
            for (index, part) in parts.enumerated() {
                if index > 0, !joined { credits.append(NSAttributedString(string: " · ")) }
                var attributes: [NSAttributedString.Key: Any] = [:]
                if let link = part.link { attributes[.link] = link }
                if heading { attributes[.font] = NSFont.systemFont(ofSize: 11, weight: .medium) }
                credits.append(NSAttributedString(string: part.text, attributes: attributes))
            }
            credits.append(NSAttributedString(string: "\n"))
        }
        func license(_ file: String) -> URL? {
            Bundle.main.url(forResource: file, withExtension: "txt", subdirectory: "Licenses")
        }
        line([(tagline, nil)])
        line([("—", nil)])
        line([("Programmed by", nil)], heading: true)
        line([("Felix-Andre Lee", nil)])
        line([("with ", nil), ("Claude Code", URL(string: "https://claude.com/claude-code")), (" by Anthropic", nil)],
             joined: true)
        line([("—", nil)])
        line([("Open-source software", nil)], heading: true)
        line([("Matrix Rust SDK", URL(string: "https://github.com/matrix-org/matrix-rust-sdk")),
              ("License", license("matrix-rust-sdk-LICENSE"))])
        line([("Sparkle", URL(string: "https://sparkle-project.org")), ("License", license("Sparkle-LICENSE"))])
        credits.deleteCharacters(in: NSRange(location: credits.length - 1, length: 1))  // no last line break
        let all = NSRange(location: 0, length: credits.length)
        credits.addAttribute(.paragraphStyle, value: paragraph, range: all)
        credits.enumerateAttribute(.font, in: all) { value, range, _ in
            if value == nil { credits.addAttribute(.font, value: font, range: range) }
        }
        credits.addAttribute(.foregroundColor, value: NSColor.labelColor, range: all)
        return credits
    }
}
