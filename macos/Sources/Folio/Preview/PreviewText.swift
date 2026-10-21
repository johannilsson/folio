import AppKit

extension NSAttributedString.Key {
    /// On a paragraph that may be wider than the text column (a picture): it starts where the text does
    /// and may run on to the right edge of the window.
    static let folioWide = NSAttributedString.Key("folioWide")

    /// Marks the preview of a suggestion (the text a `replace` or `insert` would put in). The value is
    /// the annotation's id. The text is in the view but not in the file.
    static let folioGhost = NSAttributedString.Key("folioGhost")
}

/// A table of the text. Its width and its place are the view's to set once it knows how wide the window is
/// (`PreviewView.applyColumn`): at least as wide as the text column, wider when its content asks for it.
/// It starts where the text does: a text table has no left margin, so an empty first column makes it.
final class PreviewTable {
    let grid: NSTextTable
    /// The cells of an extra first column with nothing in it, whose width is the table's left margin.
    var spacers: [NSTextTableBlock] = []
    /// How wide the table is when no cell has to wrap.
    var natural: CGFloat = 0

    init(grid: NSTextTable) {
        self.grid = grid
    }
}

/// The rendered text of a markdown file, and how its characters line up with the file's. Everything
/// that is anchored or selected goes through this map, so the rules of what is rendered text stay in
/// Rust (`Rust.anchor`, `Rust.renderedSelection`), which work on the markdown itself.
struct PreviewText {
    struct Segment {
        var display: NSRange
        /// Where the characters came from in the file. Nil for characters that exist only in the
        /// rendering: a bullet, the line between blocks, the preview of a suggestion.
        var source: NSRange?
        /// Display and source hold the same text, so a position inside is one to one. Otherwise
        /// (an entity, a rule, a fallback) the segment is mapped as a whole.
        var linear: Bool
    }

    var text = NSMutableAttributedString()
    var segments: [Segment] = []
    var tables: [PreviewTable] = []

    private var sourced: [Segment] { segments.filter { $0.source != nil } }

    // MARK: file to display

    /// The displayed range of the file's `range`, or nil when none of it is shown.
    func displayRange(forSource range: NSRange) -> NSRange? {
        guard let start = displayLocation(forSource: range.location, end: false),
              let end = displayLocation(forSource: range.upperBound, end: true), end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// Where the file's offset is on screen. A range's start snaps forward to the next shown
    /// character, its end (and a point, such as an insertion) back to the previous one.
    func displayLocation(forSource offset: Int, end: Bool) -> Int? {
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
    func sourceRange(forDisplay range: NSRange) -> NSRange? {
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
    mutating func insertGhost(_ ghost: NSAttributedString, at location: Int) {
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
}
