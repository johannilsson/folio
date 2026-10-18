import AppKit

/// The markdown source, edited in place: line numbers and a text view that is as tall as its text,
/// inside the window's scroll view. It saves a moment after typing stops, follows the file when
/// something else changes it, draws the annotations as highlights, and is the annotation UI's surface
/// while the source is showing (`AnnotationSurface`).
@MainActor
final class SourceEditorView: NSView, AnnotationSurface, NSTextViewDelegate, NSTextStorageDelegate {
    static let gutterWidth: CGFloat = 44
    private static let insets = NSSize(width: 8, height: 16)
    private static let saveDelay: TimeInterval = 0.3

    let textView = SourceTextView()
    private let lineNumbers = LineNumberView()
    private(set) var document: Document?

    /// The text is a different height now (typing, a reload); whoever scrolls it has to know.
    var onHeightChange: ((CGFloat) -> Void)?
    var onAnchors: (([AnchorRect]) -> Void)?
    var onSelection: ((SelectionInfo?) -> Void)?
    var onFocus: ((String?) -> Void)?
    var onPointer: (() -> Void)?

    private var saveTimer: Timer?
    /// Typed since the file was last written.
    private(set) var hasUnsavedEdits = false
    private var replacingText = false

    private var pending: [Annotation] = []
    /// Where each pending annotation is in the text, as UTF-16 ranges, kept right through edits.
    private(set) var ranges: [String: NSRange] = [:]
    private var pendingRange: (from: Int, to: Int)?
    private var flash: String?
    private var lastLayoutWidth: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.textContainerInset = Self.insets
        lineNumbers.textView = textView
        textView.onPointer = { [weak self] in self?.onPointer?() }
        textView.onClick = { [weak self] index in self?.clicked(at: index) }
        addSubview(lineNumbers)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: the document

    /// Shows `document`: a different file has its own text, history and annotations.
    func load(_ document: Document) {
        flushSave()
        self.document = document
        ranges = [:]
        pending = []
        pendingRange = nil
        replace(with: (try? document.readFile()) ?? "", keepingSelection: false)
        // Undo never reaches into the previous file.
        textView.history.removeAllActions()
        annotationsChanged([])
    }

