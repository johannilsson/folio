import AppKit

/// The round send button of a reply or comment field: grey while empty, dark once there is text.
private final class SendButton: NSView {
    var ready = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func draw(_ dirtyRect: NSRect) {
        (ready ? NSColor.secondaryLabelColor : NSColor.separatorColor).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: "Send")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        let tint = ready ? NSColor.windowBackgroundColor : NSColor.tertiaryLabelColor
        image?.tinted(tint).draw(in: NSRect(x: (bounds.width - 12) / 2, y: (bounds.height - 12) / 2, width: 12, height: 12))
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return copy
    }
}

/// An avatar and a rounded field with a send button: where a reply or a new comment is typed.
/// ⌘↩ sends too.
final class ReplyBoxView: NSView {
    let textView = GrowingTextView()
    var onSend: ((String) -> Void)?
    /// The field changed height, so what holds it has to lay out again.
    var onResize: (() -> Void)?

    private let avatar = AvatarView(name: "me")
    private let send = SendButton()
    private var focused = false

    init(placeholder: String) {
        super.init(frame: .zero)
        textView.placeholder = placeholder
        textView.onChange = { [weak self] in
            guard let self else { return }
            send.ready = !trimmed.isEmpty
            onResize?()
            needsDisplay = true
        }
        textView.onSubmit = { [weak self] in self?.submit() }
        textView.onFocusChange = { [weak self] focused in
            self?.focused = focused
            self?.needsDisplay = true
        }
        send.onClick = { [weak self] in self?.submit() }
        send.setAccessibilityIdentifier("send")
        send.setAccessibilityLabel("Send")
        addSubview(avatar)
        addSubview(textView)
        addSubview(send)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var trimmed: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    private static let fieldInset: CGFloat = 38
    private static let sideInsets: (left: CGFloat, right: CGFloat) = (14, 40)

    private func textWidth(_ width: CGFloat) -> CGFloat {
        width - Self.fieldInset - Self.sideInsets.left - Self.sideInsets.right
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        max(36, textView.fittingHeight(width: textWidth(width)) + 18)
    }

    func layoutContent(width: CGFloat) {
        let height = fittingHeight(width: width)
        frame.size = NSSize(width: width, height: height)
        avatar.frame.origin = NSPoint(x: 0, y: 4)
        let textH = textView.fittingHeight(width: textWidth(width))
        textView.frame = NSRect(x: Self.fieldInset + Self.sideInsets.left, y: (height - textH) / 2,
                                width: textWidth(width), height: textH)
        send.frame = NSRect(x: width - 31, y: height - 31, width: 26, height: 26)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let field = NSRect(x: Self.fieldInset, y: 0, width: bounds.width - Self.fieldInset, height: bounds.height)
        let path = NSBezierPath(roundedRect: field.insetBy(dx: 0.5, dy: 0.5), xRadius: 18, yRadius: 18)
        path.lineWidth = focused ? 1.5 : 1
        (focused ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    func submit() {
        guard !trimmed.isEmpty else { return }
        onSend?(trimmed)
    }

    /// Empties the field once what was typed has been kept.
    func clear() {
        textView.clear()
        send.ready = false
    }
}

/// The comment text being edited in place, with Cancel and Save.
final class EditBoxView: NSView {
    let textView = GrowingTextView()
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onResize: (() -> Void)?

    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let save = NSButton(title: "Save", target: nil, action: nil)

    init(text: String) {
        super.init(frame: .zero)
        textView.string = text
        textView.onChange = { [weak self] in self?.onResize?() }
        textView.onSubmit = { [weak self] in self?.commit() }
        textView.onCancel = { [weak self] in self?.onCancel?() }
        for (button, id, action) in [(cancel, "cancel-edit", #selector(cancelClicked)), (save, "save-edit", #selector(saveClicked))] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
            addSubview(button)
        }
        save.keyEquivalent = ""
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc private func cancelClicked() { onCancel?() }
    @objc private func saveClicked() { commit() }
    private func commit() { onSave?(textView.string.trimmingCharacters(in: .whitespacesAndNewlines)) }

    private static let buttonRow: CGFloat = 24

    func fittingHeight(width: CGFloat) -> CGFloat {
        textView.fittingHeight(width: width - 14) + 12 + 6 + Self.buttonRow
    }

    func layoutContent(width: CGFloat) {
        let textH = textView.fittingHeight(width: width - 14)
        frame.size = NSSize(width: width, height: textH + 12 + 6 + Self.buttonRow)
        textView.frame = NSRect(x: 7, y: 6, width: width - 14, height: textH)
        let y = textH + 12 + 6
        save.sizeToFit()
        cancel.sizeToFit()
        save.frame.origin = NSPoint(x: width - save.frame.width, y: y)
        cancel.frame.origin = NSPoint(x: save.frame.minX - 6 - cancel.frame.width, y: y)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: 0, y: 0, width: bounds.width, height: textView.frame.height + 12)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.separatorColor.setStroke()
        path.stroke()
    }
}

/// What the buttons and fields of a card do; the controller supplies them.
struct AnnotationCardHandlers {
    var focus: (String) -> Void = { _ in }
    /// Accept a suggestion (apply it to the text).
    var accept: (String) -> Void = { _ in }
    /// Reject a suggestion or dismiss a comment.
    var resolve: (String) -> Void = { _ in }
    var saveEdit: (String, String) -> Bool = { _, _ in true }
    var reply: (String, String) -> Bool = { _, _ in true }
    /// Something changed the card's height.
    var relayout: () -> Void = {}
}

/// One annotation with its thread: the card in the comments pane, and the one that opens next
/// to the text when the pane is closed.
final class AnnotationCardView: NSView {
    private(set) var annotation: Annotation
    var handlers = AnnotationCardHandlers()

    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            rebuild()
            handlers.relayout()
        }
    }
    /// Not found in the document, so there is nowhere to put it: parked at the end.
    var isUnanchored = false {
        didSet { if isUnanchored != oldValue { rebuild() } }
    }
    /// Open next to the text rather than in the comments pane: lifted off the page with a shadow.
    var isFloating = false {
        didSet {
            guard isFloating != oldValue else { return }
            layer?.shadowOpacity = isFloating ? 0.25 : 0
            needsDisplay = true
        }
    }

    let replyBox = ReplyBoxView(placeholder: "Reply…")
    private var editor: EditBoxView?

    private struct Entry {
        var avatar: AvatarView
        var name: PassthroughLabel
        var time: PassthroughLabel
        var bodies: [PassthroughLabel]
        /// A rule above the second body: a suggestion's comment under its summary.
        var ruled: Bool
        var isComment: Bool
    }

    private var entries: [Entry] = []
    private var badge: PassthroughLabel?
    private var accept: ClosureButton?
    private var more: ClosureButton?
    /// Where the thread line goes between entries, in card coordinates: (x, from, to).
    private var lines: [(CGFloat, CGFloat, CGFloat)] = []
    private var rules: [CGRect] = []

    init(annotation: Annotation) {
        self.annotation = annotation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        setAccessibilityIdentifier("annotation-card")
        setAccessibilityElement(true)
        setAccessibilityLabel(annotation.summary)
        replyBox.onSend = { [weak self] text in
            guard let self else { return }
            if handlers.reply(annotation.id, text) { replyBox.clear() }
        }
        replyBox.onResize = { [weak self] in self?.handlers.relayout() }
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(_ annotation: Annotation) {
        guard annotation != self.annotation else { return }
        // An edit in progress belongs to the text it started from.
        if annotation.comment != self.annotation.comment { editor?.removeFromSuperview(); editor = nil }
        self.annotation = annotation
        setAccessibilityLabel(annotation.summary)
        rebuild()
    }

    // MARK: building

    private func label(_ text: NSAttributedString) -> PassthroughLabel {
        PassthroughLabel(text)
    }

    private func entry(name: String, created: String, bodies: [NSAttributedString], ruled: Bool, isComment: Bool = false) -> Entry {
        let who = AnnotationStyle.displayName(name)
        let nameLabel = label(NSAttributedString(string: who, attributes: [
            .font: AnnotationStyle.authorFont, .foregroundColor: NSColor.labelColor,
        ]))
        let timeLabel = label(NSAttributedString(string: AnnotationStyle.time(created), attributes: [
            .font: AnnotationStyle.timeFont, .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        for l in [nameLabel, timeLabel] { l.maximumNumberOfLines = 1; l.lineBreakMode = .byTruncatingTail }
        return Entry(avatar: AvatarView(name: name), name: nameLabel, time: timeLabel,
                     bodies: bodies.map(label), ruled: ruled, isComment: isComment)
    }

    private func rebuild() {
        for entry in entries {
            for view in [entry.avatar, entry.name, entry.time] + entry.bodies { view.removeFromSuperview() }
        }
        [badge, accept, more].forEach { $0?.removeFromSuperview() }
        entries = []

        if isUnanchored {
            badge = label(NSAttributedString(string: "Not found in document", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            addSubview(badge!)
        } else {
            badge = nil
        }
        alphaValue = isUnanchored ? 0.65 : 1

        let primary: [NSAttributedString]
        if annotation.isComment {
            primary = [AnnotationStyle.markdown(annotation.comment ?? "", font: AnnotationStyle.bodyFont, color: .secondaryLabelColor)]
        } else {
            var texts = [NSAttributedString(string: annotation.summary, attributes: bodyAttributes(.secondaryLabelColor))]
            if let comment = annotation.comment, !comment.isEmpty {
                texts.append(AnnotationStyle.markdown(comment, font: AnnotationStyle.bodyFont, color: .tertiaryLabelColor, italic: true))
            }
            primary = texts
        }
        entries.append(entry(name: annotation.author, created: annotation.created, bodies: primary,
                             ruled: !annotation.isComment && primary.count > 1, isComment: annotation.isComment))
        for reply in annotation.replies ?? [] {
            entries.append(entry(name: reply.author, created: reply.created,
                                 bodies: [AnnotationStyle.markdown(reply.body, font: AnnotationStyle.bodyFont, color: .secondaryLabelColor)],
                                 ruled: false))
        }
        for entry in entries {
            for view in [entry.avatar, entry.name, entry.time] + entry.bodies { addSubview(view) }
        }
        buildActions()

        if isFocused { addSubview(replyBox) } else { replyBox.removeFromSuperview() }
        if let editor { addSubview(editor) }
        needsLayout = true
        needsDisplay = true
    }

    private func bodyAttributes(_ color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        return [.font: AnnotationStyle.bodyFont, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private func buildActions() {
        let isComment = annotation.isComment
        let accept = ClosureButton(symbol: "checkmark", description: isComment ? "Resolve" : "Accept", identifier: "accept")
        accept.onClick = { [weak self] in
            guard let self else { return }
            if annotation.isComment { handlers.resolve(annotation.id) } else { handlers.accept(annotation.id) }
        }
        let more = ClosureButton(symbol: "ellipsis", description: "More", identifier: "more")
        more.onClick = { [weak self, weak more] in
            guard let self, let more else { return }
            showMenu(from: more)
        }
        addSubview(accept)
        addSubview(more)
        self.accept = accept
        self.more = more
    }

    private func showMenu(from button: NSView) {
        let menu = NSMenu()
        let edit = menu.addItem(withTitle: "Edit comment", action: #selector(editComment), keyEquivalent: "")
        edit.target = self
        let delete = menu.addItem(withTitle: "Delete", action: #selector(deleteAnnotation), keyEquivalent: "")
        delete.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func deleteAnnotation() { handlers.resolve(annotation.id) }

    @objc func editComment() {
        guard editor == nil else { return }
        let box = EditBoxView(text: annotation.comment ?? "")
        box.onResize = { [weak self] in self?.handlers.relayout() }
        box.onCancel = { [weak self] in self?.endEdit() }
        box.onSave = { [weak self] text in
            guard let self else { return }
            if handlers.saveEdit(annotation.id, text) { endEdit() }
        }
        editor = box
        rebuild()
        handlers.relayout()
        window?.makeFirstResponder(box.textView)
    }

    private func endEdit() {
        editor?.removeFromSuperview()
        editor = nil
        rebuild()
        handlers.relayout()
    }

    // MARK: layout

    private static let mainX = AnnotationStyle.cardPadding + AnnotationStyle.avatarSize + 10

    /// Lays the card out at `width` and sets its size; returns the height.
    @discardableResult
    func layoutContent(width: CGFloat) -> CGFloat {
        let pad = AnnotationStyle.cardPadding
        let mainW = width - pad - Self.mainX
        var y = pad
        lines = []
        rules = []

        if let badge {
            badge.frame = NSRect(x: pad, y: y, width: width - 2 * pad, height: 13)
            y += 13 + 6
        }

        for (index, entry) in entries.enumerated() {
            let top = y
            entry.avatar.frame.origin = NSPoint(x: pad, y: top)

            entry.name.sizeToFit()
            entry.time.sizeToFit()
            let actionsW: CGFloat = index == 0 ? 48 : 0
            let nameW = min(entry.name.frame.width, mainW - actionsW - entry.time.frame.width - 6)
            entry.name.frame = NSRect(x: Self.mainX, y: top, width: max(nameW, 20), height: entry.name.frame.height)
            entry.time.frame = NSRect(x: entry.name.frame.maxX + 6, y: top + 2, width: entry.time.frame.width, height: entry.time.frame.height)

            var bodyY = top + 20
            for (i, body) in entry.bodies.enumerated() {
                let isEditedBody = editor != nil && index == 0 && ((entry.isComment && i == 0) || (!entry.isComment && i == 1))
                if entry.ruled && i == 1 {
                    rules.append(CGRect(x: Self.mainX, y: bodyY + 2, width: mainW, height: 1))
                    bodyY += 7
                }
                if isEditedBody {
                    body.isHidden = true
                    editor!.layoutContent(width: mainW)
                    editor!.frame.origin = NSPoint(x: Self.mainX, y: bodyY)
                    bodyY += editor!.frame.height + 2
                    continue
                }
                body.isHidden = false
                let h = AnnotationStyle.height(of: body.attributedStringValue, width: mainW)
                body.frame = NSRect(x: Self.mainX, y: bodyY, width: mainW, height: h)
                bodyY += h + 2
            }
            // A suggestion with no comment still offers to add one while editing.
            if editor != nil, index == 0, !entry.isComment, entry.bodies.count == 1 {
                editor!.layoutContent(width: mainW)
                editor!.frame.origin = NSPoint(x: Self.mainX, y: bodyY)
                bodyY += editor!.frame.height + 2
            }
            let bottom = max(top + AnnotationStyle.avatarSize, bodyY - 2)

            let isLast = index == entries.count - 1
            if !isLast {
                lines.append((pad + 13, top + 34, bottom + 12 - 4))
            } else if isFocused {
                lines.append((pad + 13, top + 34, bottom + 12 + 6))
            }
            y = bottom + (isLast && !isFocused ? 0 : 12)
        }

        if let accept, let more {
            more.frame = NSRect(x: width - pad - 22, y: pad - 1, width: 22, height: 22)
            accept.frame = NSRect(x: more.frame.minX - 22, y: pad - 1, width: 22, height: 22)
        }

        if isFocused {
            replyBox.layoutContent(width: width - 2 * pad)
            replyBox.frame.origin = NSPoint(x: pad, y: y)
            y += replyBox.frame.height
        }

        let height = y + pad
        frame.size = NSSize(width: width, height: height)
        needsDisplay = true
        return height
    }

    override func layout() {
        super.layout()
        if frame.width > 0 { layoutContent(width: frame.width) }
    }

    // MARK: drawing and events

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (isFloating ? AnnotationStyle.floatFill : AnnotationStyle.cardFill).setFill()
        path.fill()
        if isFocused {
            path.lineWidth = 1
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        NSColor.separatorColor.setFill()
        for (x, from, to) in lines where to > from { NSRect(x: x, y: from, width: 1, height: to - from).fill() }
        for rule in rules { rule.fill() }
    }

    override func mouseDown(with event: NSEvent) {
        handlers.focus(annotation.id)
        if isFocused { window?.makeFirstResponder(replyBox.textView) }
    }

    override var allowsVibrancy: Bool { false }
}

/// The form for a new comment: a title and a reply-style field. It sits in the comments pane
/// among the cards, or next to the text when the pane is closed.
final class NewCommentView: NSView {
    let field = ReplyBoxView(placeholder: "Add a comment…")
    var onSend: ((String) -> Void)? {
        didSet { field.onSend = onSend }
    }
    var onCancel: (() -> Void)? {
        didSet { field.textView.onCancel = onCancel }
    }
    var onResize: (() -> Void)?

    private let title = PassthroughLabel(NSAttributedString(string: "New comment", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor,
    ]))

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowRadius = 8
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.masksToBounds = false
        setAccessibilityIdentifier("new-comment")
        addSubview(title)
        addSubview(field)
        field.onResize = { [weak self] in self?.onResize?() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Next to the text rather than among the cards, so it is lifted off the page with a shadow.
    var isFloating = false {
        didSet {
            layer?.shadowOpacity = isFloating ? 0.25 : 0
            needsDisplay = true
        }
    }

    @discardableResult
    func layoutContent(width: CGFloat) -> CGFloat {
        let pad = AnnotationStyle.cardPadding
        title.sizeToFit()
        title.frame.origin = NSPoint(x: pad, y: pad)
        field.layoutContent(width: width - 2 * pad)
        field.frame.origin = NSPoint(x: pad, y: pad + title.frame.height + 8)
        let height = field.frame.maxY + pad
        frame.size = NSSize(width: width, height: height)
        needsDisplay = true
        return height
    }

    override func layout() {
        super.layout()
        if frame.width > 0 { layoutContent(width: frame.width) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        (isFloating ? AnnotationStyle.floatFill : AnnotationStyle.cardFill).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }
}
