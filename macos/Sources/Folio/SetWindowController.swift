import AppKit
import FolioKit
import UniformTypeIdentifiers

/// A window for a named set of files: a sidebar of the files beside the editor, which
/// swaps documents in place. The set itself lives in ~/.config/folio/sets, shared with
/// `folio set`, so the sidebar follows changes made from a terminal too.
final class SetWindowController: EditorWindowController, NSWindowDelegate {
    let sidebar: SidebarViewController
    private(set) var currentID: String

    private var sidebarSplitItem: NSSplitViewItem?

    /// The open items of the set, in place of the editor while the Open row is chosen.
    let openList = OpenListView()
    private(set) var openListShown = false
    /// The open items of each file, by file id; a file is read again when it changes.
    private var pageItems: [String: [OpenItem]] = [:]
    /// The tags `pageItems` were read with: a set that gains or loses one is read again.
    private var itemTags: [OpenTag] = []
    private(set) var openEntries: [OpenEntry] = []

    /// The Open pane: the split view's inspector, at the right beside the editor (and so beside the comments
    /// pane). Whether it is open is its split item's (the reader can also drag it shut); it lists the whole set
    /// until the reader picks "This file".
    let openPane = OpenPaneView()
    private var openPaneSplitItem: NSSplitViewItem?
    private var openPaneObservation: NSKeyValueObservation?
    var openPaneOn: Bool { openPaneSplitItem.map { !$0.isCollapsed } ?? false }
    private(set) var openScope: OpenList.Scope = .set
    /// Which of the pane's two tabs is shown, Open or References; the toolbar button opens the one last shown.
    private(set) var paneTab: OpenPaneView.Tab = .open
    private static let openPaneID = NSToolbarItem.Identifier("openPane")
    private static let openPaneSeparatorID = NSToolbarItem.Identifier("openPaneSeparator")
    private let openPaneItem = NSToolbarItem(itemIdentifier: SetWindowController.openPaneID)

    /// Files in the set's folders that changed underneath: new since the window opened, or
    /// changed since the reader last looked at them. Cleared when the file is shown.
    private(set) var marks: [String: SidebarTree.Mark] = [:]
    /// The files of the set's folders when last looked, by id, to tell what came and went.
    private var folderNames: [String: String] = [:]

    /// Shows the sidebar if the user (or the saved layout) had collapsed it.
    func showSidebar() {
        sidebarSplitItem?.isCollapsed = false
    }

    /// The window closed; the app stops tracking it.
    var onClose: (() -> Void)?

    var setName: String { workspace.setName ?? "" }

    override var currentDocument: Document { workspace.document(id: currentID) ?? files }

    private var split: NSSplitViewController?

