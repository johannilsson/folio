import AppKit

/// A window around the preview and the source, with the native toolbar for its two toggles. This is
/// the shared part; `FolioWindowController` shows one file, `SetWindowController` a set.
class EditorWindowController: NSWindowController, NSToolbarDelegate, NSSearchFieldDelegate {
    /// Holds the preview and the source, each as tall as its text; this is what scrolls.
    let scrollHost: EditorScrollView
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
    init(workspace: Workspace, fullHeightSidebar: Bool = false) {
        self.workspace = workspace
        scrollHost = EditorScrollView(source: SourceEditorView(frame: .zero), preview: PreviewView(frame: .zero))

        // The text's own background, so resizing never flashes white.
        let background = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 1)
                : .white
        }

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
        scrollHost.preview.load(currentDocument)
        annotations = AnnotationController(owner: self, host: scrollHost, store: currentStore,
                                           source: scrollHost.source, preview: scrollHost.preview)
        annotations.onPendingChange = { [weak self] in self?.syncButtons() }
        let keys: (NSEvent) -> Bool = { [weak self] event in self?.annotations.handleKey(event) ?? false }
        scrollHost.source.textView.keyHandler = keys
        scrollHost.preview.textView.keyHandler = keys
        syncButtons()

        workspace.onEvent = { [weak self] type, id in self?.workspaceEvent(type, id) }
        workspace.startWatching()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func installToolbar() {
        let toolbar = NSToolbar(identifier: "FolioToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window?.toolbar = toolbar
    }

    /// Remember where `id` is scrolled to before another file replaces it.
    func rememberScroll(of id: String) {
        scrollFractions[id] = scrollHost.scrollFraction
    }

    /// Scroll to where `id` was left, or its top for a file not seen before.
    func restoreScroll(of id: String) {
        scrollHost.scroll(toFraction: scrollFractions[id] ?? 0)
    }

    /// A file changed: the text and the annotations follow. Subclasses also update what they show.
    func workspaceEvent(_ type: String, _ id: String) {
        if type == "folio:changed", let document = workspace.document(id: id) { store(for: document).reload() }
        // The source follows the file it is showing, unless typing is waiting to be saved.
        if type == "md:changed", mode == .source, workspace.document(id: id) === currentDocument { scrollHost.source.reloadFromDisk() }
        if type == "md:changed", workspace.document(id: id) === currentDocument { scrollHost.preview.reloadFromDisk() }
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
                scrollHost.source.load(currentDocument)
            case .preview:
                // The preview shows the file: unsaved typing would be lost on the way back.
                guard scrollHost.source.flushSave() else { return }
                scrollHost.preview.reloadFromDisk()
            }
            // Annotation actions are kept in the preview's history or the text view's; Undo in
            // one mode must not reach past what was done in the other.
            for store in stores.values { store.forgetHistory() }
            mode = new
            scrollHost.mode = new
            scrollHost.scroll(toFraction: fraction)
            annotations.refreshMode()
            syncButtons()
            window?.makeFirstResponder(textResponder)
        }
    }

    // MARK: find

    // The toolbar's search field drives `find` of the preview or the source (`PreviewView.find`,
    // `SourceEditorView.find`), which select the match.

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
        } else {
            scrollHost.preview.find(text, backwards: backwards)
        }
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        window?.makeFirstResponder(textResponder)
    }

    /// What has the keyboard when the text does: the source or the preview.
    private var textResponder: NSView {
        mode == .source ? scrollHost.source.textView : scrollHost.preview.textView
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

}

/// One markdown file in its own window, owned by an `NSDocument`.
final class FolioWindowController: EditorWindowController {
    init(document: FolioDocument) {
        super.init(workspace: Workspace(single: document.files))
        windowFrameAutosaveName = "FolioDocumentWindow"
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
