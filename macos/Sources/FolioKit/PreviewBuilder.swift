import AppKit
import Markdown

/// Turns markdown into the preview's attributed string and the map of where its characters came
/// from (`PreviewText`). Blocks swift-markdown reads that are not drawn yet (tables, raw HTML) are
/// shown as their markdown, so nothing in the file is missing from the view.
public struct PreviewBuilder {
    private struct Context {
        var indent: CGFloat = 0
        var quoted = false
        var inList = false
        /// How many block quotes this is in.
        var depth = 0
    }

    private struct Style {
        var heading = 0
        var bold = false
        var italic = false
        var code = false
        var strike = false
        var link: URL?
        var quoted = false
        /// Code in a block of its own: the view paints the block's background, not each letter's.
        var block = false
    }

    public static let bodySize: CGFloat = 15

    /// What is parsed: the file, but with the frontmatter blanked out, so offsets stay the file's.
    private let markdown: String
    /// Where relative image paths start: the folder of the file.
    private let base: URL?
    /// Whether PlantUML blocks are drawn as diagrams (a command or server is set up for them).
    private let plantUML: Bool
    private let source: NSString
    private var lineStarts = [0]
    private var utf16At: [Int] = []
    private var result = PreviewText()
    /// Where the block being written starts, when a list marker has been written ahead of it.
    private var blockStart: Int?

    public static func build(_ markdown: String, base: URL? = nil, plantUML: Bool) -> PreviewText {
        let front = PreviewFrontmatter.split(markdown)
        var builder = PreviewBuilder(markdown, parsed: front.map { Self.blanked(markdown, $0.range) } ?? markdown, base: base, plantUML: plantUML)
        if let front { builder.frontmatterBox(front) }
        let document = Markdown.Document(parsing: builder.markdown)
        builder.blocks(of: document, Context())
        return builder.result
    }

    /// The text with `range` turned into spaces (its line breaks kept), the same length.
    private static func blanked(_ text: String, _ range: NSRange) -> String {
        var units = Array(text.utf16)
        for index in range.location..<min(range.upperBound, units.count) where units[index] != 10 { units[index] = 32 }
        return String(decoding: units, as: UTF16.self)
    }

