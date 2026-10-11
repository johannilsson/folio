import AppKit
import UniformTypeIdentifiers

/// A window for a named set of files: a sidebar of the files beside the editor, which
/// swaps documents in place. The set itself lives in ~/.config/folio/sets, shared with
/// `folio set`, so the sidebar follows changes made from a terminal too.
final class SetWindowController: EditorWindowController, NSWindowDelegate, NSMenuItemValidation {
    let sidebar: SidebarViewController
    private(set) var currentID: String

    /// The window closed; the app stops tracking it.
    var onClose: (() -> Void)?

    var setName: String { workspace.setName ?? "" }

    override var leadingToolbarItems: [NSToolbarItem.Identifier] { [.toggleSidebar] }

    /// `info` must have at least one file: the page opens on the first.
    init(set info: Rust.SetInfo) {
        let workspace = Workspace(set: info)
        sidebar = SidebarViewController(workspace: workspace)
        currentID = workspace.entries[0].document.id
        super.init(workspace: workspace, entryURL: SchemeHandler.entryURL(file: workspace.entries[0].document.id))

        // The editor goes in the content pane of a split view, with the sidebar beside it.
        let content = NSViewController()
        content.view = webView
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.maximumThickness = 340
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.splitView.autosaveName = "FolioSetSplit"
        window?.contentViewController = split
        window?.setContentSize(NSSize(width: 1100, height: 800))

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

    // MARK: following the page

    override func workspaceEvent(_ type: String, _ id: String) {
        super.workspaceEvent(type, id)
        // Annotations came or went in some file: its badge moves.
        if type == "folio:changed" { sidebar.reload() }
    }

    /// Opens a file of the set in the editor, in place. `completion` runs once the page has
    /// saved the file it left and shows the new one.
    func openFile(_ id: String, completion: (() -> Void)? = nil) {
        guard id != currentID, let entry = workspace.entries.first(where: { $0.document.id == id }) else {
            completion?()
            return
        }
        currentID = id
        window?.subtitle = entry.name
        sidebar.select(id)
        webView.callAsyncJavaScript(
            """
            if (typeof window.__folioSwitchFile !== 'function') return false
            await window.__folioSwitchFile(id)
            return true
            """,
            arguments: ["id": id], in: nil, in: .page
        ) { [weak self] result in
            // The page is not ready to swap (still booting): load it on that file instead.
            if case .success(let swapped) = result, swapped as? Bool == true {} else {
                self?.webView.load(URLRequest(url: SchemeHandler.entryURL(file: id)))
            }
            completion?()
        }
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
        // Leave the file first, so the page saves it while the set still resolves it.
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

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(removeFromSet(_:)) {
            return workspace.entries.count > 1 && sidebar.selectedID != nil
        }
        return true
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopWatching()
        onClose?()
    }
}
