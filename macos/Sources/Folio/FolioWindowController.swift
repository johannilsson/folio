import AppKit
import WebKit

/// A window around the web editor, with the native toolbar for its two toggles. This is
/// the shared part; `FolioWindowController` shows one file, `SetWindowController` a set.
class EditorWindowController: NSWindowController, WKNavigationDelegate, WKUIDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let webView: WKWebView
    /// Holds the web view, which is as tall as its page; this is what scrolls.
    let scrollHost: EditorScrollView
    let bridge: Bridge
    let workspace: Workspace

    /// Where each file of the window was scrolled to when it was left (see `EditorScrollView.scrollFraction`).
    private var scrollFractions: [String: CGFloat] = [:]

    /// What the window shows of the document, and whether the comments pane is open. Both are the
    /// app's own state: the toolbar and the View menu change them, and the page is not asked.
    private(set) var mode: EditorMode = .preview
    private(set) var commentsOn = false
    var sourceOn: Bool { mode == .source }
    private var switchingMode = false
    /// Unresolved annotations in the file on screen; the badge on the comments icon.
    var pendingCount: Int { currentStore.pending.count }

    private static let sourceID = NSToolbarItem.Identifier("source")
    private static let commentsID = NSToolbarItem.Identifier("comments")
    private static let findID = NSToolbarItem.Identifier("find")

    // Plain toolbar items, so the system sizes and draws them like any other app's.
    // A toggle shows as on with the filled form of its symbol.
    private let sourceItem = NSToolbarItem(itemIdentifier: EditorWindowController.sourceID)
    private let commentsItem = NSToolbarItem(itemIdentifier: EditorWindowController.commentsID)
    let findItem = NSSearchToolbarItem(itemIdentifier: EditorWindowController.findID)

    /// The only file of a single-file window (the first of a set).
    var files: Document { workspace.entries[0].document }

    /// The file on screen: the only one, or the one chosen in a set's sidebar.
    var currentDocument: Document { files }

    private var stores: [String: AnnotationStore] = [:]

    /// The annotations of `document`; one store per file, so a set keeps each file's history.
    func store(for document: Document) -> AnnotationStore {
        if let store = stores[document.id] { return store }
        let store = AnnotationStore(document: document)
        stores[document.id] = store
        return store
    }

    /// The annotations of the file on screen.
    var currentStore: AnnotationStore { store(for: currentDocument) }

    /// The annotation UI of this window: the comments pane, the open card, the comment form.
    private(set) var annotations: AnnotationController!

    /// Toolbar items before the toggles, which sit at the trailing edge.
    var leadingToolbarItems: [NSToolbarItem.Identifier] { [] }

    /// `fullHeightSidebar`: the window gets a sidebar that runs to its top edge; the subclass
    /// installs the toolbar once it has built the split view the toolbar has to follow.
    init(workspace: Workspace, entryURL: URL, fullHeightSidebar: Bool = false) {
        self.workspace = workspace
        bridge = Bridge(workspace: workspace)

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
        webView = ForwardingWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        scrollHost = EditorScrollView(webView: webView, source: SourceEditorView(frame: .zero),
                                      native: AppConfig.nativePreview ? NativePreviewView(frame: .zero) : nil)

        // The page's own background, so resizing and loading never flash white.
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1)
                : .white
        }
        webView.underPageBackgroundColor = background

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: fullHeightSidebar
                ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                : [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        if !fullHeightSidebar { window.contentView = scrollHost }
        window.backgroundColor = background
        window.minSize = NSSize(width: 480, height: 320)
        window.toolbarStyle = .unified

        super.init(window: window)
        shouldCascadeWindows = true

        webView.navigationDelegate = self
        webView.uiDelegate = self
        findItem.searchField.delegate = self
        findItem.searchField.target = self
        findItem.searchField.action = #selector(findNext(_:))

        if !fullHeightSidebar { installToolbar() }

        for (item, label, action) in [
            (sourceItem, "Preview", #selector(toggleSource(_:))),
            (commentsItem, "Comments", #selector(toggleComments(_:))),
        ] {
            item.label = label
            item.toolTip = label
            item.target = self
            item.action = action
            item.isBordered = true
        }
        syncButtons()
        bridge.onLayout = { [weak self] height in self?.scrollHost.setContentHeight(height) }
        bridge.onReveal = { [weak self] top, bottom in self?.scrollHost.reveal(top: top, bottom: bottom) }
        scrollHost.onViewportHeight = { [weak self] height in self?.pushViewportHeight(height) }

        scrollHost.native?.load(currentDocument)
        annotations = AnnotationController(owner: self, host: scrollHost, store: currentStore,
                                           preview: PreviewSurface(webView: webView, bridge: bridge), source: scrollHost.source,
                                           native: scrollHost.native)
        annotations.onPendingChange = { [weak self] in self?.syncButtons() }
        let keys: (NSEvent) -> Bool = { [weak self] event in self?.annotations.handleKey(event) ?? false }
        (webView as? ForwardingWebView)?.keyHandler = keys
        scrollHost.source.textView.keyHandler = keys
        scrollHost.native?.textView.keyHandler = keys
        syncButtons()

        // Stand-in for the WebSocket: file changes reach the page as events.
        workspace.onEvent = { [weak self] type, id in self?.workspaceEvent(type, id) }
        workspace.startWatching()

        // The native preview does not need the page.
        if scrollHost.native == nil { webView.load(URLRequest(url: entryURL)) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func installToolbar() {
        let toolbar = NSToolbar(identifier: "FolioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    /// The page sizes a short document to fill the window (see `__folioViewport` in layout.ts).
    private func pushViewportHeight(_ height: CGFloat) {
        webView.evaluateJavaScript("window.__folioViewport?.(\(Int(height)))")
    }

    /// Remember where `id` is scrolled to before another file replaces it.
    func rememberScroll(of id: String) {
        scrollFractions[id] = scrollHost.scrollFraction
    }

    /// Scroll to where `id` was left, or its top for a file not seen before.
    func restoreScroll(of id: String) {
        scrollHost.restoreScroll(scrollFractions[id] ?? 0)
    }

    /// A file changed: tell the page. Subclasses also update what they show.
    func workspaceEvent(_ type: String, _ id: String) {
        if type == "folio:changed", let document = workspace.document(id: id) { store(for: document).reload() }
        // The source follows the file it is showing, unless typing is waiting to be saved.
        if type == "md:changed", mode == .source, workspace.document(id: id) === currentDocument { scrollHost.source.reloadFromDisk() }
        if type == "md:changed", workspace.document(id: id) === currentDocument { scrollHost.native?.reloadFromDisk() }
        webView.callAsyncJavaScript("window.__folioEmit?.(type, id)", arguments: ["type": type, "id": id], in: nil, in: .page) { _ in }
    }

    func stopWatching() {
        workspace.stopWatching()
    }

    // MARK: toggles

    @objc func toggleSource(_ sender: Any?) {
        setMode(mode == .preview ? .source : .preview)
    }

    @objc func toggleComments(_ sender: Any?) {
        commentsOn.toggle()
        annotations.refreshMode()
        syncButtons()
    }

    /// Shows the preview or the source. What was typed in the one is saved first, and the other
    /// picks up the file; the reader stays about as far into the document.
    func setMode(_ new: EditorMode) {
        guard new != mode, !switchingMode else { return }
        switchingMode = true
        let fraction = scrollHost.scrollFraction
        Task { @MainActor in
            defer { switchingMode = false }
            switch new {
            case .source:
                await annotations.preview.flush()
                scrollHost.source.load(currentDocument)
            case .preview:
                // The preview shows the file: unsaved typing would be lost on the way back.
                guard scrollHost.source.flushSave() else { return }
                if let native = scrollHost.native {
                    native.reloadFromDisk()
                } else {
                    _ = try? await webView.callAsyncJavaScript("await window.__folioReload?.()", in: nil, contentWorld: .page)
                }
            }
            // Annotation actions are kept in the preview's history or the text view's; Undo in
            // one mode must not reach past what was done in the other.
            for store in stores.values { store.forgetHistory() }
            mode = new
            scrollHost.mode = new
            scrollHost.restoreScroll(fraction, for: 1.5)
            annotations.refreshMode()
            syncButtons()
            window?.makeFirstResponder(new == .source ? scrollHost.source.textView : (scrollHost.native?.textView ?? webView))
        }
    }

    // MARK: find

    // WKWebView has no find bar on macOS: the toolbar's search field drives `find`, which
    // selects the match. The page is as tall as its content, so it cannot scroll to the
    // match itself: it reports the selection and the scroll view goes there. The source
    // has its own search (`SourceEditorView.find`).

    @objc func showFind(_ sender: Any?) {
        window?.makeFirstResponder(findItem.searchField)
        findItem.searchField.selectText(nil)
    }

    @objc func findNext(_ sender: Any?) { find(backwards: false) }

    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }

    private func find(backwards: Bool) {
        let text = findItem.searchField.stringValue
        guard !text.isEmpty else { return }
        if mode == .source {
            scrollHost.source.find(text, backwards: backwards)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            if result.matchFound { self?.webView.evaluateJavaScript("window.__folioRevealSelection?.()") }
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        window?.makeFirstResponder(mode == .source ? scrollHost.source.textView : (scrollHost.native?.textView ?? webView))
    }

    private func syncButtons() {
        // The toolbar draws every symbol at its own fixed size (point size, scale and
        // image size are ignored), so the visual weight is chosen by the symbol.
        // The document is "selected" while its rendered preview shows; clicking it switches to the source.
        sourceItem.image = NSImage(systemSymbolName: sourceOn ? "doc.text" : "doc.text.fill",
                                   accessibilityDescription: "Preview")
        sourceItem.toolTip = sourceOn ? "Show the preview" : "Show the markdown source"
        commentsItem.image = commentsImage()
        commentsItem.toolTip = pendingCount == 0 ? "Comments" : "Comments (\(pendingCount))"
    }

    /// The comments bubble; with pending annotations, a plain bubble with their number inside
    /// (cut out of the filled one), so the count is a quiet detail of the icon itself.
    private func commentsImage() -> NSImage? {
        guard pendingCount > 0 else {
            return NSImage(systemSymbolName: commentsOn ? "text.bubble.fill" : "text.bubble",
                           accessibilityDescription: "Comments")
        }
        // The toolbar scales its own symbols up but draws this image as is, so it starts larger
        // to match the other icons.
        guard let bubble = NSImage(systemSymbolName: commentsOn ? "bubble.fill" : "bubble",
                                   accessibilityDescription: "Comments")?
            .withSymbolConfiguration(.init(pointSize: 17.5, weight: .regular)) else { return nil }
        let text = pendingCount > 99 ? "99+" : String(pendingCount)
        let size = bubble.size
        let image = NSImage(size: size, flipped: false) { rect in
            bubble.draw(in: rect)
            let font = NSFont.systemFont(ofSize: rect.height * (text.count > 1 ? 0.36 : 0.44), weight: .semibold)
            let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
            // Digits are centered on their own height, not the line box (which has room for
            // descenders), and sit a little above the middle: the bubble's body is above its tail.
            let center = rect.midY + rect.height * 0.07
            let origin = NSPoint(x: rect.midX - attributed.size().width / 2,
                                 y: center - font.capHeight / 2 + font.descender)
            NSGraphicsContext.current?.cgContext.setBlendMode(self.commentsOn ? .destinationOut : .normal)
            attributed.draw(at: origin)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Comments"
        return image
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        leadingToolbarItems + [.flexibleSpace, Self.findID, Self.sourceID, Self.commentsID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.sourceID: return sourceItem
        case Self.commentsID: return commentsItem
        case Self.findID: return findItem
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

    // A page loaded after the window was laid out has not been told how tall the window is.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pushViewportHeight(scrollHost.contentSize.height)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
    }
}

/// One markdown file in its own window, owned by an `NSDocument`.
final class FolioWindowController: EditorWindowController {
    init(document: FolioDocument) {
        super.init(workspace: Workspace(single: document.files), entryURL: SchemeHandler.entryURL)
        windowFrameAutosaveName = "FolioDocumentWindow"
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
