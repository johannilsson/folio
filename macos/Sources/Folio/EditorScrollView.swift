import AppKit

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// What the window shows of the document: the rendered preview, or the markdown source.
enum EditorMode {
    case preview, source
}

/// A blur of what scrolls under it, with a tint of the page, fading out along its lower edge.
final class ToolbarBlurView: NSView {
    /// Where the blur starts to fade and where it is gone, as fractions of the strip from its top.
    let solid: CGFloat
    let end: CGFloat
    private let tint: CGFloat
    private let fade = CAGradientLayer()
    private static let fadeSteps: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
    private static let fadeAlphas: [CGFloat] = [1, 1, 0.84, 0.5, 0.16, 0]

    init(radius: CGFloat, tint: CGFloat, solid: CGFloat, end: CGFloat) {
        self.solid = solid
        self.end = end
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        layer?.backgroundFilters = blur.map { [$0] }
        fade.colors = Self.fadeAlphas.map { NSColor.black.withAlphaComponent($0).cgColor }
        fade.startPoint = CGPoint(x: 0.5, y: 1)
        fade.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.mask = fade
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        fade.frame = bounds
        // A smooth ramp, so there is no visible line where the blur ends.
        fade.locations = [0] + Self.fadeSteps.map { NSNumber(value: Double(solid + (end - solid) * $0)) }
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(tint).cgColor
        }
    }

    override var wantsUpdateLayer: Bool { true }
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

    /// Blurs the text that scrolls up under the toolbar, fading out below it.
    /// Blurs over the toolbar, each stronger than the one below and fading out sooner, so the text blurs more and more towards the top.
    private let toolbarBlurs = [
        ToolbarBlurView(radius: 0.5, tint: 0.04, solid: 0, end: 1),
        ToolbarBlurView(radius: 1.4, tint: 0, solid: 0.12, end: 1),
        ToolbarBlurView(radius: 8, tint: 0, solid: 0.29, end: 0.71),
    ]

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
        for blur in toolbarBlurs { addSubview(blur, positioned: .above, relativeTo: nil) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Where things that float over the text go (the open card, the comment button, the form).
    var floatingHost: NSView { canvas }

    /// The width the text has.
    var textWidth: CGFloat { max(0, contentSize.width - paneWidth) }

    /// The part of the document on screen, in the document's coordinates.
    /// Without the strip under the toolbar, where the text scrolls behind glass.
    var visibleDocumentRect: NSRect {
        var rect = contentView.bounds
        rect.origin.y += contentInsets.top
        rect.size.height -= contentInsets.top + contentInsets.bottom
        return rect
    }

    /// The cards reach down to `extent`; the document is at least that tall.
    func setGutterExtent(_ extent: CGFloat) {
        guard extent != gutterExtent else { return }
        gutterExtent = extent
        fit()
    }

    override func tile() {
        super.tile()
        layoutToolbarBlur()
        fit()
    }

    override func layout() {
        super.layout()
        layoutToolbarBlur()
    }

    /// Strips over the top inset, taller than the toolbar so the blur eases out below it.
    private func layoutToolbarBlur() {
        let inset = contentInsets.top
        for blur in toolbarBlurs {
            blur.isHidden = inset <= 0
            guard inset > 0 else { continue }
            let height = inset + 32
            blur.frame = NSRect(x: 0, y: isFlipped ? 0 : bounds.height - height, width: bounds.width, height: height)
        }
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
        canvas.scrollToVisible(NSRect(x: 0, y: top - 24 - contentInsets.top, width: 1, height: bottom - top + 48 + contentInsets.top))
    }

    var scrollOffset: CGFloat { contentView.bounds.origin.y + contentInsets.top }

    private var scrollableHeight: CGFloat { max(0, canvas.frame.height - (contentSize.height - contentInsets.top - contentInsets.bottom)) }

    /// Where the window is in the document, 0 at the top and 1 at the end. It carries a
    /// position across a change of layout (a file switch, the source/preview toggle).
    var scrollFraction: CGFloat { scrollableHeight > 0 ? scrollOffset / scrollableHeight : 0 }

    func scroll(toFraction fraction: CGFloat) {
        contentView.scroll(to: NSPoint(x: 0, y: (fraction * scrollableHeight).rounded() - contentInsets.top))
        reflectScrolledClipView(contentView)
    }
}