import AppKit
import WebKit

/// A window showing one document: the web editor, plus the native toolbar for its two
/// toggles.
final class FolioWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate {
    let webView: WKWebView
    let bridge: Bridge

    /// Mirrors of the page's toggles (see the `uiState` op).
    private(set) var sourceOn = true
    private(set) var commentsOn = false

    private static let sourceID = NSToolbarItem.Identifier("source")
    private static let commentsID = NSToolbarItem.Identifier("comments")

    // Plain toolbar items, so the system sizes and draws them like any other app's.
    // A toggle shows as on with the filled form of its symbol.
    private let sourceItem = NSToolbarItem(itemIdentifier: FolioWindowController.sourceID)
    private let commentsItem = NSToolbarItem(itemIdentifier: FolioWindowController.commentsID)

    /// The file IO behind this window. Held directly: `document` is only set once AppKit
    /// has added this controller to the document, after init.
    let files: Document

    init(document: FolioDocument) {
        files = document.files
        bridge = Bridge(document: document.files)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(root: AppConfig.dist), forURLScheme: SchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: Bridge.name)
        // Collect script errors so the self-test can fail on any.
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.__errors = [];
            window.addEventListener('error', e => window.__errors.push(String(e.message)));
            window.addEventListener('unhandledrejection', e => window.__errors.push('rejection: ' + String(e.reason)));
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))
        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true

        // The page's own background, so resizing and loading never flash white.
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1)
                : .white
        }
        webView.underPageBackgroundColor = background

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = webView
        window.backgroundColor = background
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unified

        super.init(window: window)
        shouldCascadeWindows = true
        windowFrameAutosaveName = "FolioDocumentWindow"

        webView.navigationDelegate = self
        webView.uiDelegate = self

        let toolbar = NSToolbar(identifier: "FolioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        for (item, label, action) in [
            (sourceItem, "Markdown Source", #selector(toggleSource(_:))),
            (commentsItem, "Comments", #selector(toggleComments(_:))),
        ] {
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
        }
        syncButtons()
        bridge.onUIState = { [weak self] source, comments in
            self?.sourceOn = source
            self?.commentsOn = comments
            self?.syncButtons()
        }

        // Stand-in for the WebSocket: file changes reach the page as events.
        files.onEvent = { [weak self] type in
            self?.webView.evaluateJavaScript("window.__folioEmit?.('\(type)', '\(Document.id)')")
        }
        files.startWatching()

        webView.load(URLRequest(url: SchemeHandler.entryURL))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: toggles

    @objc func toggleSource(_ sender: Any?) {
        webView.evaluateJavaScript("document.getElementById('view-toggle-btn').click()")
    }

    @objc func toggleComments(_ sender: Any?) {
        webView.evaluateJavaScript("document.getElementById('toggle-gutter-btn').click()")
    }

    private func syncButtons() {
        // The toolbar draws every symbol at its own fixed size (point size, scale and
        // image size are ignored), so the visual weight is chosen by the symbol.
        sourceItem.image = NSImage(systemSymbolName: sourceOn ? "doc.plaintext.fill" : "doc.plaintext",
                                   accessibilityDescription: "Markdown Source")
        commentsItem.image = NSImage(systemSymbolName: commentsOn ? "bubble.left.fill" : "bubble.left",
                                     accessibilityDescription: "Comments")
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.sourceID, Self.commentsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sourceID: return sourceItem
        case Self.commentsID: return commentsItem
        default: return nil
        }
    }

    // MARK: navigation

    // Links in the document open in the browser; the window only ever shows folio://.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme != SchemeHandler.scheme,
              navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
    }
}
