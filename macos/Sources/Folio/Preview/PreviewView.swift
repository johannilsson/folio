import AppKit
import FolioKit

/// The rendered markdown, drawn natively: a read-only text view built from the file's markdown
/// (`PreviewBuilder`), with the annotations drawn over it and the annotation UI's surface while the
/// preview is showing (`AnnotationSurface`). Anchoring and the words a comment is anchored by come
/// from Rust against the markdown itself; `PreviewText` maps between that and what is on screen.
@MainActor
final class PreviewView: NSView, AnnotationSurface {
    private static let insets = NSSize(width: 32, height: 24)
    /// The text column. A window wider than it leaves the rest at the sides, which only tables and
    /// pictures use.
    private static let column: CGFloat = 760

    let textView = PreviewTextView()
    private(set) var document: Document?

    /// The text is a different height now (a reload, a suggestion's preview); whoever scrolls it has to know.
    var onHeightChange: ((CGFloat) -> Void)?
    var onAnchors: (([AnchorRect]) -> Void)?
    var onSelection: ((SelectionInfo?) -> Void)?
    var onFocus: ((String?) -> Void)?
    var onPointer: (() -> Void)?

    private var markdown = ""
    private var base = PreviewText()
    private var model = PreviewText()
    /// The suggestions whose preview is in the text now: a rebuild only touches the text when these change.
    private var ghosts: [String] = []
    private var pending: [Annotation] = []
    /// Where each pending annotation is in the file (UTF-16), and in the text on screen.
    private var sourceRanges: [String: NSRange] = [:]
    private(set) var ranges: [String: NSRange] = [:]
    private var ghostRanges: [String: NSRange] = [:]
    private var pendingRange: (from: Int, to: Int)?
    private var flash: String?
    private var lastLayoutWidth: CGFloat = 0
    private var lastReportedWidth: CGFloat = 0
    /// How wide the text container is, and how far the text column is in from its sides.
    private var containerWidth: CGFloat = 0
    private var side: CGFloat = 0
    /// The `side` the paragraph styles of the text have now.
    private var appliedSide: CGFloat = 0
    private var rebuilding = false
    /// The pictures (images, diagrams) asked for and had, by `PreviewAsset.key`.
    private var requested: Set<String> = []
    private var pictures: [String: NSImage] = [:]
    /// Stand-ins for diagrams that did not draw.
    private var stand: [String: NSImage] = [:]
    /// What the page said of each block of code (`PreviewCode.key`), and which it has been asked about.
    private var tokens: [String: [(range: NSRange, scope: String)]] = [:]
    private var highlightRequested: Set<String> = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.delegate = self
        textView.onPointer = { [weak self] in self?.onPointer?() }
        textView.onClick = { [weak self] index in self?.clicked(at: index) }
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    // MARK: the document

    /// Shows `document`: a different file has its own text and annotations.
    func load(_ document: Document) {
        self.document = document
        markdown = ""
        pending = []
        pendingRange = nil
        setMarkdown((try? document.readFile()) ?? "")
        annotationsChanged([])
    }

    /// The file changed (an agent, an accept, the source editor): take the new text. Returns whether it changed.
    @discardableResult
    func reloadFromDisk() -> Bool {
        guard let document, let text = try? document.readFile(), text != markdown else { return false }
        setMarkdown(text)
        rebuild()
        runFlash()
        return true
    }

    private func setMarkdown(_ text: String) {
        markdown = text
        base = PreviewBuilder.build(text, base: document?.file.deletingLastPathComponent(), plantUML: AppConfig.renderPlantUML)
        ghosts = []
        model = base
        rebuilding = true
        textView.textStorage?.setAttributedString(base.text)
        rebuilding = false
        appliedSide = 0
        applyColumn()
        pruneCaches()
        loadPictures()
        loadHighlights()
        applyHighlights()
        fitPictures()
        // The new text is as tall as it is, whatever the last one was.
        relayout()
    }

    // MARK: layout

    /// Lays the text out at `width` and returns how tall it is (at least `minHeight`).
    @discardableResult
    func layoutContent(width: CGFloat, minHeight: CGFloat) -> CGFloat {
        let width = max(width, 200)
        lastLayoutWidth = width
        let inset = Self.insets
        if textView.textContainerInset != inset { textView.textContainerInset = inset }
        containerWidth = max(100, width - 2 * inset.width)
        side = max(0, (containerWidth - Self.column) / 2)
        textView.columnInset = side
        textView.frame = NSRect(x: 0, y: 0, width: width, height: max(textView.frame.height, 1))
        applyColumn()
        fitPictures()
        let before = frame.height
        let height = contentHeight(minHeight: minHeight)
        textView.frame.size.height = height
        frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Text that moved (a narrower column, a picture that now has its size) moves the cards with it.
        if abs(height - before) > 0.5 || width != lastReportedWidth {
            lastReportedWidth = width
            reportAnchors()
        }
        return height
    }

