import AppKit
import FolioKit

/// The markdown source as an `NSTextView`. It is not in a scroll view of its own: the window's
/// `EditorScrollView` scrolls it with the comments pane beside it, so it is as tall as its text
/// (`SourceEditorView` sets the height) and its layout is whole-document (TextKit 1), which is
/// what the anchors, the line numbers and that height need.
final class SourceTextView: NSTextView {
    /// The mouse was pressed in the text, before the text view acts on it.
    var onPointer: (() -> Void)?
    /// The mouse was released: the character index under the caret, for a click that selected nothing.
    var onClick: ((Int?) -> Void)?
    /// The mouse moved over the text: the character under it, nil when it is not on a character.
    var onHover: ((Int?) -> Void)?
    /// A key press to offer the annotation shortcuts first. Returns whether it was used.
    var keyHandler: ((NSEvent) -> Bool)?

    /// The undo history of the source. The window has none of its own (the document has none on
    /// purpose), so the text view brings one; annotation actions taken while the source shows are
    /// registered in it too, so Undo goes back through typing and those actions in order.
    let history = UndoManager()
    override var undoManager: UndoManager? { history }

    /// Where a suggestion would be inserted (zero-width annotations): a marker is drawn there.
    var insertPoints: [Int] = [] {
        didSet { if insertPoints != oldValue { needsDisplay = true } }
    }

    /// The text a replace or insert would put in, and where: drawn in green after that point, over
    /// the text that follows on the line, without being part of the file.
    /// `strong` is the annotation in focus or under the mouse: its green is deeper.
    var suggestions: [(at: Int, text: String, strong: Bool)] = [] {
        didSet { needsDisplay = true }
    }

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        font = MarkdownHighlighter.regular
        textColor = .labelColor
        insertionPointColor = .labelColor
        // The file is markdown and code: nothing may be changed as it is typed.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        usesFindBar = false
        setAccessibilityIdentifier("source-editor")
        typingAttributes = [.font: MarkdownHighlighter.regular, .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: MarkdownHighlighter.paragraph]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// AppKit scrolls a text view's selection into view whenever the view is resized. This one is resized
    /// by the window (the pane sliding, room for inline cards), which must not scroll the window to the
    /// caret: the window is put back where it was.
    override func setFrameSize(_ newSize: NSSize) {
        let scrollView = enclosingScrollView
        let origin = scrollView?.contentView.bounds.origin
        super.setFrameSize(newSize)
        guard let scrollView, let origin, scrollView.contentView.bounds.origin != origin else { return }
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: keyboard

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // The window's menu would take ⌘B; here it is bold.
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command],
           window?.firstResponder === self {
            switch event.charactersIgnoringModifiers {
            case "b": toggleMarker("**"); return true
            case "i": toggleMarker("*"); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Wraps the selection in `marker` (`**` for bold), or unwraps it when it is already
    /// surrounded by it. With nothing selected, inserts a pair and puts the caret between.
    func toggleMarker(_ marker: String) {
        let text = string as NSString
        let selection = selectedRange()
        let width = (marker as NSString).length
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }

        if selection.length == 0 {
            insertText(marker + marker, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + width, length: 0))
            return
        }
        let beforeRange = NSRange(location: selection.location - width, length: width)
        let afterRange = NSRange(location: selection.upperBound, length: width)
        if beforeRange.location >= 0, afterRange.upperBound <= text.length,
           text.substring(with: beforeRange) == marker, text.substring(with: afterRange) == marker {
            // Unwrap: the later edit first, so the earlier range stays where it is.
            insertText("", replacementRange: afterRange)
            insertText("", replacementRange: beforeRange)
            setSelectedRange(NSRange(location: selection.location - width, length: selection.length))
            return
        }
        insertText(marker, replacementRange: NSRange(location: selection.upperBound, length: 0))
        insertText(marker, replacementRange: NSRange(location: selection.location, length: 0))
        setSelectedRange(NSRange(location: selection.location + width, length: selection.length))
    }

    // MARK: mouse

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

    // MARK: drawing

    /// A soft band behind the line the caret is on, and a marker where a suggestion would insert text.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer else { return }
        let origin = textContainerOrigin
        let selection = selectedRange()
        if selection.length == 0, window?.firstResponder === self, string.utf16.count > 0 || selection.location == 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(selection.location, max(0, string.utf16.count - 1)))
            var line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            if selection.location >= string.utf16.count, string.hasSuffix("\n") {
                line = layoutManager.extraLineFragmentRect
            }
            if !line.isEmpty {
                NSColor.selectedTextBackgroundColor.withAlphaComponent(0.12).setFill()
                NSRect(x: 0, y: line.minY + origin.y, width: bounds.width, height: line.height).intersection(rect).fill()
            }
        }
        for point in insertPoints where point <= string.utf16.count && string.utf16.count > 0 {
            let index = min(point, string.utf16.count - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            var x = layoutManager.location(forGlyphAt: glyph).x + line.minX + origin.x
            if point >= string.utf16.count {
                x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX + origin.x
            }
            NSColor.systemGreen.setFill()
            NSRect(x: x - 1, y: line.minY + origin.y + 3, width: 2, height: line.height - 6).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let layoutManager, let textContainer, string.utf16.count > 0 else { return }
        let origin = textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
            .foregroundColor: NSColor.systemGreen,
        ]
        for suggestion in suggestions where suggestion.at <= string.utf16.count {
            let text = suggestion.text.replacingOccurrences(of: "\n", with: " ")
            let index = min(suggestion.at, string.utf16.count - 1)
            let glyph = layoutManager.glyphIndexForCharacter(at: index)
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            var x = layoutManager.location(forGlyphAt: glyph).x + line.minX + origin.x
            if suggestion.at >= string.utf16.count {
                x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX + origin.x
            }
            let size = (text as NSString).size(withAttributes: attributes)
            let box = NSRect(x: x, y: line.minY + origin.y, width: size.width + 4, height: line.height)
            guard box.intersects(dirtyRect) else { continue }
            NSColor.textBackgroundColor.setFill()
            box.fill()
            NSColor.systemGreen.withAlphaComponent(suggestion.strong ? 0.3 : 0.15).setFill()
            box.fill()
            (text as NSString).draw(at: NSPoint(x: x + 2, y: box.minY + (box.height - size.height) / 2), withAttributes: attributes)
        }
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // The band follows the caret.
        needsDisplay = true
    }
}
