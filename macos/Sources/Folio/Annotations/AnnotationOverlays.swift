import AppKit
import FolioKit

/// The comments pane: a column of cards beside the text, each at the height of what it is
/// about. A card that would overlap the one above is pushed down.
final class AnnotationGutterView: NSView {
    override var isFlipped: Bool { true }

    /// Something to stack: a card, or the form for a new comment.
    struct Item {
        var view: NSView
        /// Where its text is, in page coordinates; nil when it is not found in the document.
        var anchor: CardLayout.Anchor?
    }

    /// Puts `items` in the pane, in document order (`CardLayout.stack`; one not found in the
    /// document is parked at `end`), and returns how far down they reach.
    /// Each has been laid out at `AnnotationStyle.cardWidth`.
    @discardableResult
    func stack(_ items: [Item], end: CGFloat) -> CGFloat {
        let keep = Set(items.map { ObjectIdentifier($0.view) })
        for view in subviews where !keep.contains(ObjectIdentifier(view)) { view.removeFromSuperview() }

        let stacked = CardLayout.stack(items.map { CardLayout.Card(anchor: $0.anchor, height: $0.view.frame.height) }, end: end)
        for (index, top) in stacked.placed {
            let view = items[index].view
            if view.superview !== self { addSubview(view) }
            view.frame.origin = NSPoint(x: 0, y: top)
        }
        return stacked.extent
    }

    /// Only the cards take the mouse: the empty column beside them belongs to nobody.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A floating pill: the Comment button over a selection.
final class CommentAdderView: NSView {
    var onClick: (() -> Void)?
    private let button = NSButton(title: "Comment", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 98, height: 32))
        wantsLayer = true
        shadow = NSShadow()
        AnnotationStyle.liftFloatingPill(layer)
        button.isBordered = false
        // The same text as the toast's message.
        button.attributedTitle = NSAttributedString(string: "Comment", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor,
        ])
        button.target = self
        button.action = #selector(clicked)
        button.setAccessibilityIdentifier("comment")
        button.frame = bounds
        addSubview(button)
        setAccessibilityIdentifier("comment-adder")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func clicked() { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        AnnotationStyle.drawFloatingPill(in: bounds)
    }

    /// The button does not take focus: the selection in the page has to stay selected.
    override var acceptsFirstResponder: Bool { false }
}

/// A short message with an optional Undo, shown for a few seconds after accepting or removing an
/// annotation, since the card and its highlight disappear at once.
final class ToastView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let undo = NSButton(title: "Undo", target: nil, action: nil)
    private var onUndo: (() -> Void)?
    private var timer: Timer?

    var message: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        AnnotationStyle.liftFloatingPill(layer)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        undo.isBordered = false
        undo.font = .systemFont(ofSize: 13, weight: .semibold)
        undo.contentTintColor = .controlAccentColor
        undo.target = self
        undo.action = #selector(undoClicked)
        undo.setAccessibilityIdentifier("toast-undo")
        addSubview(label)
        addSubview(undo)
        setAccessibilityIdentifier("toast")
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func undoClicked() {
        let action = onUndo
        hide()
        action?()
    }

    /// Shows the message, centred at `centerX` and `bottom` up from the bottom of `host`.
    func show(_ text: String, undo action: (() -> Void)?, in host: NSView, centerX: CGFloat, bottom: CGFloat) {
        onUndo = action
        label.stringValue = text
        label.sizeToFit()
        undo.isHidden = action == nil
        undo.sizeToFit()
        let padding: CGFloat = 16
        var width = label.frame.width + 2 * padding
        if action != nil { width += undo.frame.width + 12 }
        let height: CGFloat = 32
        frame = NSRect(x: centerX - width / 2, y: bottom, width: width, height: height)
        label.frame.origin = NSPoint(x: padding, y: (height - label.frame.height) / 2)
        undo.frame.origin = NSPoint(x: label.frame.maxX + 12, y: (height - undo.frame.height) / 2)
        if superview !== host { host.addSubview(self) }
        isHidden = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in self?.hide() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        isHidden = true
        onUndo = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        AnnotationStyle.drawFloatingPill(in: bounds)
    }
}