    // MARK: the text column

    /// Puts the text in its column: each paragraph is indented by `side` and stops short of the right
    /// side by as much, except the ones that may be wider (pictures) and the tables, whose width and
    /// left margin are set here too.
    private func applyColumn() {
        guard let storage = textView.textStorage else { return }
        let delta = side - appliedSide
        if abs(delta) > 0.01, storage.length > 0 {
            appliedSide = side
            let text = storage.string as NSString
            var changes: [(NSRange, NSParagraphStyle)] = []
            var at = 0
            while at < text.length {
                let paragraph = text.paragraphRange(for: NSRange(location: at, length: 0))
                at = paragraph.upperBound
                guard let style = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle,
                      style.textBlocks.isEmpty, storage.attribute(.folioCentered, at: paragraph.location, effectiveRange: nil) == nil,
                      let copy = style.mutableCopy() as? NSMutableParagraphStyle else { continue }
                copy.headIndent += delta
                copy.firstLineHeadIndent += delta
                if storage.attribute(.folioWide, at: paragraph.location, effectiveRange: nil) == nil { copy.tailIndent -= delta }
                copy.tabStops = style.tabStops.map { NSTextTab(textAlignment: $0.alignment, location: $0.location + delta, options: $0.options) }
                changes.append((paragraph, copy))
            }
            storage.beginEditing()
            for (range, style) in changes { storage.addAttribute(.paragraphStyle, value: style, range: range) }
            storage.endEditing()
        }
        // A table is at least as wide as the text (edge to edge with it), and as wide as its content
        // needs up to the window; a table wider than the text is centred in the window.
        let column = min(containerWidth, Self.column)
        for table in model.tables {
            let wanted = min(max(table.natural, column), containerWidth)
            // Never 0: a spacer of no width is left to the table's automatic layout, which gives it some.
            let margin = max(1, min(side, (containerWidth - wanted) / 2))
            let width = min(wanted, containerWidth - margin)
            guard table.applied != (margin, width) else { continue }
            table.applied = (margin, width)
            table.grid.setContentWidth(margin + width, type: .absoluteValueType)
            for block in table.spacers { block.setValue(margin, type: .absoluteValueType, for: .width) }
            textView.layoutManager?.invalidateLayout(forCharacterRange: NSRange(location: 0, length: storage.length), actualCharacterRange: nil)
        }
    }

    // MARK: pictures

