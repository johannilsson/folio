import AppKit

/// The rendered document as an `NSTextView` the reader can select in but not edit. Like the source,
/// it is not in a scroll view of its own: `EditorScrollView` scrolls it with the comments pane, so it
/// is as tall as its text (`NativePreviewView` sets the height) and laid out whole (TextKit 1).
final class PreviewTextView: NSTextView {
    /// The mouse was pressed in the text, before the text view acts on it.
    var onPointer: (() -> Void)?
    /// The mouse was released: the character index under the caret, for a click that selected nothing.
    var onClick: ((Int?) -> Void)?
    /// A key press to offer the annotation shortcuts first. Returns whether it was used.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        usesFindBar = false
        setAccessibilityIdentifier("native-preview")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onPointer?()
        super.mouseDown(with: event)
        // super tracked the drag to its end: a click that selected nothing is a click on a character.
        let selection = selectedRange()
        onClick?(selection.length == 0 ? selection.location : nil)
    }
}