    private init(_ original: String, parsed markdown: String, base: URL?, plantUML: Bool) {
        self.markdown = markdown
        self.base = base
        self.plantUML = plantUML
        source = original as NSString
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
            font = .systemFont(ofSize: size, weight: style.bold ? .bold : (style.heading > 0 ? .medium : .regular))
        }
        if style.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.quoted ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        if style.code && !style.block { attributes[.backgroundColor] = NSColor.labelColor.withAlphaComponent(0.07) }
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
            let start = result.text.length
            paragraph(context) { $0.inlines(of: text, $1) }
            // A picture alone in its paragraph may be wider than the text.
            let only = Array(text.children)
            if only.count == 1, only[0] is Image {
                centre(NSRange(location: start, length: result.text.length - start))
            }
        case let code as CodeBlock:
            codeBlock(code, context)
        case let table as Markdown.Table:
            self.table(table, context)
        case let quote as BlockQuote:
            var inner = context
            inner.quoted = true
            inner.indent += 18
            inner.depth += 1
            let start = result.text.length
            blocks(of: quote, inner)
            // The bars of this level, where a deeper quote has not put its own count.
            let whole = NSRange(location: start, length: result.text.length - start)
            var open: [NSRange] = []
            result.text.enumerateAttribute(.folioQuote, in: whole) { value, run, _ in if value == nil { open.append(run) } }
            for run in open { result.text.addAttribute(.folioQuote, value: inner.depth, range: run) }
        case let list as UnorderedList:
            for item in list.listItems { listItem(item, marker: nil, context) }
        case let list as OrderedList:
            var number = Int(list.startIndex)
            for item in list.listItems {
                listItem(item, marker: "\(number).", context)
                number += 1
            }
        case is ThematicBreak:
            let start = result.text.length
            paragraph(context) { builder, style in
                builder.emit(" ", source: builder.range(of: node), linear: false, [.font: NSFont.systemFont(ofSize: 8)])
            }
            result.text.addAttribute(.folioBlock, value: "rule", range: NSRange(location: start, length: 1))
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
        let start = result.text.length
        paragraph(context) { builder, style in
            var code = style
            code.code = true
            code.block = true
            builder.emit(text, source: whole, linear: true, builder.attributes(code))
        }
        setApart(from: start, "code")
    }

    private mutating func codeBlock(_ code: CodeBlock, _ context: Context) {
        var text = code.code
        while text.hasSuffix("\n") { text.removeLast() }
        if plantUML, code.language?.lowercased() == "plantuml" {
            picture(PreviewAsset(.plantuml(text)), of: code, context)
            return
        }
        if code.language?.lowercased() == "mermaid" {
            picture(PreviewAsset(.mermaid(text)), of: code, context)
            return
        }
        let start = result.text.length
        paragraph(context) { builder, style in
            var mono = style
            mono.code = true
            mono.block = true
            builder.codeLines(text, of: code, mono)
        }
        if let language = code.language, !language.isEmpty, !text.isEmpty {
            result.text.addAttribute(.folioCode, value: PreviewCode(language: language.lowercased(), code: text),
                                     range: NSRange(location: start, length: (text as NSString).length))
        }
        setApart(from: start, "code")
        // Its lines are one block: no paragraph gap between them, and room after the last.
        let block = NSRange(location: start, length: result.text.length - start)
        if let style = (result.text.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle)?
            .mutableCopy() as? NSMutableParagraphStyle {
            style.paragraphSpacing = 0
            style.headIndent += 12
            style.firstLineHeadIndent += 12
            result.text.addAttribute(.paragraphStyle, value: style, range: block)
        }
        // A paragraph has the style of its first character, so the whole last line is set, not its line break.
        let lastLine = (result.text.string as NSString).paragraphRange(for: NSRange(location: block.upperBound - 1, length: 0))
        if let last = result.text.attribute(.paragraphStyle, at: lastLine.location, effectiveRange: nil) as? NSParagraphStyle,
           let spaced = last.mutableCopy() as? NSMutableParagraphStyle {
            spaced.paragraphSpacing = 22
            result.text.addAttribute(.paragraphStyle, value: spaced, range: lastLine)
        }
        // Room above the first line for the painted background.
        let firstLine = (result.text.string as NSString).paragraphRange(for: NSRange(location: block.location, length: 0))
        if let first = (result.text.attribute(.paragraphStyle, at: block.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            first.paragraphSpacingBefore = 16
            result.text.addAttribute(.paragraphStyle, value: first, range: firstLine)
        }
    }

    /// Marks what was just written (not its closing line break) as a block the view paints behind.
    private mutating func setApart(from start: Int, _ kind: String) {
        let end = result.text.length - 1
        guard end > start else { return }
        result.text.addAttribute(.folioBlock, value: kind, range: NSRange(location: start, length: end - start))
    }

    // MARK: frontmatter

    /// The frontmatter as rows of key and value in a box, which the view paints behind them.
    private mutating func frontmatterBox(_ front: PreviewFrontmatter) {
        guard !front.entries.isEmpty else { return }
        let size: CGFloat = 12
        let key: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.secondaryLabelColor]
        let value: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.labelColor]
        let column = ceil(front.entries.map { NSAttributedString(string: $0.key, attributes: key).size().width }.max() ?? 0) + 14 + 24
        let start = result.text.length
        for (index, entry) in front.entries.enumerated() {
            let rowStart = result.text.length
            emit(entry.key, source: entry.keyRange, linear: true, key)
            emit("\t", source: nil, linear: false, value)
            emit(entry.value, source: entry.valueRange, linear: true, value)
            emit("\n", source: nil, linear: false, value)
            let layout = NSMutableParagraphStyle()
            layout.firstLineHeadIndent = 14
            layout.headIndent = column
            layout.tailIndent = -14
            layout.lineSpacing = 2
            layout.paragraphSpacing = index == front.entries.count - 1 ? 26 : 2
            layout.paragraphSpacingBefore = index == 0 ? 14 : 0
            layout.tabStops = [NSTextTab(textAlignment: .left, location: column)]
            result.text.addAttribute(.paragraphStyle, value: layout, range: NSRange(location: rowStart, length: result.text.length - rowStart))
        }
        setApart(from: start, "box")
    }

    /// The code of a block. Where it is written as it is shown (a fence at the left edge) it is one piece; in a
    /// list or a quote the file has the indentation the code does not, so each line is found on its own.
    private mutating func codeLines(_ text: String, of node: CodeBlock, _ style: Style) {
        guard let whole = range(of: node), !source.substring(with: whole).contains(text) else {
            leaf(text, of: node, style)
            return
        }
        var cursor = whole.location
        let lines = text.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var place: NSRange?
            if !line.isEmpty {
                let found = source.range(of: line, options: [], range: NSRange(location: cursor, length: whole.upperBound - cursor))
                if found.location != NSNotFound {
                    place = found
                    cursor = found.upperBound
                }
            }
            emit(line, source: place, linear: place != nil, attributes(style))
            if index < lines.count - 1 { emit("\n", source: nil, linear: false, attributes(style)) }
        }
    }

    /// A picture in a block of its own: one character the view fills in once the picture is loaded.
    private mutating func picture(_ asset: PreviewAsset, of node: Markup, _ context: Context) {
        let start = result.text.length
        paragraph(context) { builder, style in
            builder.emitPicture(asset, of: node, builder.attributes(style))
        }
        centre(NSRange(location: start, length: result.text.length - start))
    }

    /// A picture in a block of its own is centred in the window and may be as wide as it.
    private mutating func centre(_ range: NSRange) {
        result.text.addAttribute(.folioWide, value: true, range: range)
        result.text.addAttribute(.folioCentered, value: true, range: range)
        if let style = (result.text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            style.alignment = .center
            result.text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    private mutating func emitPicture(_ asset: PreviewAsset, of node: Markup, _ attributes: [NSAttributedString.Key: Any]) {
        let attachment = NSTextAttachment()
        attachment.bounds = NSRect(x: 0, y: 0, width: 1, height: 1)
        var tagged = attributes
        tagged[.attachment] = attachment
        tagged[.folioAsset] = asset
        emit("\u{FFFC}", source: range(of: node), linear: false, tagged)
    }

    // MARK: tables

    private mutating func table(_ table: Markdown.Table, _ context: Context) {
        let rows: [[Markdown.Table.Cell]] =
            [table.head.children.compactMap { $0 as? Markdown.Table.Cell }]
            + table.body.children.compactMap { ($0 as? Markdown.Table.Row)?.children.compactMap { $0 as? Markdown.Table.Cell } }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let grid = NSTextTable()
        grid.numberOfColumns = columns + 1
        grid.collapsesBorders = true
        let info = PreviewTable(grid: grid)
        var widest = [CGFloat](repeating: 0, count: columns)
        for (r, row) in rows.enumerated() {
            let spacer = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            let spacing = NSMutableParagraphStyle()
            spacing.textBlocks = [spacer]
            let spacerStart = result.text.length
            emit("\n", source: nil, linear: false, [.font: NSFont.systemFont(ofSize: 1)])
            result.text.addAttribute(.paragraphStyle, value: spacing, range: NSRange(location: spacerStart, length: 1))
            info.spacers.append(spacer)
            for c in 0..<columns {
                let block = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1, startingColumn: c + 1, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor.separatorColor)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                if r == 0 { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06) }
                let layout = NSMutableParagraphStyle()
                layout.textBlocks = [block]
                if c < table.columnAlignments.count, let alignment = table.columnAlignments[c] {
                    layout.alignment = alignment == .center ? .center : (alignment == .right ? .right : .left)
                }
                let start = result.text.length
                var style = Style()
                style.bold = r == 0
                style.quoted = context.quoted
                if c < row.count { inlines(of: row[c], style) }
                // What the cell needs on one line, and its padding and border.
                let needed = result.text.attributedSubstring(from: NSRange(location: start, length: result.text.length - start)).size().width
                widest[c] = max(widest[c], ceil(needed) + 13)
                emit("\n", source: nil, linear: false, attributes(style))
                result.text.addAttribute(.paragraphStyle, value: layout, range: NSRange(location: start, length: result.text.length - start))
            }
        }
        info.natural = widest.reduce(0, +)
        result.tables.append(info)
        // Room after the table.
        var gap = Style()
        gap.quoted = context.quoted
        emit("\n", source: nil, linear: false, attributes(gap).merging([.font: NSFont.systemFont(ofSize: 6)]) { _, new in new })
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

    private func imageURL(_ path: String) -> URL? {
        if let url = URL(string: path), url.scheme != nil { return url }
        guard let base else { return nil }
        return URL(fileURLWithPath: path.removingPercentEncoding ?? path, relativeTo: base).standardizedFileURL
    }

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
        case let image as Image:
            if let place = image.source.flatMap({ imageURL($0) }) {
                emitPicture(PreviewAsset(.image(place)), of: node, attributes(style))
            } else {
                inlines(of: node, style)
            }
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
