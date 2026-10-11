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
    private let removeButton = NSButton()

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

    // MARK: view

    override func loadView() {
        table.style = .sourceList
        table.headerView = nil
        table.allowsEmptySelection = false
        table.rowSizeStyle = .default
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
        scroll.automaticallyAdjustsContentInsets = true

        // The + and − bar of Xcode's and Finder's source lists.
        let add = Self.barButton("plus", "Add Files to Set…", self, #selector(addClicked))
        removeButton.image = NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove from Set")
        removeButton.isBordered = false
        removeButton.contentTintColor = .secondaryLabelColor
        removeButton.toolTip = "Remove from Set"
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        let bar = NSStackView(views: [add, removeButton])
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 6, right: 10)
        bar.alignment = .centerY
        bar.distribution = .gravityAreas
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        bar.addView(spacer, in: .trailing)

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [scroll, separator, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        stack.alignment = .width
        view = stack
        reload()
    }

    private static func barButton(_ symbol: String, _ label: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let button = NSButton()
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.target = target
        button.action = action
        return button
    }

    @objc private func addClicked() { onAdd?() }

    @objc private func removeClicked() {
        if let id = selectedID { onRemove?(id) }
    }

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
        removeButton.isEnabled = entries.count > 1
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
            let cell = NSTableCellView()
            cell.textField = label
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
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
