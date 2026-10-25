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
