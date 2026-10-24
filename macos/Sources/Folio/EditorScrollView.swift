import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the window shows of the document: the rendered preview, or the markdown source.
enum EditorMode {
    case preview, source
}

/// Scrolls the text and the comments pane beside it: they share one coordinate space and scroll
/// together. The text is the preview or the source editor, each as tall as its text.
final class EditorScrollView: NSScrollView {
    private let canvas = FlippedView()
    let source: SourceEditorView
    let preview: PreviewView
    /// The cards of the comments pane (see `AnnotationController`).
    let gutter = AnnotationGutterView()

    /// What is showing; the other one is hidden.
    var mode: EditorMode = .preview {
        didSet {
            guard mode != oldValue else { return }
            preview.isHidden = mode == .source
            source.isHidden = mode == .preview
            fit()
        }
    }

    /// How tall the text is.
    var contentHeight: CGFloat { mode == .source ? source.frame.height : preview.frame.height }

    /// How much of the width the pane takes now, 0 closed to `AnnotationStyle.paneWidth` open.
    /// The text gets the rest, so it reflows as the pane slides.
    private(set) var paneWidth: CGFloat = 0
    private var paneTarget: CGFloat = 0
    private var paneTimer: Timer?
    /// How far down the cards reach, which can be past the end of the text.
    private var gutterExtent: CGFloat = 0

    /// The pane moved or the window resized: cards beside the text may have to move.
    var onPaneLayout: (() -> Void)?

    init(source: SourceEditorView, preview: PreviewView) {
        self.source = source
        self.preview = preview
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        borderType = .noBorder
        documentView = canvas
        canvas.addSubview(preview)
        canvas.addSubview(source)
        canvas.addSubview(gutter)
        gutter.isHidden = true
        source.isHidden = true
        source.onHeightChange = { [weak self] _ in self?.fit() }
        preview.onHeightChange = { [weak self] _ in self?.fit() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where things that float over the text go (the open card, the comment button, the form).
    var floatingHost: NSView { canvas }

    /// The width the text has.
    var textWidth: CGFloat { max(0, contentSize.width - paneWidth) }

    /// The part of the document on screen, in the document's coordinates.
    var visibleDocumentRect: NSRect { contentView.bounds }

    /// The cards reach down to `extent`; the document is at least that tall.
    func setGutterExtent(_ extent: CGFloat) {
        guard extent != gutterExtent else { return }
        gutterExtent = extent
        fit()
    }

    override func tile() {
        super.tile()
        fit()
    }

    private func fit() {
        let textHeight = mode == .source
            ? source.layoutContent(width: textWidth, minHeight: contentSize.height)
            : preview.layoutContent(width: textWidth, minHeight: contentSize.height)
        let size = NSSize(width: contentSize.width, height: max(textHeight, gutterExtent))
        if canvas.frame.size != size { canvas.frame = NSRect(origin: .zero, size: size) }
        gutter.frame = NSRect(x: contentSize.width - paneWidth, y: 0, width: AnnotationStyle.gutterWidth, height: size.height)
        gutter.isHidden = paneWidth <= 0
    }

    // MARK: the pane

    /// Opens or closes the pane, sliding it like the window's sidebar.
    func setPane(open: Bool, animated: Bool = true) {
        let target = open ? AnnotationStyle.paneWidth : 0
        guard target != paneTarget else { return }
        paneTarget = target
        paneTimer?.invalidate()
        guard animated else {
            paneWidth = target
            fit()
            onPaneLayout?()
            return
        }
        let from = paneWidth
        let start = Date()
        let duration = 0.25
        paneTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, Date().timeIntervalSince(start) / duration)
            // Ease in and out, like the sidebar.
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            paneWidth = from + (target - from) * CGFloat(eased)
            fit()
            onPaneLayout?()
            if t >= 1 { timer.invalidate() }
        }
    }

    // MARK: scrolling

    /// Scroll so the rectangle (top and bottom in the canvas's coordinates) is on screen.
    func reveal(top: CGFloat, bottom: CGFloat) {
        canvas.scrollToVisible(NSRect(x: 0, y: top - 24, width: 1, height: bottom - top + 48))
    }

    var scrollOffset: CGFloat { contentView.bounds.origin.y }

    private var scrollableHeight: CGFloat { max(0, canvas.frame.height - contentSize.height) }

    /// Where the window is in the document, 0 at the top and 1 at the end. It carries a
    /// position across a change of layout (a file switch, the source/preview toggle).
    var scrollFraction: CGFloat { scrollableHeight > 0 ? scrollOffset / scrollableHeight : 0 }

    func scroll(toFraction fraction: CGFloat) {
        contentView.scroll(to: NSPoint(x: 0, y: (fraction * scrollableHeight).rounded()))
        reflectScrolledClipView(contentView)
    }
}
