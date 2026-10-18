import AppKit
import WebKit

/// The page never scrolls: it lays itself out at its full height and `EditorScrollView`
/// scrolls it. Vertical wheel events the web view receives go to the enclosing scroll view;
/// sideways ones stay with the page, where a wide table or code block scrolls itself.
final class ForwardingWebView: WKWebView {
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

/// Scrolls the web view, which is exactly as tall as its page (see the `layout` op).
final class EditorScrollView: NSScrollView {
    private let canvas = FlippedView()
    private let web: WKWebView
    private(set) var contentHeight: CGFloat = 0
    private var viewportHeight: CGFloat = 0
    /// A scroll position to hold while the page settles after a switch (it keeps growing
    /// as diagrams render, so each new height re-applies it until the deadline).
    private var restore: (fraction: CGFloat, deadline: Date)?

    /// The visible height changed; the page sizes a short document to fill it.
    var onViewportHeight: ((CGFloat) -> Void)?

    init(webView: WKWebView) {
        web = webView
        super.init(frame: .zero)
        hasVerticalScroller = true
        drawsBackground = false
        borderType = .noBorder
        documentView = canvas
        canvas.addSubview(webView)
        webView.autoresizingMask = []
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The page reported its height; the web view is exactly that tall.
    func setContentHeight(_ height: CGFloat) {
        contentHeight = height
        fit()
        if let restore, Date() < restore.deadline { scroll(toFraction: restore.fraction) }
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
        let size = NSSize(width: contentSize.width, height: max(contentHeight, contentSize.height))
        if canvas.frame.size != size {
            canvas.frame = NSRect(origin: .zero, size: size)
            web.frame = canvas.bounds
        }
    }

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