    /// Asks for each picture of the text that is not here yet.
    private func loadPictures() {
        guard let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.folioAsset, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let asset = value as? PreviewAsset, requested.insert(asset.key).inserted else { return }
            Task { @MainActor [weak self] in
                if let image = await asset.load(dark: self?.isDark ?? false) {
                    self?.pictures[asset.key] = image
                } else {
                    // Not had (no network, a missing file): the next time the text is read it is asked for again.
                    self?.requested.remove(asset.key)
                    guard let image = asset.placeholder() else { return }
                    self?.stand[asset.key] = image
                }
                self?.fitPictures()
                self?.relayout()
                self?.reportAnchors()
            }
        }
    }

    // MARK: code colours

    /// Asks the page about each block of code that has a language and has not been asked about.
    private func loadHighlights() {
        guard let storage = textView.textStorage else { return }
        storage.enumerateAttribute(.folioCode, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let code = value as? PreviewCode, highlightRequested.insert(code.key).inserted else { return }
            Task { @MainActor [weak self] in
                let answer = await DiagramPage.shared.highlight(code.code, language: code.language)
                self?.tokens[code.key] = answer
                self?.applyHighlights()
            }
        }
    }

    /// Colours the code in the text with what the page said. Only whole blocks are touched: a
    /// block that something was put into (a suggestion's preview) is left plain.
    private func applyHighlights() {
        guard let storage = textView.textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.folioCode, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let code = value as? PreviewCode, let found = tokens[code.key], run.length == (code.code as NSString).length else { return }
            for token in found where token.range.upperBound <= run.length {
                guard let color = SyntaxColors.color(for: token.scope) else { continue }
                storage.addAttribute(.foregroundColor, value: color,
                                     range: NSRange(location: run.location + token.range.location, length: token.range.length))
            }
        }
        storage.endEditing()
    }

    /// Gives each loaded picture its size: its own, or the width of the text.
    private func fitPictures() {
        guard let storage = textView.textStorage, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let whole = max(100, containerWidth > 0 ? containerWidth : container.size.width)
        storage.enumerateAttribute(.folioAsset, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let asset = value as? PreviewAsset, let image = pictures[asset.key] ?? stand[asset.key], image.size.width > 0,
                  let attachment = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment else { return }
            // A picture in a block of its own may be wider than the text; one in a sentence is not.
            let wide = storage.attribute(.folioWide, at: range.location, effectiveRange: nil) != nil
            let centered = storage.attribute(.folioCentered, at: range.location, effectiveRange: nil) != nil
            let available = centered ? whole : (wide ? whole - side : min(whole, Self.column))
            // A diagram fills the window: up to twice its size and 800 points tall
            // when it is smaller, and the width of the window when it is larger. Images are never enlarged.
            let grow = centered && !asset.key.hasPrefix("image:") ? max(1, min(2, 800 / max(1, image.size.height))) : 1
            let scale = min(grow, available / image.size.width)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            if attachment.image !== image {
                attachment.image = image
                // Same size, other picture (a diagram drawn again): the text view has to paint it again.
                layoutManager.invalidateDisplay(forCharacterRange: range)
                textView.needsDisplay = true
            }
            if attachment.bounds.size != size {
                attachment.bounds = NSRect(origin: .zero, size: size)
                layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            }
        }
    }

    /// The picture of a kind that has loaded (`"mermaid:"`), for the self-test.
    func picture(_ kind: String) -> NSImage? {
        pictures.first { $0.key.hasPrefix(kind) }?.value
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Diagrams are drawn in a look, so a change of appearance draws them again.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let drawn = requested.filter { $0.hasPrefix("mermaid:") }
        guard !drawn.isEmpty else { return }
        requested.subtract(drawn)
        loadPictures()
    }

    /// Forgets the pictures and code colours of text that is gone: a long session of edits to a diagram
    /// would keep every version of it.
    private func pruneCaches() {
        guard let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var assets = Set<String>(), codes = Set<String>()
        storage.enumerateAttribute(.folioAsset, in: whole) { value, _, _ in
            if let asset = value as? PreviewAsset { assets.insert(asset.key) }
        }
        storage.enumerateAttribute(.folioCode, in: whole) { value, _, _ in
            if let code = value as? PreviewCode { codes.insert(code.key) }
        }
        requested.formIntersection(assets)
        pictures = pictures.filter { assets.contains($0.key) }
        stand = stand.filter { assets.contains($0.key) }
        highlightRequested.formIntersection(codes)
        tokens = tokens.filter { codes.contains($0.key) }
    }

    private func contentHeight(minHeight: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return minHeight }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).maxY
        // Room under the last line to scroll past.
        return max(minHeight, ceil(used + 2 * Self.insets.height + 16))
    }

    private func relayout() {
        guard lastLayoutWidth > 0 else { return }
        let before = frame.height
        let height = contentHeight(minHeight: 0)
        guard abs(height - before) > 0.5 else { return }
        textView.frame.size.height = height
        frame.size.height = height
        onHeightChange?(height)
    }

    // MARK: annotations on the text

    func annotationsChanged(_ pending: [Annotation]) {
        self.pending = pending
        rebuild()
    }

    /// Anchors the pending annotations in the file, puts the preview of suggestions into the text,
    /// and draws the marks. The text itself is only touched when a suggestion's preview changed.
    private func rebuild() {
        sourceRanges = TextSurface.anchor(pending, in: markdown)
        var inserts: [(location: Int, id: String, text: NSAttributedString)] = []
        for annotation in pending {
            guard let range = sourceRanges[annotation.id], let replacement = annotation.replacement, !replacement.isEmpty else { continue }
            let green = NSColor.systemGreen
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: PreviewBuilder.bodySize),
                .foregroundColor: green,
                .backgroundColor: green.withAlphaComponent(0.12),
                .folioGhost: annotation.id,
            ]
            switch annotation.kind {
            case .replace:
                guard let end = base.displayLocation(forSource: range.upperBound, end: true) else { continue }
                attributes[.paragraphStyle] = ghostStyle(at: end)
                inserts.append((end, annotation.id, NSAttributedString(string: replacement, attributes: attributes)))
            case .insert:
                guard let at = base.displayLocation(forSource: range.location, end: true) else { continue }
                attributes[.paragraphStyle] = ghostStyle(at: at)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attributes[.underlineColor] = green
                inserts.append((at, annotation.id, NSAttributedString(string: replacement, attributes: attributes)))
            default: break
            }
        }
        inserts.sort { $0.location > $1.location }
        let signature = inserts.map { "\($0.id)@\($0.location):\($0.text.string)" }
        if signature != ghosts {
            ghosts = signature
            var built = base
            // `text` is a reference: without a copy the previews would be written into `base` and stay there.
            built.text = NSMutableAttributedString(attributedString: base.text)
            for insert in inserts { built.insertGhost(insert.text, at: insert.location) }
            model = built
            let selection = textView.selectedRange()
            rebuilding = true
            textView.textStorage?.setAttributedString(model.text)
            textView.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: model.text.length)))
            rebuilding = false
            appliedSide = 0
            applyColumn()
            applyHighlights()
            fitPictures()
            relayout()
        }
        ghostRanges = [:]
        model.text.enumerateAttribute(.folioGhost, in: NSRange(location: 0, length: model.text.length)) { value, range, _ in
            if let id = value as? String { ghostRanges[id] = range }
        }
        ranges = [:]
        for annotation in pending {
            guard let range = sourceRanges[annotation.id] else { continue }
            if range.length == 0 {
                // A point (an insertion): where its preview starts.
                if let at = ghostRanges[annotation.id]?.location ?? model.displayLocation(forSource: range.location, end: true) {
                    ranges[annotation.id] = NSRange(location: at, length: 0)
                }
            } else if let shown = model.displayRange(forSource: range) {
                ranges[annotation.id] = shown
            }
        }
        applyMarks()
        reportAnchors()
        reportSelection()
    }

    /// The paragraph style for a suggestion's preview put in at `location`: that of the paragraph it goes into,
    /// so that the paragraphs a long suggestion adds are in the text column too (a paragraph with no style
    /// of its own runs from one side of the window to the other).
    private func ghostStyle(at location: Int) -> NSParagraphStyle? {
        let length = base.text.length
        guard length > 0 else { return nil }
        // The paragraph the text goes into: the one before the position, unless it is at the start of one.
        let text = base.text.string as NSString
        let index = location > 0 && text.character(at: location - 1) != 10 ? location - 1 : min(location, length - 1)
        guard let style = base.text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
              let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return nil }
        // A paragraph that starts inside the preview has no list marker to hang.
        copy.firstLineHeadIndent = copy.headIndent
        return copy
    }

    /// Draws each annotation over its text without touching the text.
    private func applyMarks() {
        let pendingText = pendingRange.flatMap { model.displayRange(forSource: NSRange(location: $0.from, length: $0.to - $0.from)) }
        TextSurface.applyMarks(in: textView, pending: pending, ranges: ranges, pendingRange: pendingText)
    }

    // MARK: reports

    private func reportAnchors() {
        guard !rebuilding else { return }
        let anchors: [AnchorRect] = pending.compactMap { annotation in
            guard let range = ranges[annotation.id], let spot = TextSurface.position(of: range.location, in: textView) else { return nil }
            return AnchorRect(id: annotation.id, from: sourceRanges[annotation.id]?.location ?? range.location,
                              top: spot.top, bottom: spot.bottom, left: spot.left)
        }
        onAnchors?(anchors)
    }

    private func reportSelection() {
        guard !rebuilding else { return }
        let range = textView.selectedRange()
        guard let inFile = model.sourceRange(forDisplay: range) else {
            onSelection?(nil)
            return
        }
        onSelection?(TextSurface.selection(in: textView, displayRange: range, fileRange: inFile, document: markdown))
    }

    /// A click on a character: the annotation there (or its suggested text) takes the focus, or none.
    private func clicked(at index: Int?) {
        guard let index else { onFocus?(nil); return }
        let suggested = pending.first { annotation in
            guard let ghost = ghostRanges[annotation.id] else { return false }
            return index >= ghost.location && index < ghost.upperBound
        }?.id
        onFocus?(TextSurface.annotation(at: index, in: pending, ranges: ranges) ?? suggested)
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

    func flush() async {}

    func flashAfterReload(_ text: String) {
        flash = text
    }

    /// Briefly highlights the text an accepted suggestion put in.
    private func runFlash() {
        guard let text = flash else { return }
        flash = nil
        TextSurface.flash(text, in: textView) { [weak self] in self?.applyMarks() }
    }
}

extension PreviewView {
    /// Selects the next (or previous) match of `text` in what is on screen, wrapping round. Returns whether there is one.
    /// A match in the preview of a suggestion is text that is not in the file: it is skipped.
    @discardableResult
    func find(_ text: String, backwards: Bool) -> Bool {
        TextSurface.find(text, backwards: backwards, in: textView) { [model] range in
            var ghost = false
            model.text.enumerateAttribute(.folioGhost, in: NSIntersectionRange(range, NSRange(location: 0, length: model.text.length))) { value, _, _ in
                if value != nil { ghost = true }
            }
            return ghost
        }
    }
}

extension PreviewView: NSTextViewDelegate {
    func textViewDidChangeSelection(_ notification: Notification) {
        reportSelection()
    }
}
