import AppKit
import WebKit

/// The page never scrolls: it lays itself out at its full height and `EditorScrollView`
/// scrolls it. Vertical wheel events the web view receives go to the enclosing scroll view;
/// sideways ones stay with the page, where a wide table or code block scrolls itself.
final class ForwardingWebView: WKWebView {
    /// Gets key presses first: the annotation shortcuts, which the page no longer knows. Returns
    /// whether it used the key.
    var keyHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if keyHandler?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    /// Dragging a selection past the window's edge: the page has nothing of its own to
    /// scroll, so the scroll view does it.
    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        _ = superview?.autoscroll(with: event)
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the window shows of the document: the rendered preview, or the markdown source.
enum EditorMode {
    case preview, source
}

/// Scrolls the text and the comments pane beside it: they share one coordinate space and scroll
/// together. The text is the web view, which is exactly as tall as its page (see the `layout` op),
/// or the source editor, which is as tall as its text.
final class EditorScrollView: NSScrollView {
    private let canvas = FlippedView()
    private let web: WKWebView
    let source: SourceEditorView
    /// The cards of the comments pane (see `AnnotationController`).
    let gutter = AnnotationGutterView()

    /// What is showing; the other one is hidden.
    var mode: EditorMode = .preview {
        didSet {
            guard mode != oldValue else { return }
            web.isHidden = mode == .source
            source.isHidden = mode == .preview
            fit()
        }
    }

    /// How tall the text is: the page's reported height, or the source's.
    var contentHeight: CGFloat { mode == .source ? source.frame.height : pageHeight }
    private var pageHeight: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    /// A scroll position to hold while the page settles after a switch (it keeps growing
    /// as diagrams render, so each new height re-applies it until the deadline).
    private var restore: (fraction: CGFloat, deadline: Date)?

    /// How much of the width the pane takes now, 0 closed to `AnnotationStyle.paneWidth` open.
    /// The web view gets the rest, so the text reflows as the pane slides.
    private(set) var paneWidth: CGFloat = 0
    private var paneTarget: CGFloat = 0
    private var paneTimer: Timer?
    /// How far down the cards reach, which can be past the end of the text.
    private var gutterExtent: CGFloat = 0

    /// The visible height changed; the page sizes a short document to fill it.
    var onViewportHeight: ((CGFloat) -> Void)?
    /// The pane moved or the window resized: cards beside the text may have to move.
    var onPaneLayout: (() -> Void)?

    init(webView: WKWebView, source: SourceEditorView) {
        web = webView
        self.source = source
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        borderType = .noBorder
        documentView = canvas
        canvas.addSubview(webView)
        canvas.addSubview(source)
        canvas.addSubview(gutter)
        gutter.isHidden = true
        source.isHidden = true
        webView.autoresizingMask = []
        source.onHeightChange = { [weak self] _ in self?.fit() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where things that float over the text go (the open card, the comment button, the form).
    var floatingHost: NSView { canvas }

    /// The width the page has.
    var textWidth: CGFloat { max(0, contentSize.width - paneWidth) }

    /// The part of the document on screen, in the document's coordinates.
    var visibleDocumentRect: NSRect { contentView.bounds }

    /// The page reported its height; the web view is exactly that tall.
    func setContentHeight(_ height: CGFloat) {
        pageHeight = height
        fit()
        if let restore, Date() < restore.deadline { scroll(toFraction: restore.fraction) }
    }

    /// The cards reach down to `extent`; the document is at least that tall.
    func setGutterExtent(_ extent: CGFloat) {
        guard extent != gutterExtent else { return }
        gutterExtent = extent
        fit()
    }

    override func tile() {
        super.tile()
        fit()
        if viewportHeight != contentSize.height {
            viewportHeight = contentSize.height
            onViewportHeight?(viewportHeight)
        }
    }

    private func fit() {
        let textHeight: CGFloat
        if mode == .source {
            textHeight = source.layoutContent(width: textWidth, minHeight: contentSize.height)
        } else {
            textHeight = max(pageHeight, contentSize.height)
            web.frame = NSRect(x: 0, y: 0, width: textWidth, height: textHeight)
        }
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

    /// Scroll so the page's rectangle (top and bottom in page coordinates) is on screen.
    func reveal(top: CGFloat, bottom: CGFloat) {
        restore = nil
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

    /// Go to `fraction` now, and keep it while the page lays itself out again.
    func restoreScroll(_ fraction: CGFloat, for seconds: TimeInterval = 0.6) {
        restore = (fraction, Date().addingTimeInterval(seconds))
        scroll(toFraction: fraction)
    }

    /// The reader scrolled by hand: stop holding the old position.
    override func scrollWheel(with event: NSEvent) {
        restore = nil
        super.scrollWheel(with: event)
    }
}