    /// The file changed under us (an agent, `folio accept`): take the new text, unless typing is
    /// still waiting to be saved, which is about to overwrite it. Returns whether the text changed.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard !hasUnsavedEdits, let document, let text = try? document.readFile(), text != textView.string else { return false }
        replace(with: text, keepingSelection: true)
        // The history holds ranges of text that is gone.
        textView.history.removeAllActions()
        reanchor()
        runFlash()
        return true
    }

    /// Replaces the whole text without it counting as the reader's typing: no undo step, no save.
    private func replace(with text: String, keepingSelection: Bool) {
        let selection = textView.selectedRange()
        replacingText = true
        textView.textStorage?.replaceCharacters(in: NSRange(location: 0, length: (textView.string as NSString).length), with: text)
        textStyled()
        let length = (text as NSString).length
        textView.setSelectedRange(keepingSelection ? NSRange(location: min(selection.location, length), length: 0) : NSRange(location: 0, length: 0))
        replacingText = false
        hasUnsavedEdits = false
        relayout()
    }

    /// Writes typed text to the file now.
    func flushSave() {
        saveTimer?.invalidate()
        saveTimer = nil
        guard hasUnsavedEdits, let document else { return }
        hasUnsavedEdits = false
        try? document.writeFile(textView.string)
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushSave() }
        }
    }

    // MARK: text changes

    func textDidChange(_ notification: Notification) {
        guard !replacingText else { return }
        hasUnsavedEdits = true
        scheduleSave()
        textStyled()
        relayout()
        // Typing keeps the caret in view, wherever the edit came from.
        textView.scrollRangeToVisible(textView.selectedRange())
        reportAnchors()
        reportSelection()
    }

    /// Highlights, numbers the lines, and draws the annotations again: all that depends on the characters.
    private func textStyled() {
        guard let storage = textView.textStorage else { return }
        MarkdownHighlighter.apply(to: storage)
        var starts = [0]
        let text = storage.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            if enclosing.upperBound < text.length { starts.append(enclosing.upperBound) }
        }
        // A final newline starts one more (empty) line.
        if text.length > 0, text.character(at: text.length - 1) == 0x0A, starts.last != text.length { starts.append(text.length) }
        lineNumbers.lineStarts = starts
        applyMarks()
    }

    /// Edits move the annotations with the text they are about, as a text editor does.
    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                 range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !replacingText else { return }
            let oldEnd = editedRange.upperBound - delta
            func map(_ position: Int) -> Int {
                if position <= editedRange.location { return position }
                if position >= oldEnd { return position + delta }
                return editedRange.location + editedRange.length
            }
            ranges = ranges.mapValues { NSRange(location: map($0.location), length: max(0, map($0.upperBound) - map($0.location))) }
            if let pendingRange { self.pendingRange = (map(pendingRange.from), map(pendingRange.to)) }
        }
    }

    // MARK: layout

    /// Lays the text out at `width` and returns how tall it is (at least `minHeight`).
    @discardableResult
    func layoutContent(width: CGFloat, minHeight: CGFloat) -> CGFloat {
        lastLayoutWidth = width
        let textWidth = max(100, width - Self.gutterWidth)
        textView.frame = NSRect(x: Self.gutterWidth, y: 0, width: textWidth, height: max(textView.frame.height, 1))
        let height = contentHeight(minHeight: minHeight)
        textView.frame.size.height = height
        lineNumbers.frame = NSRect(x: 0, y: 0, width: Self.gutterWidth, height: height)
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        return height
    }

    private func contentHeight(minHeight: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return minHeight }
        layoutManager.ensureLayout(for: container)
        let used = max(layoutManager.usedRect(for: container).maxY, layoutManager.extraLineFragmentRect.maxY)
        // Room under the last line to scroll past, as the web editor had.
        return max(minHeight, ceil(used + 2 * Self.insets.height + 16))
    }

    /// The text changed its height: the frame follows, and so does the scroll view.
    private func relayout() {
        guard lastLayoutWidth > 0 else { return }
        let before = frame.height
        let height = contentHeight(minHeight: 0)
        guard abs(height - before) > 0.5 else { return }
        textView.frame.size.height = height
        lineNumbers.frame.size.height = height
        frame.size.height = height
        onHeightChange?(height)
    }

    // MARK: annotations on the text

    func annotationsChanged(_ pending: [Annotation]) {
        self.pending = pending
        reanchor()
    }

    /// Anchors the pending annotations in the text as it is now, with the same matcher the CLI uses.
    func reanchor() {
        let items: [[String: Any]] = pending.map { annotation in
            var item: [String: Any] = ["id": annotation.id, "context_before": annotation.contextBefore]
            if let target = annotation.target { item["target"] = target }
            return item
        }
        var found: [String: NSRange] = [:]
        if !items.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: items),
           let answer = try? Rust.anchor(doc: textView.string, itemsJSON: String(decoding: data, as: UTF8.self), raw: true),
           let list = try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String, let from = (entry["char_from"] as? NSNumber)?.intValue,
                      let to = (entry["char_to"] as? NSNumber)?.intValue else { continue }
                found[id] = NSRange(location: from, length: max(0, to - from))
            }
        }
        ranges = found
        applyMarks()
        reportAnchors()
    }

    private static let purple = NSColor.systemPurple
    private static let red = NSColor.systemRed

    /// Draws each annotation over its text without touching the text: temporary attributes.
    private func applyMarks() {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        let whole = NSRange(location: 0, length: length)
        for key in [NSAttributedString.Key.backgroundColor, .strikethroughStyle, .strikethroughColor, .underlineStyle, .underlineColor] {
            layoutManager.removeTemporaryAttribute(key, forCharacterRange: whole)
        }
        func clamped(_ range: NSRange) -> NSRange? {
            let clipped = NSIntersectionRange(range, whole)
            return clipped.length > 0 ? clipped : nil
        }
        var inserts: [Int] = []
        for annotation in pending {
            guard let range = ranges[annotation.id] else { continue }
            switch annotation.kind {
            case "comment", "highlight":
                if let range = clamped(range) { layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.purple.withAlphaComponent(0.22), forCharacterRange: range) }
            case "replace", "delete":
                guard let range = clamped(range) else { continue }
                layoutManager.addTemporaryAttributes([
                    .backgroundColor: Self.red.withAlphaComponent(0.12),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: Self.red,
                ], forCharacterRange: range)
                if annotation.kind == "delete" {
                    layoutManager.addTemporaryAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue, .underlineColor: Self.red], forCharacterRange: range)
                }
            case "insert":
                inserts.append(range.location)
            default: break
            }
        }
        if let pendingRange, let range = clamped(NSRange(location: pendingRange.from, length: pendingRange.to - pendingRange.from)) {
            layoutManager.addTemporaryAttribute(.backgroundColor, value: Self.purple.withAlphaComponent(0.4), forCharacterRange: range)
        }
        textView.insertPoints = inserts
    }

    /// Where the character at `index` is, in this view's coordinates: the top and bottom of its
    /// line, and how far along that line it is.
    private func position(of index: Int) -> (top: Double, bottom: Double, left: Double)? {
        guard let layoutManager = textView.layoutManager, textView.string.utf16.count > 0 else { return nil }
        let length = textView.string.utf16.count
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        var x = layoutManager.location(forGlyphAt: glyph).x + line.minX + origin.x
        if index >= length { x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textView.textContainer!).maxX + origin.x }
        return (Double(textView.frame.minY + line.minY + origin.y), Double(textView.frame.minY + line.maxY + origin.y), Double(textView.frame.minX + x))
    }

    private func reportAnchors() {
        guard !replacingText else { return }
        let anchors: [AnchorRect] = pending.compactMap { annotation in
            guard let range = ranges[annotation.id], let spot = position(of: range.location) else { return nil }
            return AnchorRect(id: annotation.id, from: range.location, top: spot.top, bottom: spot.bottom, left: spot.left)
        }
        onAnchors?(anchors)
    }

    private func reportSelection() {
        guard !replacingText else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let first = position(of: range.location) else {
            onSelection?(nil)
            return
        }
        let text = textView.string as NSString
        let last = position(of: max(range.location, range.upperBound - 1)) ?? first
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let box = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let origin = textView.textContainerOrigin
        // Words an annotation is anchored by: the raw text, with 30 characters before it.
        let before = NSRange(location: max(0, range.location - 30), length: range.location - max(0, range.location - 30))
        onSelection?(SelectionInfo(
            from: range.location, to: range.upperBound, top: first.top, bottom: first.bottom, endBottom: last.bottom,
            left: Double(textView.frame.minX + box.minX + origin.x), right: Double(textView.frame.minX + box.maxX + origin.x),
            target: text.substring(with: range), contextBefore: text.substring(with: before)
        ))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportSelection()
    }

    /// A click on a character: the annotation there takes the focus, or none.
    private func clicked(at index: Int?) {
        guard let index else { onFocus?(nil); return }
        let hit = pending.first { annotation in
            guard let range = ranges[annotation.id] else { return false }
            return index >= range.location && index <= range.upperBound
        }
        onFocus?(hit?.id)
    }

    // MARK: AnnotationSurface

    var hasKeyboardFocus: Bool { window?.firstResponder === textView }

    func focusText() {
        window?.makeFirstResponder(textView)
    }

    func setPending(_ range: (from: Int, to: Int)?) {
        pendingRange = range
        applyMarks()
    }

    func select(annotation id: String) {
        guard let range = ranges[id] else { return }
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    func flush() async {
        flushSave()
    }

    func flashAfterReload(_ text: String) {
        flash = text
    }

    /// Briefly highlights the text an accepted suggestion put in.
    private func runFlash() {
        guard let text = flash, let layoutManager = textView.layoutManager else { return }
        flash = nil
        let found = (textView.string as NSString).range(of: text)
        guard found.location != NSNotFound else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.5), forCharacterRange: found)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.applyMarks()
        }
    }

    // MARK: undo

    var canUndo: Bool { textView.history.canUndo }
    var canRedo: Bool { textView.history.canRedo }

    func undo() { textView.history.undo() }
    func redo() { textView.history.redo() }

    // MARK: finding

    /// Selects the next (or previous) match of `text`, wrapping round. Returns whether there is one.
    @discardableResult
    func find(_ text: String, backwards: Bool) -> Bool {
        guard !text.isEmpty else { return false }
        let all = textView.string as NSString
        let selection = textView.selectedRange()
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let ahead = backwards ? NSRange(location: 0, length: selection.location) : NSRange(location: selection.upperBound, length: all.length - selection.upperBound)
        var found = all.range(of: text, options: options, range: ahead)
        if found.location == NSNotFound { found = all.range(of: text, options: options) }
        guard found.location != NSNotFound else { return false }
        textView.setSelectedRange(found)
        textView.scrollRangeToVisible(found)
        textView.showFindIndicator(for: found)
        return true
    }
}
