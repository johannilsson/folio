import AppKit
import WebKit

/// Where a surface drew an annotation: its top-left and line height, in the scrolling canvas's
/// coordinates (the page's, for the preview), and its place in the document, which orders the cards.
struct AnchorRect: Equatable {
    var id: String
    var from: Int
    var top: Double
    var bottom: Double
    var left: Double
}

/// The text the reader has selected, and the words an annotation on it is anchored by.
struct SelectionInfo: Equatable {
    var from: Int
    var to: Int
    /// The first line of the selection.
    var top: Double
    var bottom: Double
    /// The bottom of its last line.
    var endBottom: Double
    var left: Double
    var right: Double
    var target: String
    var contextBefore: String
}

/// What the annotation UI needs from whatever shows the text: the rendered preview (a web page) or
/// the markdown source (a native text view). The cards, pane, open card, Comment button, form
/// and toast are the same for both (`AnnotationController`); a surface draws the highlights and
/// reports where annotations are, what is selected and what was clicked.
@MainActor
protocol AnnotationSurface: AnyObject {
    /// Where each pending annotation starts, once the surface has anchored them, and whenever it changes.
    var onAnchors: (([AnchorRect]) -> Void)? { get set }
    /// The selected text, or nil when nothing is selected.
    var onSelection: ((SelectionInfo?) -> Void)? { get set }
    /// The annotation clicked in the text, or nil for a click on plain text.
    var onFocus: ((String?) -> Void)? { get set }
    /// The mouse was pressed somewhere in the text, before the surface acted on it.
    var onPointer: (() -> Void)? { get set }

    /// Whether the keyboard is in the text, so the Comment button over a selection is wanted.
    var hasKeyboardFocus: Bool { get }
    /// Gives the keyboard back to the text.
    func focusText()

    /// The pending annotations changed. The preview reads the sidecar itself; the source anchors them here.
    func annotationsChanged(_ pending: [Annotation])
    /// Keeps the text being commented on highlighted while the form is open.
    func setPending(_ range: (from: Int, to: Int)?)
    /// Puts the caret at the start of an annotation.
    func select(annotation id: String)
    /// Saves pending edits, so accepting patches the text as it is on screen.
    func flush() async
    /// The text changes only once the reloaded document arrives; flash it then.
    func flashAfterReload(_ text: String)
}

/// The rendered preview: a web page that draws the highlights, and tells the app what it needs
/// through the bridge (the `anchors`, `selection`, `focus` and `pointer` ops).
@MainActor
final class PreviewSurface: AnnotationSurface {
    private unowned let webView: WKWebView
    var onAnchors: (([AnchorRect]) -> Void)?
    var onSelection: ((SelectionInfo?) -> Void)?
    var onFocus: ((String?) -> Void)?
    var onPointer: (() -> Void)?
    /// The reader typed in the page: Undo is the page's for a moment.
    var onTyping: (() -> Void)?

    init(webView: WKWebView, bridge: Bridge) {
        self.webView = webView
        bridge.onAnchors = { [weak self] list in self?.onAnchors?(list) }
        bridge.onSelection = { [weak self] selection in self?.onSelection?(selection) }
        bridge.onFocus = { [weak self] id in self?.onFocus?(id) }
        bridge.onPointer = { [weak self] in self?.onPointer?() }
        bridge.onTyping = { [weak self] in self?.onTyping?() }
    }

    var hasKeyboardFocus: Bool {
        ((webView.window?.firstResponder as? NSView)?.isDescendant(of: webView)) ?? false
    }

    func focusText() {
        webView.window?.makeFirstResponder(webView)
    }

    func annotationsChanged(_ pending: [Annotation]) {}

    func setPending(_ range: (from: Int, to: Int)?) {
        let argument = range.map { "{from: \($0.from), to: \($0.to)}" } ?? "null"
        webView.evaluateJavaScript("window.__folioSetPending?.(\(argument))")
    }

    func select(annotation id: String) {
        webView.evaluateJavaScript("window.__folioSelectAnnotation?.('\(id)')")
    }

    func flush() async {
        _ = try? await webView.callAsyncJavaScript("await window.__folioFlush?.()", in: nil, contentWorld: .page)
    }

    func flashAfterReload(_ text: String) {
        webView.callAsyncJavaScript("window.__folioFlashAfterReload?.(text)", arguments: ["text": text], in: nil, in: .page) { _ in }
    }
}
