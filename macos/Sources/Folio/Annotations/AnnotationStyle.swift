import AppKit

/// Looks shared by the annotation views. Chrome follows the system; Folio's own colour is
/// for content, so the avatars (who wrote it) are purple and blue, and everything else is system grey.
enum AnnotationStyle {
    /// A card, and the column of cards beside the text: 280 wide with a 24 margin to the window
    /// edge, as the page's own pane was.
    static let gutterWidth: CGFloat = 280
    static let paneWidth: CGFloat = 304
    static let cardWidth: CGFloat = 272
    static let cardPadding: CGFloat = 12
    static let avatarSize: CGFloat = 28

    static let cardFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.145, alpha: 1)
            : NSColor(srgbRed: 0.965, green: 0.965, blue: 0.96, alpha: 1)
    }

    /// Floating pieces over the text (the open card, the comment button, the toast).
    static let floatFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.18, alpha: 1)
            : NSColor.white
    }

    /// The look of the small things that float over the text, the Comment button and the toast: a
    /// capsule with a hairline edge, lifted off the page by a soft shadow.
    static func liftFloatingPill(_ layer: CALayer?) {
        layer?.shadowOpacity = 0.22
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
    }

    static func drawFloatingPill(in bounds: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        floatFill.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static let authorFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let timeFont = NSFont.systemFont(ofSize: 11)
    static let bodyFont = NSFont.systemFont(ofSize: 12)

    // MARK: people

    static func displayName(_ author: String) -> String { author == "me" ? "You" : author }

    private static let avatarColors: [NSColor] = ["#6366f1", "#0891b2", "#db2777", "#7c3aed"].map(color(hex:))

    private static func color(hex: String) -> NSColor {
        let value = Int(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }

    static func avatarColor(for name: String) -> NSColor {
        if name == "You" { return avatarColors[0] }
        var hash: UInt32 = 0
        for scalar in name.unicodeScalars { hash = hash &* 31 &+ scalar.value }
        return avatarColors[1 + Int(hash) % (avatarColors.count - 1)]
    }

    static func initials(for name: String) -> String {
        if name == "You" { return "Y" }
        let words = name.split(whereSeparator: \.isWhitespace)
        let letters = words.count > 1 ? String(words[0].prefix(1) + words[1].prefix(1)) : String(name.prefix(2))
        return letters.uppercased()
    }

    // MARK: text

    private static let isoParsers: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [plain, fractional]
    }()

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    /// The time of day, as the page showed it.
    static func time(_ iso: String) -> String {
        guard let date = isoParsers.lazy.compactMap({ $0.date(from: iso) }).first else { return "" }
        return clock.string(from: date)
    }

    /// Card text is markdown: emphasis, code and links render, line breaks stay.
    static func markdown(_ text: String, font: NSFont, color: NSColor, italic: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = (font.pointSize * 1.55).rounded()
        paragraph.lineBreakMode = .byWordWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]

        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        guard let parsed = try? AttributedString(markdown: text, options: options) else {
            return NSAttributedString(string: text, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attributes = base
            var traits: NSFontDescriptor.SymbolicTraits = italic ? [.italic] : []
            if let intent = run.inlinePresentationIntent {
                if intent.contains(.stronglyEmphasized) { traits.insert(.bold) }
                if intent.contains(.emphasized) { traits.insert(.italic) }
                if intent.contains(.code) {
                    attributes[.font] = NSFont.monospacedSystemFont(ofSize: font.pointSize * 0.95, weight: .regular)
                    attributes[.backgroundColor] = NSColor.quaternaryLabelColor
                }
            }
            if !traits.isEmpty, (attributes[.font] as? NSFont)?.isFixedPitch != true {
                let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
                attributes[.font] = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    /// The height `text` takes at `width`.
    static func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        guard text.length > 0, width > 0 else { return 0 }
        let box = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(box.height)
    }
}
