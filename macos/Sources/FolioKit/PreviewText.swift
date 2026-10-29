import AppKit

public extension NSAttributedString.Key {
    /// On a paragraph that may be wider than the text column (a picture): it starts where the text does
    /// and may run on to the right edge of the window.
    static let folioWide = NSAttributedString.Key("folioWide")

    /// On a paragraph that is a diagram: centred between the sides of the text container, whatever the
    /// text column is.
    static let folioCentered = NSAttributedString.Key("folioCentered")

    /// Marks the preview of a suggestion (the text a `replace` or `insert` would put in). The value is
    /// the annotation's id. The text is in the view but not in the file.
    static let folioGhost = NSAttributedString.Key("folioGhost")
}

/// A table of the text. Its width and its place are the view's to set once it knows how wide the window is
/// (`PreviewView.applyColumn`): at least as wide as the text column, wider when its content asks for it.
/// It starts where the text does: a text table has no left margin, so an empty first column makes it.
public final class PreviewTable {
    public let grid: NSTextTable
    /// The cells of an extra first column with nothing in it, whose width is the table's left margin.
    public var spacers: [NSTextTableBlock] = []
    /// How wide the table is when no cell has to wrap.
    public var natural: CGFloat = 0
    /// The margin and width last given to the grid: laid-out text keeps what it was laid out with until told otherwise.
    public var applied: (margin: CGFloat, width: CGFloat) = (-1, -1)

    public init(grid: NSTextTable) {
        self.grid = grid
    }
}

/// The rendered text of a markdown file, and how its characters line up with the file's. Everything
/// that is anchored or selected goes through this map, so the rules of what is rendered text stay in
/// Rust (`Rust.anchor`, `Rust.renderedSelection`), which work on the markdown itself.
public struct PreviewText {
    public struct Segment {
        public var display: NSRange
        /// Where the characters came from in the file. Nil for characters that exist only in the
        /// rendering: a bullet, the line between blocks, the preview of a suggestion.
        public var source: NSRange?
        /// Display and source hold the same text, so a position inside is one to one. Otherwise
        /// (an entity, a rule, a fallback) the segment is mapped as a whole.
        public var linear: Bool

        public init(display: NSRange, source: NSRange?, linear: Bool) {
            self.display = display
            self.source = source
            self.linear = linear
        }
    }

    public var text = NSMutableAttributedString()
    public var segments: [Segment] = []
    public var tables: [PreviewTable] = []

    public init() {}

    private var sourced: [Segment] { segments.filter { $0.source != nil } }

    // MARK: file to display

    /// The displayed range of the file's `range`, or nil when none of it is shown.
    public func displayRange(forSource range: NSRange) -> NSRange? {
        guard let start = displayLocation(forSource: range.location, end: false),
              let end = displayLocation(forSource: range.upperBound, end: true), end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Where the file's offset is on screen. A range's start snaps forward to the next shown
    /// character, its end (and a point, such as an insertion) back to the previous one.
    public func displayLocation(forSource offset: Int, end: Bool) -> Int? {
        let list = sourced
        guard let first = list.first, let last = list.last else { return nil }
        if end {
            guard let segment = list.last(where: { $0.source!.location < offset }) else { return first.display.location }
            let source = segment.source!
            if offset >= source.upperBound { return segment.display.upperBound }
            return segment.linear ? segment.display.location + offset - source.location : segment.display.upperBound
        }
        guard let segment = list.first(where: { $0.source!.upperBound > offset }) else { return last.display.upperBound }
        let source = segment.source!
        if offset <= source.location || !segment.linear { return segment.display.location }
        return segment.display.location + offset - source.location
    }

    // MARK: display to file

    /// The file's range for a displayed one, or nil when it holds nothing from the file (bullets, say).
    public func sourceRange(forDisplay range: NSRange) -> NSRange? {
        let list = sourced
        guard let first = list.first(where: { $0.display.upperBound > range.location }),
              let last = list.last(where: { $0.display.location < range.upperBound }) else { return nil }
        let a = first.source!, b = last.source!
        let start = range.location <= first.display.location || !first.linear ? a.location : a.location + range.location - first.display.location
        let end = range.upperBound >= last.display.upperBound || !last.linear ? b.upperBound : b.location + range.upperBound - last.display.location
        return end > start ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: suggestions

    /// Puts the preview of a suggestion into the text at a displayed position.
    public mutating func insertGhost(_ ghost: NSAttributedString, at location: Int) {
        var location = location
        // Inside a segment that cannot be cut, the preview goes after it.
        if let inside = segments.first(where: { $0.display.location < location && location < $0.display.upperBound }), !inside.linear || inside.source == nil {
            location = inside.display.upperBound
        }
        var result: [Segment] = []
        var added = false
        for segment in segments {
            if segment.display.location >= location {
                if !added { result.append(Segment(display: NSRange(location: location, length: ghost.length), source: nil, linear: false)); added = true }
                var moved = segment
                moved.display.location += ghost.length
                result.append(moved)
            } else if segment.display.upperBound > location, let source = segment.source {
                // Linear, and cut at the position: the two halves around the preview.
                let cut = location - segment.display.location
                result.append(Segment(display: NSRange(location: segment.display.location, length: cut),
                                      source: NSRange(location: source.location, length: cut), linear: true))
                result.append(Segment(display: NSRange(location: location, length: ghost.length), source: nil, linear: false))
                added = true
                result.append(Segment(display: NSRange(location: location + ghost.length, length: segment.display.length - cut),
                                      source: NSRange(location: source.location + cut, length: source.length - cut), linear: true))
            } else {
                result.append(segment)
            }
        }
        if !added { result.append(Segment(display: NSRange(location: location, length: ghost.length), source: nil, linear: false)) }
        segments = result
        text.insert(ghost, at: location)
    }

    // MARK: rows

    /// The row of the rendered `text` that holds the character at `index`, which inline cards go under:
    /// its last character, and whether it is a block painted behind (code, the frontmatter box), whose
    /// paint reaches below its text. A paragraph, heading or list item is a row; a block of code and a
    /// table are one row each, the table ending with the line after it, which is not in the table.
    public static func row(at index: Int, in text: NSAttributedString) -> (end: Int, painted: Bool)? {
        guard text.length > 0 else { return nil }
        let string = text.string as NSString
        let index = min(max(0, index), text.length - 1)
        var end = string.paragraphRange(for: NSRange(location: index, length: 0)).upperBound - 1
        var run = NSRange()
        let kind = text.attribute(.folioBlock, at: index, longestEffectiveRange: &run, in: NSRange(location: 0, length: text.length)) as? String
        let painted = kind == "code" || kind == "box"
        // The block is marked up to its last line break, which ends it.
        if painted { end = min(run.upperBound, text.length - 1) }
        while end + 1 < text.length, let style = text.attribute(.paragraphStyle, at: end, effectiveRange: nil) as? NSParagraphStyle,
              !style.textBlocks.isEmpty {
            end = string.paragraphRange(for: NSRange(location: end + 1, length: 0)).upperBound - 1
        }
        return (end, painted)
    }
}
