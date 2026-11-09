import AppKit
import FolioKit

/// The source list of a set window: the set's files grouped by repo, each with its count
/// of unresolved annotations, then each of the set's folders as a tree of its markdown files.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        /// The open items of the whole set, above its files, when there are any.
        case openList(count: Int)
        case header(String)
        /// A subfolder of one of the set's folders (`group`), at `path` in it; `depth` 1 is
        /// directly in it. Clicking it folds or unfolds its files.
        case folder(name: String, group: String, path: String, depth: Int, collapsed: Bool)
        /// `depth` is how far below its set folder a file is (0 for a file added on its own).
        case file(id: String, name: String, pending: Int, depth: Int)

        var fileID: String? {
            if case .file(let id, _, _, _) = self { return id }
            return nil
        }
    }

    private let workspace: Workspace
    private var rows: [Row] = []
    private let table = NSTableView()

    /// The user picked a file.
    var onSelect: ((String) -> Void)?
    /// The + button, and "Remove from Set" for the selected file.
    var onAdd: (() -> Void)?
    var onRemove: ((String) -> Void)?
    /// A file's mark (new, changed underneath), from the window controller, which keeps them.
    var mark: (String) -> SidebarTree.Mark? = { _ in nil }
    /// The user picked the Open row.
    var onOpenList: (() -> Void)?
    /// How many open items the set has: the Open row is there while it has any.
    var openCount = 0 {
        didSet { if openCount != oldValue, isViewLoaded { reload() } }
    }
    /// The Open row is the selected one: the window shows the list, not a file.
    private var openSelected = false

    /// The subfolders folded away, by the set folder they are in: a reader's choice for this
    /// window, kept across reloads.
    private var collapsed: [String: Set<String>] = [:]
    /// The file the window shows, highlighted whenever its row is in the list (a folded folder
    /// can hide it).
    private var shownID: String?

    private let notice = NSTextField(wrappingLabelWithString: "")
    private var noticeShown = 0

    private var selecting = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: what the tests look at

    var fileIDs: [String] { rows.compactMap(\.fileID) }
    var headerTitles: [String] { rows.compactMap { if case .header(let title) = $0 { return title } else { return nil } } }
    var folderTitles: [String] { rows.compactMap { if case .folder(let name, _, _, _, _) = $0 { return name } else { return nil } } }
    /// The folded subfolders, by name.
    var collapsedTitles: [String] {
        rows.compactMap { if case .folder(let name, _, _, _, true) = $0 { return name } else { return nil } }
    }
    var fileNames: [String] { rows.compactMap { if case .file(_, let name, _, _) = $0 { return name } else { return nil } } }
    var selectedID: String? {
        guard table.selectedRow >= 0 else { return nil }
        return rows[table.selectedRow].fileID
    }
    /// The count on the Open row, nil when there is none.
    var openRowCount: Int? {
        for case .openList(let count) in rows { return count }
        return nil
    }
    var openRowSelected: Bool {
        guard table.selectedRow >= 0, case .openList = rows[table.selectedRow] else { return false }
        return true
    }
    func badge(for id: String) -> Int? {
        for case .file(let rowID, _, let pending, _) in rows where rowID == id { return pending }
        return nil
    }
    /// The notice at the bottom, while it shows.
    var noticeText: String? { notice.isHidden ? nil : notice.stringValue }
    /// The selected row draws the soft grey selection with accent-colored text.
    var selectedRowIsSoft: Bool {
        guard let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: false) as? SoftSelectionRowView else { return false }
        return !row.isEmphasized && row.isSelected
    }

    // MARK: view

    override func loadView() {
        table.style = .sourceList
        table.headerView = nil
        // A folded folder can hide the file on screen, leaving no row to highlight.
        table.allowsEmptySelection = true
        table.rowSizeStyle = .custom  // the system size follows the "Sidebar icon size" setting, which can be as tight as 20pt
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        // Room at the bottom for the add button, which floats over the list.
        scroll.contentInsets = NSEdgeInsets(top: 10, left: 0, bottom: 52, right: 0)

        // A single circled plus at the bottom-left with no bar behind it, as in Preview and
        // other recent system sidebars. Removing a file is in the row's context menu and the
        // File menu.
        let add = NSButton()
        add.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: "Add Files to Set…")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.toolTip = "Add Files to Set…"
        add.target = self
        add.action = #selector(addClicked)

        // What changed on disk in the set's folders, for a few seconds.
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.maximumNumberOfLines = 2
        notice.isHidden = true

        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        add.translatesAutoresizingMaskIntoConstraints = false
        notice.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(add)
        root.addSubview(notice)
        NSLayoutConstraint.activate([
            notice.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
        ])
        view = root
        reload()
    }

    // The sidebar runs under the title bar, so the list starts below it (and the traffic lights).
    override func viewDidLayout() {
        super.viewDidLayout()
        guard let scroll = table.enclosingScrollView else { return }
        let top = view.safeAreaInsets.top + 6
        guard scroll.contentInsets.top != top else { return }
        scroll.contentInsets = NSEdgeInsets(top: top, left: 0, bottom: scroll.contentInsets.bottom, right: 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -top))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @objc private func addClicked() { onAdd?() }

    // MARK: content

    /// Rebuilds the rows, keeping the selection where the file still exists.
    func reload() {
        let keep = shownID
        let keepOpen = openRowSelected || (openSelected && selectedID == nil)
        let picked = workspace.entries.filter { !$0.inFolder }
        let inFolders = workspace.entries.filter(\.inFolder)
        // Checkout headings (repo and branch) only earn their space when the set spans several
        // checkouts, or has folders too.
        let headings = SidebarTree.headings(picked.compactMap(\.checkout))
        let multiRoot = Set(picked.map(\.root)).count > 1 || (!picked.isEmpty && !inFolders.isEmpty)
        var next: [Row] = []
        if openCount > 0 { next.append(.openList(count: openCount)) }
        var root: URL?
        for entry in picked {
            if multiRoot && entry.root != root {
                root = entry.root
                next.append(.header(headings[entry.root.path] ?? entry.group))
            }
            next.append(.file(id: entry.document.id, name: entry.name, pending: entry.document.pendingCount(), depth: 0))
        }
        // Each folder under its name, its files as a tree (they come in tree order, folder by folder).
        var start = inFolders.startIndex
        while start < inFolders.endIndex {
            let name = inFolders[start].group
            let end = inFolders[start...].firstIndex { $0.group != name } ?? inFolders.endIndex
            let files = Array(inFolders[start..<end])
            next.append(.header(name))
            for row in SidebarTree.rows(files.map(\.name), collapsed: collapsed[name] ?? []) {
                switch row {
                case .folder(let folder, let path, let depth, let folded):
                    next.append(.folder(name: folder, group: name, path: path, depth: depth, collapsed: folded))
                case .file(let index, let file, let depth):
                    let entry = files[index]
                    next.append(.file(id: entry.document.id, name: file, pending: entry.document.pendingCount(), depth: depth))
                }
            }
            start = end
        }
        rows = next
        // Reloading drops the selection and the table selects the first row again, which
        // must not be taken for the user picking that file.
        selecting = true
        table.reloadData()
        selecting = false
        if keepOpen, openCount > 0 { selectOpenList() } else if let keep { highlight(keep) } else if let first = fileIDs.first { highlight(first) }
    }

    /// Folds a subfolder of a set folder away, or unfolds it.
    func toggleFolder(group: String, path: String) {
        if collapsed[group, default: []].remove(path) == nil { collapsed[group, default: []].insert(path) }
        reload()
    }

    /// Folds a subfolder by its name, for the tests.
    func toggleFolder(named name: String) {
        for case .folder(name, let group, let path, _, _) in rows {
            toggleFolder(group: group, path: path)
            return
        }
    }

    @objc private func rowClicked() {
        guard table.clickedRow >= 0, case .folder(_, let group, let path, _, _) = rows[table.clickedRow] else { return }
        toggleFolder(group: group, path: path)
    }

    /// Highlights the Open row without announcing it, for when the window shows the list on its own.
    func selectOpenList() {
        openSelected = true
        shownID = nil
        guard let index = rows.firstIndex(where: { if case .openList = $0 { return true } else { return false } }) else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selecting = false
    }

    /// What clicking the Open row does: highlight it and show the list.
    func chooseOpenList() {
        selectOpenList()
        onOpenList?()
    }

    /// Highlights a file without announcing it, for when the page moved on its own. A folded
    /// folder the file is in unfolds, so it shows.
    func select(_ id: String) {
        if let entry = workspace.entries.first(where: { $0.document.id == id }), entry.inFolder {
            let folders = SidebarTree.folders(containing: entry.name)
            if !collapsed[entry.group, default: []].isDisjoint(with: folders) {
                collapsed[entry.group]?.subtract(folders)
                openSelected = false
                shownID = id
                selecting = true
                table.deselectAll(nil)
                selecting = false
                reload()
                return
            }
        }
        highlight(id)
    }

    /// Highlights the file's row, or none while a folded folder hides it.
    private func highlight(_ id: String) {
        openSelected = false
        shownID = id
        selecting = true
        if let index = rows.firstIndex(where: { $0.fileID == id }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        selecting = false
    }

    /// Shows a line about files that changed on disk for a while; a newer one replaces it.
    func showNotice(_ text: String) {
        noticeShown += 1
        let shown = noticeShown
        notice.stringValue = text
        notice.isHidden = false
        setBottomInset(96)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.noticeShown == shown else { return }
            self.notice.isHidden = true
            self.setBottomInset(52)
        }
    }

    /// Room at the bottom of the list for what floats over it.
    private func setBottomInset(_ bottom: CGFloat) {
        guard let scroll = table.enclosingScrollView else { return }
        let insets = scroll.contentInsets
        scroll.contentInsets = NSEdgeInsets(top: insets.top, left: 0, bottom: bottom, right: 0)
    }

    /// What clicking the file does: highlight it and open it.
    func choose(_ id: String) {
        select(id)
        onSelect?(id)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch rows[row] {
        case .header: return 36
        case .folder: return 26
        case .file, .openList: return tableView.rowHeight
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .openList = rows[row] { return true }
        return rows[row].fileID != nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .openList(let count):
            let icon = NSImageView(image: NSImage(systemSymbolName: "checklist", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = NSTextField(labelWithString: "Open")
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            let badge = NSTextField(labelWithString: String(count))
            badge.font = .systemFont(ofSize: 11, weight: .medium)
            badge.textColor = .secondaryLabelColor
            badge.setContentHuggingPriority(.required, for: .horizontal)
            let stack = NSStackView(views: [icon, label, badge])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            let cell = NSTableCellView()
            cell.textField = label
            cell.imageView = icon
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            // Repo folder names can be long: cut them short rather than run into the edge.
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = title
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            // Indented to line up with the file icons below, and sitting near the bottom of its
            // row so there is air above the heading and it stays close to its own files.
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 22),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -12),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
            return cell

        case .folder(let name, _, _, let depth, let folded):
            let chevron = NSImageView(image: NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down",
                                                     accessibilityDescription: folded ? "Folded" : "Unfolded") ?? NSImage())
            chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            chevron.contentTintColor = .tertiaryLabelColor
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.widthAnchor.constraint(equalToConstant: 10).isActive = true
            let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = NSTextField(labelWithString: name)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = name
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            let stack = NSStackView(views: [chevron, icon, label])
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            let cell = NSTableCellView()
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.indent * CGFloat(depth - 1)),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell

        case .file(let id, let name, let pending, let depth):
            let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
            icon.contentTintColor = .secondaryLabelColor
            icon.setContentHuggingPriority(.required, for: .horizontal)
            let label = NSTextField(labelWithString: name)
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = name
            label.setContentCompressionResistancePriority(.init(1), for: .horizontal)

            let count = NSTextField(labelWithString: pending > 0 ? String(pending) : "")
            count.font = .systemFont(ofSize: 11, weight: .medium)
            count.textColor = .secondaryLabelColor
            count.isHidden = pending == 0
            count.toolTip = "\(pending) pending"
            count.setContentHuggingPriority(.required, for: .horizontal)

            // New since the window opened, or changed since the reader last looked at it.
            let marked = NSTextField(labelWithString: "")
            marked.textColor = .controlAccentColor
            switch mark(id) {
            case .new?:
                marked.stringValue = "NEW"
                marked.font = .systemFont(ofSize: 9, weight: .bold)
                marked.toolTip = "Added since the window opened"
            case .changed?:
                marked.stringValue = "●"
                marked.font = .systemFont(ofSize: 8)
                marked.toolTip = "Changed on disk"
            case nil:
                marked.isHidden = true
            }
            marked.setContentHuggingPriority(.required, for: .horizontal)

            let stack = NSStackView(views: [icon, label, marked, count])
            stack.orientation = .horizontal
            stack.spacing = 6
            stack.alignment = .centerY
            let cell = NSTableCellView()
            cell.textField = label
            cell.imageView = icon
            stack.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: Self.indent * CGFloat(depth)),
                stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }
    }

    /// How far a level of a folder's tree is indented.
    private static let indent: CGFloat = 14

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting else { return }
        // A click on empty space clears the selection: the shown file stays highlighted.
        if table.selectedRow < 0 {
            if let shownID, !openSelected { highlight(shownID) } else if openSelected { selectOpenList() }
            return
        }
        if openRowSelected {
            openSelected = true
            onOpenList?()
        } else if let id = selectedID {
            openSelected = false
            shownID = id
            onSelect?(id)
        }
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, let id = rows[table.clickedRow].fileID else { return }
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(reveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = id
        menu.addItem(reveal)
        let remove = NSMenuItem(title: "Remove from Set", action: #selector(removeFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        // A file in one of the set's folders is there because it is in the folder.
        remove.isEnabled = workspace.entries.count > 1 && workspace.entries.first { $0.document.id == id }?.inFolder == false
        menu.addItem(remove)
    }

    @objc private func reveal(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let file = workspace.document(id: id)?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { onRemove?(id) }
    }
}

/// A selected row as in Finder's sidebar: a soft grey rounded background with the name in the
/// accent color, instead of the strong accent fill with white text a key window gets by default.
final class SoftSelectionRowView: NSTableRowView {
    // Never emphasized, so the selection stays grey whether or not the window is active.
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override var isSelected: Bool {
        didSet { tint() }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 0), xRadius: 8, yRadius: 8).fill()
    }

    // The cell is added after the row view is created, so tint it when it arrives too.
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        tint()
    }

    private func tint() {
        for case let cell as NSTableCellView in subviews {
            cell.textField?.textColor = isSelected ? .controlAccentColor : .labelColor
            cell.imageView?.contentTintColor = isSelected ? .controlAccentColor : .secondaryLabelColor
        }
    }
}
