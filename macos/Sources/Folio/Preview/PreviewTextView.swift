import AppKit

/// A layout manager whose text backgrounds (inline code, marks, suggestions) stay where the text is:
/// the stock ones run to the edge of the line at a line break and a wrap, outside the text column.
final class PreviewLayoutManager: NSLayoutManager {
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int, forCharacterRange charRange: NSRange, color: NSColor) {
        // A table's cells are painted the same way and are not text: the stock fill.
        let style = textStorage?.attribute(.paragraphStyle, at: min(charRange.location, max(0, (textStorage?.length ?? 1) - 1)), effectiveRange: nil) as? NSParagraphStyle
        guard let container = textContainers.first, style?.textBlocks.isEmpty ?? true else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        // The rectangles are in the text view's coordinates; the layout is in the container's.
        let origin = firstTextView?.textContainerOrigin ?? .zero
        color.setFill()
        for index in 0..<rectCount {
            let rect = rectArray[index]
            // One rectangle may cover several lines (and the empty ones between paragraphs): each line on its own.
            let local = rect.offsetBy(dx: -origin.x, dy: -origin.y)
            enumerateLineFragments(forGlyphRange: glyphRange(forBoundingRect: local, in: container)) { line, used, _, _, _ in
                let top = max(local.minY, line.minY), bottom = min(local.maxY, line.maxY)
                let left = max(local.minX, used.minX), right = min(local.maxX, used.maxX)
                guard bottom > top, right > left else { return }
                NSRect(x: left + origin.x, y: top + origin.y, width: right - left, height: bottom - top).fill()
            }
        }
    }
}

/// The rendered document as an `NSTextView` the reader can select in but not edit. Like the source,
/// it is not in a scroll view of its own: `EditorScrollView` scrolls it with the comments pane, so it
/// is as tall as its text (`PreviewView` sets the height) and laid out whole (TextKit 1).
final class PreviewTextView: NSTextView {
    /// The mouse was pressed in the text, before the text view acts on it.
    var onPointer: (() -> Void)?
    /// The mouse was released: the character index under the caret, for a click that selected nothing.
    var onClick: ((Int?) -> Void)?
    /// The mouse moved over the text: the character under it, nil when it is not on a character.
    var onHover: ((Int?) -> Void)?
    /// A key press to offer the annotation shortcuts first. Returns whether it was used.
    var keyHandler: ((NSEvent) -> Bool)?

    /// How far the text column is in from each side of the text container: the text is a column in
    /// the middle, and tables and pictures may be wider than it. The blocks painted behind the text
    /// follow the column.
    var columnInset: CGFloat = 0 {
        didSet { if columnInset != oldValue { needsDisplay = true } }
    }

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let storage = NSTextStorage()
        let layout = PreviewLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        setAccessibilityIdentifier("preview")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// AppKit scrolls a text view's selection into view whenever the view is resized. This one is resized
    /// by the window (the pane sliding, room for inline cards), which must not scroll the window to the caret.
    private var resizing = false

    override func setFrameSize(_ newSize: NSSize) {
        resizing = true
        super.setFrameSize(newSize)
        resizing = false
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        resizing ? false : super.scrollToVisible(rect)
    }

    // MARK: blocks painted behind the text

    /// The frontmatter box, the background of code blocks, the bars beside quotes and the rules: what
    /// the text itself cannot draw, found by the attributes the builder put on the text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, let layoutManager, let container = textContainer, storage.length > 0 else { return }
        let origin = textContainerOrigin
        let left = origin.x + columnInset, right = origin.x + container.size.width - columnInset
        let whole = NSRange(location: 0, length: storage.length)
        func box(_ range: NSRange) -> NSRect {
            var found = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            found.origin.x += origin.x
            found.origin.y += origin.y
            return found
        }
        storage.enumerateAttribute(.folioBlock, in: whole) { value, range, _ in
            guard let kind = value as? String else { return }
            let found = box(range)
            switch kind {
            case "code", "box":
                let pad: CGFloat = 10
                // Both are the width of the text column: the bounding rect of a block can start further left (an empty line, a picture above).
                let area = NSRect(x: left, y: found.minY - pad, width: 0, height: found.height + 2 * pad)
                var drawn = area
                drawn.size.width = right - drawn.minX
                guard drawn.intersects(rect) else { return }
                NSColor.labelColor.withAlphaComponent(kind == "box" ? 0.05 : 0.06).setFill()
                NSBezierPath(roundedRect: drawn, xRadius: kind == "box" ? 10 : 6, yRadius: kind == "box" ? 10 : 6).fill()
            case "rule":
                guard found.insetBy(dx: -left, dy: -4).intersects(rect) else { return }
                NSColor.separatorColor.setFill()
                NSRect(x: left, y: found.midY - 0.5, width: right - left, height: 1).fill()
            default: break
            }
        }
        storage.enumerateAttribute(.folioQuote, in: whole) { value, range, _ in
            guard let depth = value as? Int, depth > 0 else { return }
            // A little past the text each way, so bars of neighbouring quotes join up.
            var found = box(range)
            found.origin.y -= 5
            found.size.height += 10
            guard found.intersects(rect.insetBy(dx: -left, dy: 0)) else { return }
            NSColor.tertiaryLabelColor.setFill()
            for level in 0..<depth {
                NSRect(x: left + CGFloat(level) * 18 + 4, y: found.minY, width: 3, height: found.height).fill()
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(TextSurface.character(at: convert(event.locationInWindow, from: nil), in: self))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        onPointer?()
        super.mouseDown(with: event)
        // super tracked the drag to its end: a click that selected nothing is a click on a character.
        let selection = selectedRange()
        onClick?(selection.length == 0 ? selection.location : nil)
    }
}
