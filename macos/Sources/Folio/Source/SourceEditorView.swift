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
    /// The file as it was last read or written here: a save finds out from it whether someone
    /// else changed the file meanwhile.
    private var base = ""
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
    /// still waiting to be saved; the save then asks which to keep. Returns whether the text changed.
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
        base = text
        relayout()
    }

    /// Writes typed text to the file now. Returns whether it is saved: when the write fails, or
    /// someone else changed the file since it was read, the reader is told and the text stays
    /// unsaved, so an outside change does not replace it.
    @discardableResult
    func flushSave() -> Bool {
        saveTimer?.invalidate()
        saveTimer = nil
        guard hasUnsavedEdits, let document else { return true }
        if let onDisk = try? document.readFile(), onDisk != base, onDisk != textView.string {
            askAboutOutsideChange(onDisk)
            return false
        }
        do {
            try document.writeFile(textView.string)
            base = textView.string
            hasUnsavedEdits = false
            return true
        } catch {
            if let window, window.attachedSheet == nil {
                NSAlert(error: error).beginSheetModal(for: window)
            } else if window == nil {
                NSApp.presentError(error)
            }
            return false
        }
    }

    /// The file changed while typing waited to be saved: the reader keeps one of the two.
    private func askAboutOutsideChange(_ onDisk: String) {
        guard let document, window?.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "The file was changed by another program"
        alert.informativeText = "“\(document.file.lastPathComponent)” changed on disk while you were typing. Keep your version, or use the file as it is now?"
        alert.addButton(withTitle: "Keep Mine")
        alert.addButton(withTitle: "Use the File")
        let answer: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, self.document === document else { return }
            if response == .alertFirstButtonReturn {
                base = onDisk
                flushSave()
            } else {
                hasUnsavedEdits = false
                if !reloadFromDisk() { base = textView.string }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: answer) } else { answer(alert.runModal()) }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.flushSave() }
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
        ranges = TextSurface.anchor(pending, in: textView.string)
        applyMarks()
        reportAnchors()
    }

    /// Draws each annotation over its text without touching the text.
    private func applyMarks() {
        let pendingText = pendingRange.map { NSRange(location: $0.from, length: $0.to - $0.from) }
        textView.insertPoints = TextSurface.applyMarks(in: textView, pending: pending, ranges: ranges, pendingRange: pendingText)
    }

    private func reportAnchors() {
        guard !replacingText else { return }
        let anchors: [AnchorRect] = pending.compactMap { annotation in
            guard let range = ranges[annotation.id], let spot = TextSurface.position(of: range.location, in: textView) else { return nil }
            return AnchorRect(id: annotation.id, from: range.location, top: spot.top, bottom: spot.bottom, left: spot.left)
        }
        onAnchors?(anchors)
    }

    private func reportSelection() {
        guard !replacingText else { return }
        let range = textView.selectedRange()
        onSelection?(TextSurface.selection(in: textView, displayRange: range, fileRange: range, document: textView.string))
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportSelection()
    }

    /// A click on a character: the annotation there takes the focus, or none.
    private func clicked(at index: Int?) {
        guard let index else { onFocus?(nil); return }
        onFocus?(TextSurface.annotation(at: index, in: pending, ranges: ranges))
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
        guard let text = flash else { return }
        flash = nil
        TextSurface.flash(text, in: textView) { [weak self] in self?.applyMarks() }
    }

    /// Where each line starts, for the self-test.
    var lineStartsForTest: [Int] { lineNumbers.lineStarts }

    // MARK: undo

    var canUndo: Bool { textView.history.canUndo }
    var canRedo: Bool { textView.history.canRedo }

    func undo() { textView.history.undo() }
    func redo() { textView.history.redo() }

    // MARK: finding

    /// Selects the next (or previous) match of `text`, wrapping round. Returns whether there is one.
    @discardableResult
    func find(_ text: String, backwards: Bool) -> Bool {
        TextSurface.find(text, backwards: backwards, in: textView)
    }
}
