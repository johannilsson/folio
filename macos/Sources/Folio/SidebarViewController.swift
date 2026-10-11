import AppKit

/// The source list of a set window: the set's files grouped by repo, each with its count
/// of unresolved annotations.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    private enum Row {
        case header(String)
        case file(id: String, name: String, pending: Int)
    }

    private let workspace: Workspace
    private var rows: [Row] = []
    private let table = NSTableView()

    /// The user picked a file.
    var onSelect: ((String) -> Void)?
    /// The + button, and "Remove from Set" for the selected file.
    var onAdd: (() -> Void)?
    var onRemove: ((String) -> Void)?

    private var selecting = false

    init(workspace: Workspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: what the tests look at

    var fileIDs: [String] { rows.compactMap { if case .file(let id, _, _) = $0 { return id } else { return nil } } }
    var headerTitles: [String] { rows.compactMap { if case .header(let title) = $0 { return title } else { return nil } } }
    var selectedID: String? {
        guard table.selectedRow >= 0, case .file(let id, _, _) = rows[table.selectedRow] else { return nil }
        return id
    }
    func badge(for id: String) -> Int? {
        for case .file(let rowID, _, let pending) in rows where rowID == id { return pending }
        return nil
    }
    /// The selected row draws the soft grey selection with accent-colored text.
    var selectedRowIsSoft: Bool {
        guard let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: false) as? SoftSelectionRowView else { return false }
        return !row.isEmphasized && row.isSelected
    }

    // MARK: view

    override func loadView() {
        table.style = .sourceList
        table.headerView = nil
        table.allowsEmptySelection = false
        table.rowSizeStyle = .custom  // the system size follows the "Sidebar icon size" setting, which can be as tight as 20pt
        table.rowHeight = 34
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file")))
        table.dataSource = self
        table.delegate = self

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

        let root = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        add.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        root.addSubview(add)
        NSLayoutConstraint.activate([
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

    @objc private func addClicked() { onAdd?() }

    // MARK: content

    /// Rebuilds the rows, keeping the selection where the file still exists.
    func reload() {
        let keep = selectedID
        let entries = workspace.entries
        // Repo headings only earn their space when the set spans several roots.
        let multiRoot = Set(entries.map(\.group)).count > 1
        var next: [Row] = []
        var group: String?
        for entry in entries {
            if multiRoot && entry.group != group {
                group = entry.group
                next.append(.header(entry.group))
            }
            next.append(.file(id: entry.document.id, name: entry.name, pending: entry.document.pendingCount()))
        }
        rows = next
        // Reloading drops the selection and the table selects the first row again, which
        // must not be taken for the user picking that file.
        selecting = true
        table.reloadData()
        selecting = false
        if let keep { select(keep) } else if let first = fileIDs.first { select(first) }
    }

    /// Highlights a file without announcing it, for when the page moved on its own.
    func select(_ id: String) {
        guard let index = rows.firstIndex(where: { if case .file(let rowID, _, _) = $0 { return rowID == id } else { return false } }) else { return }
        selecting = true
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        selecting = false
    }

    /// What clicking the file does: highlight it and open it.
    func choose(_ id: String) {
        select(id)
        onSelect?(id)
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 36 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        SoftSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .header = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
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

        case .file(_, let name, let pending):
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

            let stack = NSStackView(views: [icon, label, count])
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
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !selecting, let id = selectedID else { return }
        onSelect?(id)
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard table.clickedRow >= 0, case .file(let id, _, _) = rows[table.clickedRow] else { return }
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(reveal(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = id
        menu.addItem(reveal)
        let remove = NSMenuItem(title: "Remove from Set", action: #selector(removeFromMenu(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = id
        remove.isEnabled = workspace.entries.count > 1
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
