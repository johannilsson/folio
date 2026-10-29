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

    override func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                          willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == .sidebarTrackingSeparator, let split {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
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
        content.view = contentRoot
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)
        sidebarSplitItem = sidebarItem
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "FolioSetSplit"
        self.split = split
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1100, height: 800))
        installToolbar()

        window?.delegate = self
        window?.title = info.name
        window?.subtitle = workspace.entries[0].name
        windowFrameAutosaveName = "FolioSetWindow"

        sidebar.onSelect = { [weak self] id in self?.openFile(id) }
        sidebar.onAdd = { [weak self] in self?.addFilesToSet(nil) }
        sidebar.onRemove = { [weak self] id in self?.remove(id) }
        workspace.onChange = { [weak self] in self?.filesChanged() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: following the files

    override func workspaceEvent(_ type: String, _ id: String) {
        super.workspaceEvent(type, id)
        // Annotations came or went in some file: its badge moves.
        if type == "folio:changed" { sidebar.reload() }
    }

    /// Opens a file of the set in the editor, in place. `completion` runs once the new file is shown.
    func openFile(_ id: String, completion: (() -> Void)? = nil) {
        guard id != currentID, let entry = workspace.entries.first(where: { $0.document.id == id }) else {
            completion?()
            return
        }
        rememberScroll(of: currentID)
        currentID = id
        window?.subtitle = entry.name
        sidebar.select(id)
        // The source shows the file it was opened on until it is told otherwise. It comes first: the
        // annotation UI then hands the new file's annotations to it.
        if mode == .source { scrollHost.source.load(entry.document) }
        scrollHost.preview.load(entry.document)
        annotations.fileChanged(store: currentStore)
        restoreScroll(of: id)
        completion?()
    }

    /// The manifest changed (here or from a terminal): refresh the sidebar, and move off a
    /// file that is no longer in the set.
    private func filesChanged() {
        sidebar.reload()
        if !workspace.entries.contains(where: { $0.document.id == currentID }), let first = workspace.entries.first {
            openFile(first.document.id)
        } else if let entry = workspace.entries.first(where: { $0.document.id == currentID }) {
            window?.subtitle = entry.name
        }
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
    /// last file stays: a set needs one to open on.
    func remove(_ id: String, completion: (() -> Void)? = nil) {
        guard workspace.entries.count > 1, let document = workspace.document(id: id) else {
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
            return workspace.entries.count > 1 && sidebar.selectedID != nil
        }
        return super.validateMenuItem(item)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        onClose?()
    }
}