    // The sidebar runs to the top of the window, as in Finder, Notes and Preview: the
    // sidebar button sits in its top strip, and the toolbar after the tracking separator
    // belongs to the editor.
    override var leadingToolbarItems: [NSToolbarItem.Identifier] { [.toggleSidebar, .sidebarTrackingSeparator] }
    // The Open pane is an inspector, as in Xcode: a second tracking separator follows its divider, so the
    // editor's buttons stay over the editor and the pane's button sits at the trailing edge, over the pane
    // while it is open.
    override var trailingToolbarItems: [NSToolbarItem.Identifier] { [Self.openPaneSeparatorID, .flexibleSpace, Self.openPaneID] }

    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
        if id == Self.openPaneSeparatorID, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 1)
        }
        if id == Self.openPaneID { return openPaneItem }
        return super.toolbar(toolbar, itemForItemIdentifier: id, willBeInsertedIntoToolbar: flag)
    }

    /// `info` must have at least one file: the window opens on the first.
    init(set info: Rust.SetInfo) {
        let workspace = Workspace(set: info)
        sidebar = SidebarViewController(workspace: workspace)
        currentID = workspace.entries[0].document.id
        super.init(workspace: workspace, fullHeightSidebar: true)

        // The editor goes in the content pane of a split view, with the sidebar beside it.
        // The text runs up under the toolbar, which floats over the content side.
        let content = NSViewController()
        let contentRoot = NSView()
        scrollHost.translatesAutoresizingMaskIntoConstraints = false
        contentRoot.addSubview(scrollHost)
        NSLayoutConstraint.activate([
            scrollHost.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            scrollHost.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
            scrollHost.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            scrollHost.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
        ])
        openList.translatesAutoresizingMaskIntoConstraints = false
        openList.isHidden = true
        contentRoot.addSubview(openList)
        NSLayoutConstraint.activate([
            openList.topAnchor.constraint(equalTo: contentRoot.topAnchor),
            openList.bottomAnchor.constraint(equalTo: contentRoot.bottomAnchor),
            openList.leadingAnchor.constraint(equalTo: contentRoot.leadingAnchor),
            openList.trailingAnchor.constraint(equalTo: contentRoot.trailingAnchor),
        ])
        content.view = contentRoot
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)
        sidebarSplitItem = sidebarItem
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        // The Open pane, the window's inspector: the editor narrows when it opens.
        let paneController = NSViewController()
        paneController.view = openPane
        let paneItem: NSSplitViewItem
        if #available(macOS 14, *) {
            paneItem = NSSplitViewItem(inspectorWithViewController: paneController)
        } else {
            paneItem = NSSplitViewItem(viewController: paneController)
            paneItem.canCollapse = true
        }
        // A fixed width: left free, it opens at its widest and squeezes the text and the comments pane.
        paneItem.minimumThickness = OpenPaneView.width
        paneItem.maximumThickness = OpenPaneView.width
        paneItem.isCollapsed = true
        split.addSplitViewItem(paneItem)
        openPaneSplitItem = paneItem
        // Its own name: the layout saved with two panes would not fit three.
        split.splitView.autosaveName = "FolioSetSplit3"
        self.split = split
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1100, height: 800))
        installToolbar()

        window?.delegate = self
        window?.title = info.name
        window?.subtitle = subtitle(of: workspace.entries[0])
        windowFrameAutosaveName = "FolioSetWindow"

        folderNames = Self.namesInFolders(workspace)
        sidebar.mark = { [weak self] id in self?.marks[id] }
        sidebar.onSelect = { [weak self] id in self?.openFile(id) }
        sidebar.onAdd = { [weak self] in self?.addFilesToSet(nil) }
        sidebar.onRemove = { [weak self] id in self?.remove(id) }
        sidebar.onOpenList = { [weak self] in self?.showOpenList() }
        openList.onTick = { [weak self] entry in self?.tickOpenItem(entry) }
        openList.onOpen = { [weak self] entry in self?.openItem(entry) }
        openList.onLink = { [weak self] url in self?.follow(openListLink: url) }
        openPane.onTick = { [weak self] entry in self?.tickOpenItem(entry) }
        openPane.onOpen = { [weak self] entry in self?.openItem(entry) }
        openPane.onScope = { [weak self] scope in self?.setOpenScope(scope) }
        openPane.onTab = { [weak self] tab in self?.setPaneTab(tab) }
        openPane.onOpenReference = { [weak self] backlink in self?.openReference(backlink) }
        openPaneItem.label = "Open"
        openPaneItem.target = self
        openPaneItem.action = #selector(toggleOpenPane(_:))
        openPaneItem.isBordered = true
        // Opened or closed by the button, the menu or dragging its divider: the button and the list follow.
        openPaneObservation = paneItem.observe(\.isCollapsed) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.openPaneChanged() }
        }
        workspace.onChange = { [weak self] in self?.filesChanged() }
        updateOpenItems()
        updateFileReferences()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: following the files

    override func workspaceEvent(_ type: String, _ id: String) {
        super.workspaceEvent(type, id)
        // Annotations came or went in some file: its badge moves.
        if type == "folio:changed" { sidebar.reload() }
        // A file changed: its open items may differ.
        if type == "md:changed" {
            pageItems[id] = nil
            updateOpenItems()
        }
        // A wiki page changed, or the file on screen: the backlinks may differ.
        if type == "md:changed", workspace.entries.first(where: { $0.document.id == id })?.inFolder == true {
            pageReferences[id] = nil
            updateBacklinks()
        } else if id == currentID {
            updateBacklinks()
        }
        // A file of the set's folders changed while another was shown: it gets its dot.
        if type == "md:changed", id != currentID, let name = folderNames[id] {
            if marks[id] == nil { marks[id] = .changed }
            sidebar.reload()
            if let text = SidebarTree.notice(added: [], removed: [], changed: [name]) { sidebar.showNotice(text) }
        }
    }

    /// Opens a file of the set in the editor, in place. `completion` runs once the new file is shown.
    func openFile(_ id: String, completion: (() -> Void)? = nil) {
        hideOpenList()
        guard id != currentID, let entry = workspace.entries.first(where: { $0.document.id == id }) else {
            completion?()
            return
        }
        let previous = currentID
        rememberScroll(of: currentID)
        currentID = id
        // Another file's annotations: the cards ask for their backlinks and items again.
        backlinks = nil
        cardItems = nil
        window?.subtitle = subtitle(of: entry)
        // Looked at now: its mark goes.
        if marks.removeValue(forKey: id) != nil { sidebar.reload() }
        sidebar.select(id)
        // The source shows the file it was opened on until it is told otherwise. It comes first: the
        // annotation UI then hands the new file's annotations to it.
        if mode == .source { scrollHost.source.load(entry.document) }
        scrollHost.preview.load(entry.document)
        annotations.fileChanged(store: currentStore)
        restoreScroll(of: id)
        // What was typed in the file left is on disk by now: it may have tagged an item.
        pageItems[previous] = nil
        updateOpenItems()
        // The pages that link to this file, not the last one.
        updateFileReferences()
        completion?()
    }

    /// The manifest changed (here or from a terminal): refresh the sidebar, and move off a
    /// file that is no longer in the set.
    private func filesChanged() {
        // Files that came or went in the set's folders: the new ones are marked, and the sidebar
        // says what happened.
        let now = Self.namesInFolders(workspace)
        let added = now.keys.filter { folderNames[$0] == nil }.sorted()
        let removed = folderNames.keys.filter { now[$0] == nil }.sorted()
        for id in added { marks[id] = .new }
        for id in removed { marks[id] = nil }
        if let text = SidebarTree.notice(added: added.compactMap { now[$0] }, removed: removed.compactMap { folderNames[$0] }, changed: []) {
            sidebar.showNotice(text)
        }
        folderNames = now
        sidebar.reload()
        // A page that came or went in the wiki, a branch that was checked out: links go live or dead.
        scrollHost.preview.refreshLinks()
        for id in pageReferences.keys where now[id] == nil { pageReferences[id] = nil }
        for id in pageItems.keys where workspace.document(id: id) == nil { pageItems[id] = nil }
        updateOpenItems()
        updateBacklinks()
        if !workspace.entries.contains(where: { $0.document.id == currentID }), let first = workspace.entries.first {
            openFile(first.document.id)
        } else if let entry = workspace.entries.first(where: { $0.document.id == currentID }) {
            window?.subtitle = subtitle(of: entry)
        }
    }

    // MARK: the Open list

    /// The open items of every file of the set, read again for a file that changed.
    func updateOpenItems() {
        if itemTags != workspace.tags {
            itemTags = workspace.tags
            pageItems = [:]
        }
        var entries: [OpenEntry] = []
        for entry in workspace.entries {
            let id = entry.document.id
            if pageItems[id] == nil { pageItems[id] = (try? Rust.openItems(in: (try? entry.document.readFile()) ?? "", tags: workspace.tags.map(\.name))) ?? [] }
            entries += (pageItems[id] ?? []).map { OpenEntry(pageID: id, page: entry.name, item: $0) }
        }
        openEntries = entries
        openList.tags = workspace.tags
        openPane.tags = workspace.tags
        openList.entries = entries
        sidebar.openCount = entries.count
        updateOpenPane()
        if openListShown, entries.isEmpty { hideOpenList() }
        // The cards list the items that are about their annotation.
        let onCards = computeCardItems()
        if onCards != cardItems {
            cardItems = onCards
            annotations?.refresh()
        }
    }

    // MARK: the Open pane

    /// View ▸ Toggle Open Items and the toolbar button: the pane opens or closes beside the editor.
    @objc func toggleOpenPane(_ sender: Any?) {
        guard let item = openPaneSplitItem else { return }
        item.animator().isCollapsed = !item.isCollapsed
    }

    private func openPaneChanged() {
        if openPaneOn {
            // What was typed in a file is on disk by now: read every file again.
            pageItems = [:]
            updateOpenItems()
        }
        syncOpenButton()
    }

    /// "This file" or "Whole set" in the pane.
    func setOpenScope(_ scope: OpenList.Scope) {
        openScope = scope
        updateOpenPane()
    }

    /// Open or References in the pane.
    func setPaneTab(_ tab: OpenPaneView.Tab) {
        paneTab = tab
        updateOpenPane()
    }

    /// The pane lists what its scope says, with the items about an annotation of the file on screen marked, or
    /// on its References tab the wiki pages that link to the file on screen.
    private func updateOpenPane() {
        let here = linkTarget()
        openPane.tab = paneTab
        openPane.scope = openScope
        openPane.references = FileReferences.byPage(fileReferences)
        openPane.counts = (openEntries.count, fileReferences.count)
        openPane.rows = OpenList.paneRows(openEntries, scope: openScope, candidate: here?.candidate, file: here?.file ?? "")
        syncOpenButton()
    }

    /// The checklist with the number of open items in the set beside it; ticked while the pane is open.
    private func syncOpenButton() {
        let count = openEntries.count
        openPaneItem.toolTip = count == 0 ? "Open items" : "Open items (\(count))"
        openPaneItem.image = openPaneImage(count: count)
    }

    private func openPaneImage(count: Int) -> NSImage? {
        let name = openPaneOn ? "checklist.checked" : "checklist.unchecked"
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: "Open items")
                ?? NSImage(systemSymbolName: "checklist", accessibilityDescription: "Open items") else { return nil }
        guard count > 0 else { return symbol }
        // The toolbar scales its own symbols up but draws this image as is, so it starts larger to match.
        let glyph = symbol.withSymbolConfiguration(.init(pointSize: 15, weight: .regular)) ?? symbol
        let text = NSAttributedString(string: count > 99 ? "99+" : String(count), attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black,
        ])
        let gap: CGFloat = 3
        let textSize = text.size()
        let size = NSSize(width: ceil(glyph.size.width + gap + textSize.width), height: ceil(max(glyph.size.height, textSize.height)))
        let image = NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: NSRect(x: 0, y: (rect.height - glyph.size.height) / 2, width: glyph.size.width, height: glyph.size.height))
            text.draw(at: NSPoint(x: glyph.size.width + gap, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Open items"
        return image
    }

    /// Shows the list in place of the editor.
    func showOpenList() {
        // What was typed in a file is on disk by now: read every file again.
        pageItems = [:]
        updateOpenItems()
        guard !openEntries.isEmpty else { return }
        openListShown = true
        openList.isHidden = false
        scrollHost.isHidden = true
        window?.subtitle = "Open items"
        sidebar.selectOpenList()
    }

    /// Back to the editor, on the file it was on.
    func hideOpenList() {
        guard openListShown else { return }
        openListShown = false
        openList.isHidden = true
        scrollHost.isHidden = false
        if let entry = workspace.entries.first(where: { $0.document.id == currentID }) { window?.subtitle = subtitle(of: entry) }
        sidebar.select(currentID)
    }

    /// Opens the file the item is in, with the start of its words selected.
    private func openItem(_ entry: OpenEntry) {
        openFile(entry.pageID) { [weak self] in
            self?.annotations.reveal(passage: String(entry.item.text.prefix(40)), before: "")
        }
    }

    /// An address or a Folio link on a row: only web addresses and links into Folio open.
    private func follow(openListLink url: URL) {
        if url.scheme == "folio" {
            follow(url)
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Ticks an item: its file is read, changed and written (the disk is the truth), not the copy the list
    /// holds. An item that is not on its line any more (the file changed since) is not ticked.
    override func tickOpenItem(_ entry: OpenEntry) {
        guard let document = workspace.document(id: entry.pageID) else { return }
        let write: () -> Void = { [weak self] in
            guard let self else { return }
            do {
                let text = try document.readFile()
                if try Rust.openItems(in: text, tags: workspace.tags.map(\.name)).contains(where: { $0.line == entry.item.line && $0.text == entry.item.text }) {
                    try document.writeFile(try Rust.tickItem(in: text, line: entry.item.line))
                    // Our own write is not reported back by the poller.
                    if document === currentDocument {
                        scrollHost.preview.reloadFromDisk()
                        if mode == .source { scrollHost.source.reloadFromDisk() }
                    }
                }
            } catch {
                NSApp.presentError(error)
            }
            pageItems[entry.pageID] = nil
            updateOpenItems()
        }
        if mode == .source, document === currentDocument {
            // What is typed in it is saved first, so the write does not drop it.
            Task { @MainActor in
                await scrollHost.source.flush()
                write()
            }
        } else {
            write()
        }
    }

    // MARK: backlinks

    /// What each wiki page links to, by the page's id. A page is read again when it changes.
    private var pageReferences: [String: [WikiReferences.Reference]] = [:]
    /// The wiki pages that link to each annotation of the file on screen, by annotation id; nil until asked.
    private var backlinks: [String: [Backlink]]?
    /// The open items that link to each annotation of the file on screen, by annotation id; nil until asked.
    private var cardItems: [String: [OpenEntry]]?

    /// Every link in the wiki pages to the file on screen, whatever it points at: the References tab lists them.
    private(set) var fileReferences: [FileReference] = []

    /// What a wiki page links to, read again when the page changes.
    private func links(in page: Workspace.Entry) -> [WikiReferences.Reference] {
        if pageReferences[page.document.id] == nil {
            pageReferences[page.document.id] = WikiReferences.find(in: (try? page.document.readFile()) ?? "")
        }
        return pageReferences[page.document.id] ?? []
    }

    private func computeFileReferences() -> [FileReference] {
        guard let here = linkTarget() else { return [] }
        let pages = workspace.entries.filter(\.inFolder).map { FileReferences.Page(id: $0.document.id, name: $0.name, references: links(in: $0)) }
        return FileReferences.collect(pages, candidate: here.candidate, file: here.file)
    }

    /// The links to the file on screen changed (a page, or the file shown): the References tab is drawn again.
    private func updateFileReferences() {
        let now = computeFileReferences()
        guard now != fileReferences else { return }
        fileReferences = now
        updateOpenPane()
    }

    override func references(for annotation: String) -> [Backlink] {
        if backlinks == nil { backlinks = computeBacklinks() }
        return backlinks?[annotation] ?? []
    }

    override var openTags: [OpenTag] { workspace.tags }

    override func openItems(for annotation: String) -> [OpenEntry] {
        if cardItems == nil { cardItems = computeCardItems() }
        return cardItems?[annotation] ?? []
    }

    /// Which open items are about which annotation of the file on screen: those with a link to it.
    private func computeCardItems() -> [String: [OpenEntry]] {
        guard let here = linkTarget() else { return [:] }
        var found: [String: [OpenEntry]] = [:]
        for entry in openEntries {
            guard case .annotation(let id) = OpenList.about(entry.item, candidate: here.candidate, file: here.file) else { continue }
            found[id, default: []].append(entry)
        }
        return found
    }

    /// The file on screen as a link names it: its checkout (nil when it is in none) and its path on disk.
    private func linkTarget() -> (candidate: FolioLink.Candidate?, file: String)? {
        guard let current = workspace.entries.first(where: { $0.document.id == currentID }) else { return nil }
        return (current.checkout.map { FolioLink.Candidate(repo: $0.repo, branch: $0.branch, path: current.name) }, current.document.file.path)
    }

    /// Opens the page at the link: the page, then the words of the link selected.
    override func openReference(_ backlink: Backlink) {
        openFile(backlink.pageID) { [weak self] in
            guard !backlink.label.isEmpty else { return }
            self?.annotations.reveal(passage: backlink.label, before: "")
        }
    }

    /// A page's links or the file on screen changed: the cards are drawn again when what they list does.
    private func updateBacklinks() {
        updateFileReferences()
        let now = computeBacklinks()
        guard now != backlinks else { return }
        backlinks = now
        annotations.refresh()
    }

    /// Which wiki pages link to which annotation of the file on screen: a link to an annotation by its id, a
    /// link to a passage to the annotations whose text it overlaps.
    private func computeBacklinks() -> [String: [Backlink]] {
        let pages = workspace.entries.filter(\.inFolder)
        guard !pages.isEmpty, let current = workspace.entries.first(where: { $0.document.id == currentID }) else { return [:] }
        let candidate = current.checkout.map { FolioLink.Candidate(repo: $0.repo, branch: $0.branch, path: current.name) }
        let file = current.document.file.path
        var text: String?
        var placed: [String: NSRange]?
        var found: [String: [Backlink]] = [:]
        for page in pages {
            for reference in links(in: page) where reference.link.points(to: candidate, file: file) {
                let backlink = Backlink(pageID: page.document.id, page: page.name, context: reference.context, label: reference.label, line: reference.line)
                switch reference.link.target {
                case .document:
                    // Not on a card; the References tab lists it.
                    break
                case .annotation(let id):
                    found[id, default: []].append(backlink)
                case .passage(let words, let before):
                    let markdown = text ?? ((try? current.document.readFile()) ?? "")
                    text = markdown
                    let ranges = placed ?? TextSurface.anchor(currentStore.pending, in: markdown)
                    placed = ranges
                    guard let passage = TextSurface.anchorPassage(text: words, before: before, in: markdown) else { continue }
                    for (id, range) in ranges where NSIntersectionRange(range, passage).length > 0 || range.location == passage.location {
                        found[id, default: []].append(backlink)
                    }
                }
            }
        }
        return found.mapValues { $0.sorted { ($0.page, $0.line) < ($1.page, $1.line) } }
    }

    // MARK: the wiki

    /// The file a `[[link]]` means: a page of the set's folders, else another file of the set.
    private func page(of link: WikiLink) -> Workspace.Entry? {
        let entries = workspace.entries
        return WikiLinks.resolve(link.name, among: entries.map(\.name), inWiki: entries.map(\.inFolder)).map { entries[$0] }
    }

    override func linkState(_ url: URL) -> PreviewBuilder.LinkState {
        guard url.host == "wiki" else { return super.linkState(url) }
        guard let link = WikiLink(url: url) else { return .live }
        return page(of: link) == nil ? .dead("“\(link.name)” isn't in the wiki or the set") : .live
    }

    override func follow(_ url: URL) {
        guard url.host == "wiki" else { return super.follow(url) }
        guard let link = WikiLink(url: url), let entry = page(of: link) else { return }
        // `[[page#heading]]`: the page, then the heading selected.
        openFile(entry.document.id) { [weak self] in
            if let heading = link.heading { self?.annotations.reveal(passage: heading, before: "") }
        }
    }

    /// The file's name, and where else the same file is in the set (another branch or worktree).
    private func subtitle(of entry: Workspace.Entry) -> String {
        SidebarTree.subtitle(
            name: entry.name, checkout: entry.checkout,
            others: workspace.entries.compactMap { other in other.checkout.map { (name: other.name, checkout: $0) } }
        )
    }

    /// The files of the set's folders, by id, with their names as the notice gives them.
    private static func namesInFolders(_ workspace: Workspace) -> [String: String] {
        var names: [String: String] = [:]
        for entry in workspace.entries where entry.inFolder {
            names[entry.document.id] = (entry.name as NSString).lastPathComponent
        }
        return names
    }

    // MARK: changing the set

    @objc func addFilesToSet(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AppDelegate.markdownTypes
        panel.message = "Choose markdown files to add to “\(setName)”"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK { self?.add(panel.urls) }
        }
    }

    func add(_ files: [URL]) {
        do {
            try Rust.setAdd(setName, files: files)
            workspace.reload()
        } catch {
            present(error)
        }
    }

    @objc func removeFromSet(_ sender: Any?) {
        if let id = sidebar.selectedID { remove(id) }
    }

    /// Takes a file out of the set; the file itself and its annotations stay on disk. The
    /// last file stays: a set needs one to open on. A file in one of the set's folders stays too:
    /// it is in the set because it is in the folder.
    func remove(_ id: String, completion: (() -> Void)? = nil) {
        guard workspace.entries.count > 1, let document = workspace.document(id: id),
              workspace.entries.first(where: { $0.document.id == id })?.inFolder == false else {
            completion?()
            return
        }
        let finish = { [weak self] in
            guard let self else { return }
            do {
                try Rust.setRemove(self.setName, files: [document.file])
                self.workspace.reload()
            } catch {
                self.present(error)
            }
            completion?()
        }
        // Leave the file first, while the set still resolves it.
        if id == currentID, let other = workspace.entries.first(where: { $0.document.id != id }) {
            openFile(other.document.id, completion: finish)
        } else {
            finish()
        }
    }

    @objc func deleteSet(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete the set “\(setName)”?"
        alert.informativeText = "Only the list is deleted. The files and their annotations stay where they are."
        alert.addButton(withTitle: "Delete Set")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.performDeleteSet() }
        }
    }

    func performDeleteSet() {
        do {
            try Rust.setDelete(setName)
            window?.close()
        } catch {
            present(error)
        }
    }

    private func present(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not change the set"
        alert.informativeText = "\(error)"
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(removeFromSet(_:)) {
            guard let id = sidebar.selectedID else { return false }
            return workspace.entries.count > 1 && workspace.entries.first { $0.document.id == id }?.inFolder == false
        }
        return super.validateMenuItem(item)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        onClose?()
    }
}
