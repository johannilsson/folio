import AppKit
import Markdown

/// Turns markdown into the preview's attributed string and the map of where its characters came
/// from (`PreviewText`). Blocks swift-markdown reads that are not drawn yet (tables, raw HTML) are
/// shown as their markdown, so nothing in the file is missing from the view.
struct PreviewBuilder {
    private struct Context {
        var indent: CGFloat = 0
        var quoted = false
        var inList = false
    }

    private struct Style {
        var heading = 0
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL?
        var quoted = false
    }

    static let bodySize: CGFloat = 15

    private let markdown: String
    private let source: NSString
    private var lineStarts = [0]
    private var utf16At: [Int] = []
    private var result = PreviewText()
    /// Where the block being written starts, when a list marker has been written ahead of it.
    private var blockStart: Int?

    static func build(_ markdown: String) -> PreviewText {
        var builder = PreviewBuilder(markdown)
        let document = Markdown.Document(parsing: markdown)
        builder.blocks(of: document, Context())
        return builder.result
    }

    private init(_ markdown: String) {
        self.markdown = markdown
        source = markdown as NSString
        // swift-markdown counts columns in UTF-8 bytes; the app counts UTF-16 units.
        var byte = 0, unit = 0
        utf16At.reserveCapacity(markdown.utf8.count + 1)
        for scalar in markdown.unicodeScalars {
            let bytes = UTF8.width(scalar), units = UTF16.width(scalar)
            for _ in 0..<bytes { utf16At.append(unit) }
            if scalar == "\n" { lineStarts.append(byte + 1) }
            byte += bytes
            unit += units
        }
        utf16At.append(unit)
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line >= 1, location.line <= lineStarts.count else { return nil }
        let byte = lineStarts[location.line - 1] + location.column - 1
        return byte >= 0 && byte < utf16At.count ? utf16At[byte] : nil
    }

    private func range(of node: Markup) -> NSRange? {
        guard let found = node.range, let a = offset(found.lowerBound), let b = offset(found.upperBound), b >= a, b <= source.length else { return nil }
        return NSRange(location: a, length: b - a)
    }

    // MARK: writing

    private mutating func emit(_ string: String, source range: NSRange?, linear: Bool, _ attributes: [NSAttributedString.Key: Any]) {
        guard !string.isEmpty else { return }
        let length = (string as NSString).length
        result.segments.append(.init(display: NSRange(location: result.text.length, length: length), source: range, linear: linear && range?.length == length))
        result.text.append(NSAttributedString(string: string, attributes: attributes))
    }

    /// Text that has its own place in the file: found inside the node's source when it is written the same way there.
    private mutating func leaf(_ string: String, of node: Markup, _ style: Style) {
        var place: NSRange?
        var linear = false
        if let whole = range(of: node) {
            let found = (source.substring(with: whole) as NSString).range(of: string)
            if found.location != NSNotFound {
                place = NSRange(location: whole.location + found.location, length: found.length)
                linear = true
            } else {
                place = whole
            }
        }
        emit(string, source: place, linear: linear, attributes(style))
    }

