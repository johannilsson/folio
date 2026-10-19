import AppKit

/// A text view that is as tall as its text, for the reply, comment and edit fields. It is not
/// in a scroll view: whoever lays it out asks `fittingHeight(width:)` and sets the frame.
final class GrowingTextView: NSTextView {
    var placeholder = ""
    /// ⌘↩.
    var onSubmit: (() -> Void)?
    /// Escape.
    var onCancel: (() -> Void)?
    /// The text changed, so the field may need a different height.
    var onChange: (() -> Void)?
    /// Gained or lost the keyboard, so the field around it can show it.
    var onFocusChange: ((Bool) -> Void)?

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
        font = AnnotationStyle.bodyFont
        textColor = .labelColor
        insertionPointColor = .labelColor
        // Markdown goes in this field: smart quotes and dashes would change what is typed.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        defaultParagraphStyle = paragraph
        typingAttributes = [.font: AnnotationStyle.bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 18 }
        textContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(18, ceil(layoutManager.usedRect(for: textContainer).height))
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        if isSubmit(event) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// ⌘↩ and ⌃↩ post what is typed; ⌃↩ would otherwise reach the window's accept shortcut first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isSubmit(event) else { return super.performKeyEquivalent(with: event) }
        onSubmit?()
        return true
    }

    private func isSubmit(_ event: NSEvent) -> Bool {
        event.keyCode == 36 && !event.modifierFlags.intersection([.command, .control]).isEmpty
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        placeholder.draw(at: NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y), withAttributes: [
            .font: AnnotationStyle.bodyFont, .foregroundColor: NSColor.placeholderTextColor,
        ])
    }

    /// Takes the text away, and the height it had.
    func clear() {
        string = ""
        needsDisplay = true
        onChange?()
    }
}

/// A button whose action is a closure.
final class ClosureButton: NSButton {
    var onClick: (() -> Void)?

    convenience init(symbol: String, description: String, identifier: String) {
        self.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        toolTip = description
        setAccessibilityIdentifier(identifier)
        setAccessibilityLabel(description)
        isBordered = false
        imagePosition = .imageOnly
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { onClick?() }

    /// Buttons act on the first click even when the window is behind; the page's did.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A label that lets clicks through to the card behind it.
final class PassthroughLabel: NSTextField {
    convenience init(_ text: NSAttributedString) {
        self.init(labelWithAttributedString: text)
        isSelectable = false
        lineBreakMode = .byWordWrapping
        maximumNumberOfLines = 0
        cell?.wraps = true
        cell?.isScrollable = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The round badge with a person's initials.
final class AvatarView: NSView {
    private let name: String

    init(name: String) {
        self.name = AnnotationStyle.displayName(name)
        super.init(frame: NSRect(x: 0, y: 0, width: AnnotationStyle.avatarSize, height: AnnotationStyle.avatarSize))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        AnnotationStyle.avatarColor(for: name).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let text = NSAttributedString(string: AnnotationStyle.initials(for: name), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}
