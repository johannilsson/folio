import AppKit

/// Colours the markdown source: headings, emphasis, code, links, quotes, list markers, fences.
/// Line by line, with one piece of state (inside a fenced block), which is all the editor needs.
/// It sets attributes on the text storage and never touches the characters.
enum MarkdownHighlighter {
    static let fontSize: CGFloat = 13

    static let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    private static let medium = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
    private static let strong = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)

    private static let marker = NSColor.tertiaryLabelColor
    private static let quote = NSColor.secondaryLabelColor
    private static let code = NSColor.systemOrange.blended(withFraction: 0.35, of: .labelColor) ?? .systemOrange
    private static let link = NSColor.systemBlue

    // One pass over a line's text for the inline forms. Not a full CommonMark parse: the
    // forms below, in the order they should win.
    private static let inline: [(NSRegularExpression, (NSMutableAttributedString, NSRange) -> Void)] = [
        (try! NSRegularExpression(pattern: "`[^`\\n]+`"), { text, range in
            text.addAttribute(.foregroundColor, value: code, range: range)
            text.addAttribute(.backgroundColor, value: NSColor.quaternaryLabelColor, range: range)
        }),
        (try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__"), { text, range in
            text.addAttribute(.font, value: strong, range: range)
        }),
        (try! NSRegularExpression(pattern: "(?<![*\\w])\\*[^*\\s][^*\\n]*\\*(?![*\\w])|(?<![_\\w])_[^_\\s][^_\\n]*_(?![_\\w])"), { text, range in
            text.addAttribute(.obliqueness, value: 0.2, range: range)
        }),
        (try! NSRegularExpression(pattern: "!?\\[[^\\]\\n]*\\]\\([^)\\n]*\\)"), { text, range in
            text.addAttribute(.foregroundColor, value: link, range: range)
        }),
        (try! NSRegularExpression(pattern: "<https?://[^>\\s]+>"), { text, range in
            text.addAttribute(.foregroundColor, value: link, range: range)
        }),
    ]

    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})([ \\t].*)?$")
    private static let fence = try! NSRegularExpression(pattern: "^\\s{0,3}(```|~~~)")
    private static let listMarker = try! NSRegularExpression(pattern: "^\\s*([-*+]|\\d{1,9}[.)])[ \\t]")
    private static let rule = try! NSRegularExpression(pattern: "^\\s{0,3}([-*_])(\\s*\\1){2,}\\s*$")

    /// Gives all of `storage` its look.
    static func apply(to storage: NSTextStorage) {
        let whole = NSRange(location: 0, length: storage.length)
        let text = storage.string as NSString
        storage.beginEditing()
        storage.setAttributes([.font: regular, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph], range: whole)

        var inFence = false
        text.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange)
            let local = NSRange(location: 0, length: (line as NSString).length)

            if fence.firstMatch(in: line, range: local) != nil {
                inFence.toggle()
                storage.addAttribute(.foregroundColor, value: marker, range: lineRange)
                return
            }
            if inFence {
                storage.addAttribute(.foregroundColor, value: code, range: lineRange)
                return
            }
            if rule.firstMatch(in: line, range: local) != nil {
                storage.addAttribute(.foregroundColor, value: marker, range: lineRange)
                return
            }
            if let match = heading.firstMatch(in: line, range: local) {
                storage.addAttribute(.font, value: strong, range: lineRange)
                let hashes = match.range(at: 1)
                storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: lineRange.location + hashes.location, length: hashes.length))
                return
            }
            if line.hasPrefix(">") || line.drop(while: { $0 == " " }).hasPrefix(">") {
                storage.addAttribute(.foregroundColor, value: quote, range: lineRange)
            }
            if let match = listMarker.firstMatch(in: line, range: local) {
                let bullet = match.range(at: 1)
                storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: lineRange.location + bullet.location, length: bullet.length))
            }
            for (expression, style) in inline {
                expression.enumerateMatches(in: line, range: local) { match, _, _ in
                    guard let match else { return }
                    style(storage, NSRange(location: lineRange.location + match.range.location, length: match.range.length))
                }
            }
        }
        storage.endEditing()
    }

    /// The paragraph style the whole text uses: room between lines.
    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 22
        style.maximumLineHeight = 22
        return style
    }()
}