    private func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let size: CGFloat = style.heading > 0 ? [28, 23, 19, 17, 15, 14][min(style.heading, 6) - 1] : Self.bodySize
        var font: NSFont
        if style.code {
            font = .monospacedSystemFont(ofSize: size * 0.88, weight: style.bold ? .bold : .regular)
        } else {
            font = .systemFont(ofSize: size, weight: style.heading > 0 || style.bold ? .bold : .regular)
        }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.quoted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if style.code { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07) }
        if style.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link = style.link { attributes[.link] = link }
        return attributes
    }

    // MARK: blocks

    private mutating func blocks(of parent: Markup, _ context: Context) {
        for child in parent.children { block(child, context) }
    }

    /// Writes a block, then ends it with a line break of the rendering's own.
    private mutating func paragraph(_ context: Context, heading: Int = 0, _ body: (inout PreviewBuilder, Style) -> Void) {
        let start = blockStart ?? result.text.length
        let markered = blockStart != nil
        blockStart = nil
        var style = Style()
        style.heading = heading
        style.quoted = context.quoted
        body(&self, style)
        emit("\n", source: nil, linear: false, attributes(style))
        let layout = NSMutableParagraphStyle()
        layout.lineSpacing = 3
        layout.paragraphSpacing = heading > 0 ? 8 : (context.inList ? 4 : 10)
        layout.paragraphSpacingBefore = heading > 0 ? 10 : 0
        layout.headIndent = context.indent
        layout.firstLineHeadIndent = markered ? max(0, context.indent - 22) : context.indent
        layout.tabStops = [NSTextTab(textAlignment: .left, location: context.indent)]
        result.text.addAttribute(.paragraphStyle, value: layout, range: NSRange(location: start, length: result.text.length - start))
    }

    private mutating func block(_ node: Markup, _ context: Context) {
        switch node {
        case let heading as Heading:
            paragraph(context, heading: heading.level) { $0.inlines(of: heading, $1) }
        case let text as Paragraph:
            paragraph(context) { $0.inlines(of: text, $1) }
        case let code as CodeBlock:
            codeBlock(code, context)
        case let quote as BlockQuote:
            var inner = context
            inner.quoted = true
            inner.indent += 18
            blocks(of: quote, inner)
        case let list as UnorderedList:
            for item in list.listItems { listItem(item, marker: nil, context) }
        case let list as OrderedList:
            var number = Int(list.startIndex)
            for item in list.listItems {
                listItem(item, marker: "\(number).", context)
                number += 1
            }
        case is ThematicBreak:
            paragraph(context) { builder, style in
                builder.emit(String(repeating: "─", count: 24), source: builder.range(of: node), linear: false, builder.attributes(style))
            }
        default:
            raw(node, context)
        }
    }

    /// A block that is not drawn yet: its markdown, as it is in the file.
    private mutating func raw(_ node: Markup, _ context: Context) {
        guard let found = range(of: node) else { return }
        var text = source.substring(with: found)
        while text.hasSuffix("\n") { text.removeLast() }
        let whole = NSRange(location: found.location, length: (text as NSString).length)
        paragraph(context) { builder, style in
            var code = style
            code.code = true
            builder.emit(text, source: whole, linear: true, builder.attributes(code))
        }
    }

    private mutating func codeBlock(_ code: CodeBlock, _ context: Context) {
        var text = code.code
        while text.hasSuffix("\n") { text.removeLast() }
        let start = result.text.length
        paragraph(context) { builder, style in
            var mono = style
            mono.code = true
            builder.leaf(text, of: code, mono)
        }
        // Its lines are one block: no paragraph gap between them, and room after the last.
        let block = NSRange(location: start, length: result.text.length - start)
        if let style = (result.text.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 0
            style.headIndent += 12
            style.firstLineHeadIndent += 12
            result.text.addAttribute(.paragraphStyle, value: style, range: block)
        }
        if let last = result.text.attribute(.paragraphStyle, at: block.upperBound - 1, effectiveRange: nil) as? NSParagraphStyle,
           let spaced = last.mutableCopy() as? NSMutableParagraphStyle {
            spaced.paragraphSpacing = 14
            result.text.addAttribute(.paragraphStyle, value: spaced, range: NSRange(location: block.upperBound - 1, length: 1))
        }
    }

    private mutating func listItem(_ item: ListItem, marker: String?, _ context: Context) {
        var inner = context
        inner.indent += 22
        inner.inList = true
        blockStart = result.text.length
        var label = marker ?? "•"
        if let checkbox = item.checkbox { label = checkbox == .checked ? "☑" : "☐" }
        var style = Style()
        style.quoted = context.quoted
        emit(label + "\t", source: nil, linear: false, attributes(style))
        blocks(of: item, inner)
        blockStart = nil
    }

    // MARK: inline

    private mutating func inlines(of parent: Markup, _ style: Style) {
        for child in parent.children { inline(child, style) }
    }

    private mutating func inline(_ node: Markup, _ style: Style) {
        var next = style
        switch node {
        case let text as Text:
            leaf(text.string, of: node, style)
        case let code as InlineCode:
            next.code = true
            leaf(code.code, of: node, next)
        case is SoftBreak:
            emit(" ", source: range(of: node), linear: true, attributes(style))
        case is LineBreak:
            emit("\n", source: range(of: node), linear: false, attributes(style))
        case let html as InlineHTML:
            next.code = true
            leaf(html.rawHTML, of: node, next)
        case is Emphasis:
            next.italic = true
            inlines(of: node, next)
        case is Strong:
            next.bold = true
            inlines(of: node, next)
        case is Strikethrough:
            next.strike = true
            inlines(of: node, next)
        case let link as Link:
            next.link = link.destination.flatMap { URL(string: $0) }
            inlines(of: node, next)
        default:
            inlines(of: node, style)
        }
    }
}
