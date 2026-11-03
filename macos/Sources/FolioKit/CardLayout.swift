import CoreGraphics
import Foundation

/// Where the cards go: stacked in the comments pane beside the text, or floating over it (the open
/// card, the form for a new comment, the Comment button). Page coordinates, y down.
public enum CardLayout {
    /// Where a card's text is: its top, and its place in the document, which orders the pane.
    public struct Anchor: Equatable {
        public var top: CGFloat
        public var order: Int

        public init(top: CGFloat, order: Int) {
            self.top = top
            self.order = order
        }
    }

    /// A card to stack: its anchor (nil when it is not found in the document) and its measured height.
    public struct Card: Equatable {
        public var anchor: Anchor?
        public var height: CGFloat

        public init(anchor: Anchor?, height: CGFloat) {
            self.anchor = anchor
            self.height = height
        }
    }

    /// Stacks `cards` in document order, each at its anchor's top minus 4, pushed down to 6 below
    /// the one above when it would overlap. One not found in the document is parked at `end`, after
    /// the text. Returns each card's index in `cards` with its top, in document order, and how far
    /// down they reach.
    public static func stack(_ cards: [Card], end: CGFloat) -> (placed: [(index: Int, top: CGFloat)], extent: CGFloat) {
        let gap: CGFloat = 6
        let order = { (index: Int) in cards[index].anchor?.order ?? Int.max }
        var placed: [(index: Int, top: CGFloat)] = []
        var minTop: CGFloat = 0
        for index in cards.indices.sorted(by: { order($0) < order($1) }) {
            let top = max((cards[index].anchor?.top ?? end) - 4, minTop)
            placed.append((index: index, top: top))
            minTop = top + cards[index].height + gap
        }
        return (placed, minTop)
    }

    // MARK: inline

    /// A row of the text that cards can go under: a block of the preview, a line of the source.
    public struct Row: Equatable {
        /// The row's last character, which says which row it is (the room goes after the line it ends).
        public var end: Int
        /// Where the row's text ends.
        public var bottom: CGFloat
        /// Where the text after it starts when there is no room after it.
        public var next: CGFloat

        public init(end: Int, bottom: CGFloat, next: CGFloat) {
            self.end = end
            self.bottom = bottom
            self.next = next
        }
    }

    /// A card to put under its row (nil when it is not found in the document): its place in the
    /// document and its measured height.
    public struct InlineCard: Equatable {
        public var row: Row?
        public var order: Int
        public var height: CGFloat

        public init(row: Row?, order: Int, height: CGFloat) {
            self.row = row
            self.order = order
            self.height = height
        }
    }

    /// Puts `cards` under their rows: 8 below the row's text, stacked 6 apart in document order, and
    /// the text after the row starts 14 below the last of them. One not found in the document is
    /// parked after `end`. Returns each card's index in `cards` with its top, in document order, the
    /// room to leave after each row (by `Row.end`), and how far down the cards reach.
    public static func inline(_ cards: [InlineCard], end: CGFloat)
        -> (placed: [(index: Int, top: CGFloat)], room: [Int: CGFloat], extent: CGFloat) {
        let gap: CGFloat = 6, above: CGFloat = 8, below: CGFloat = 14
        let ordered = cards.indices.sorted { a, b in
            let (x, y) = (cards[a], cards[b])
            let (rowX, rowY) = (x.row?.end ?? Int.max, y.row?.end ?? Int.max)
            return rowX != rowY ? rowX < rowY : x.order < y.order
        }
        var placed: [(index: Int, top: CGFloat)] = []
        var room: [Int: CGFloat] = [:]
        var extent: CGFloat = 0
        var row: Row?
        var top: CGFloat = 0
        func close() {
            guard let row else { return }
            room[row.end] = max(0, top - gap + below - row.next)
        }
        for index in ordered {
            let card = cards[index]
            if card.row?.end != row?.end || placed.isEmpty {
                close()
                row = card.row
                top = (card.row?.bottom ?? end) + above
            }
            placed.append((index: index, top: top))
            extent = max(extent, top + card.height)
            top += card.height + gap
        }
        close()
        return (placed, room, extent)
    }

    /// Where something floating of `width` × `height` goes for text from `top` to `bottom` that starts
    /// at `left`: below `bottom`, or above `top` when it will not fit below but will fit above. Kept
    /// inside `visible` (also when it fits neither way, with the text at the bottom of the window) and
    /// inside the text column, `textWidth` wide.
    public static func floatingOrigin(width: CGFloat, height: CGFloat, left: CGFloat, top: CGFloat, bottom: CGFloat,
                                      visible: CGRect, textWidth: CGFloat) -> CGPoint {
        let fitsBelow = visible.maxY - bottom >= height + 12
        let fitsAbove = top - visible.minY > height + 12
        var y = !fitsBelow && fitsAbove ? top - height - 6 : bottom + 6
        y = min(y, visible.maxY - height - 8)
        y = max(y, visible.minY + 8)
        let maxX = max(8, textWidth - width - 8)
        return CGPoint(x: min(max(8, left), maxX), y: y)
    }

    /// How far to scroll down (up when negative) to show `anchor`, the lines of an annotation, and
    /// with it `card`, its card, when both fit: `visible` is the part of the document on screen, kept
    /// `topMargin` and `bottomMargin` clear of its edges. Nothing moves when the span is already in view;
    /// when it is too tall, the top of the anchor wins.
    public static func revealDelta(anchor: (top: CGFloat, bottom: CGFloat), card: (top: CGFloat, bottom: CGFloat)?,
                                   visible: CGRect, topMargin: CGFloat, bottomMargin: CGFloat) -> CGFloat {
        let upper = visible.minY + topMargin, lower = visible.maxY - bottomMargin
        var span = anchor
        if let card {
            let both = (top: min(anchor.top, card.top), bottom: max(anchor.bottom, card.bottom))
            if both.bottom - both.top <= lower - upper { span = both }
        }
        if span.top < upper { return span.top - upper }
        if span.bottom > lower { return min(span.bottom - lower, span.top - upper) }
        return 0
    }

    /// Where the Comment button of `width` × `height` goes for a selection whose first line runs from
    /// `top` to `bottom`, between `left` and `right`: above it, centred, or below it when there is no
    /// room above, near the top of `visible`. Kept inside the text column, `textWidth` wide.
    public static func adderOrigin(width: CGFloat, height: CGFloat, left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat,
                                   visible: CGRect, textWidth: CGFloat) -> CGPoint {
        let centre = (left + right) / 2
        let above = top - 8 - height
        let y = above < visible.minY + 8 ? bottom + 8 : above
        let x = min(max(8, centre - width / 2), max(8, textWidth - width - 8))
        return CGPoint(x: x, y: y)
    }
}
