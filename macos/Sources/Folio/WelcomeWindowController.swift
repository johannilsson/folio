import AppKit
import FolioKit
import UniformTypeIdentifiers

/// The window Folio shows when there is nothing open, like Xcode's: the app and its actions on
/// the left, the sets and recent files on the right. Markdown files dropped on it open.
/// It closes once a document or set window comes forward (`AppDelegate` watches for that).
final class WelcomeWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    enum Row: Equatable {
        case header(String)
        case set(name: String, files: Int)
        case file(URL)
    }

    private weak var app: AppDelegate?
    private(set) var rows: [Row] = []
    private let table = WelcomeTable()
    private let empty = NSTextField(labelWithString: "No Sets or Recent Files")
    private let skillCard = WelcomeCard()
    private let skillBadge = NSTextField(labelWithString: "")
    private let skillPitch = NSTextField(wrappingLabelWithString: "")
    private let skillButton = NSButton(title: "", target: nil, action: nil)
    private(set) var skill: SkillStatus?

    init(app: AppDelegate) {
        self.app = app
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Welcome to Folio"
        window.isMovableByWindowBackground = true
        window.isExcludedFromWindowsMenu = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Brings the window forward with the lists as they are now, the first item selected.
    func show() {
        reload()
        showSkill(try? Rust.skillStatus())
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
        if let first = rows.firstIndex(where: isOpenable) {
            table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
            table.scrollRowToVisible(first)
        }
    }

    // MARK: view

    private func build() {
        let root = WelcomeDropView()
        root.onDrop = { [weak self] urls in self?.openDropped(urls) }

        // Left: the app, then what can be done.
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 128), icon.heightAnchor.constraint(equalToConstant: 128)])

        let name = NSTextField(labelWithString: "Folio")
        name.font = .systemFont(ofSize: 34, weight: .semibold)
        let version = NSTextField(labelWithString: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Version \($0)" } ?? "")
        version.font = .systemFont(ofSize: 13)
        version.textColor = .secondaryLabelColor
        version.isHidden = version.stringValue.isEmpty

        let openFile = WelcomeActionButton(title: "Open File…", symbol: "doc.text", target: self, action: #selector(openFile(_:)))
        openFile.setAccessibilityIdentifier("welcome-open")
        let newSet = WelcomeActionButton(title: "New Set…", symbol: "rectangle.stack.badge.plus", target: self, action: #selector(newSet(_:)))
        newSet.setAccessibilityIdentifier("welcome-new-set")
        let hint = NSTextField(labelWithString: "Or drop markdown files here")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let left = NSStackView(views: [icon, name, version, openFile, newSet, hint, buildSkillCard()])
        left.orientation = .vertical
        left.alignment = .centerX
        left.spacing = 8
        left.setCustomSpacing(4, after: icon)
        left.setCustomSpacing(2, after: name)
        left.setCustomSpacing(32, after: version)
        left.setCustomSpacing(10, after: newSet)
        left.setCustomSpacing(24, after: hint)

        // Right: the sets and recent files, in the sidebar's material.
        table.style = .inset
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.rowHeight = 44
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked(_:))
        table.onReturn = { [weak self] in self?.openSelected() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)

        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        let right = NSVisualEffectView()
        right.material = .sidebar
        right.blendingMode = .behindWindow

        for view in [left, right, scroll, empty] as [NSView] { view.translatesAutoresizingMaskIntoConstraints = false }
        root.addSubview(left)
        root.addSubview(right)
        right.addSubview(scroll)
        right.addSubview(empty)
        root.addSubview(root.highlight)
        NSLayoutConstraint.activate([
            right.topAnchor.constraint(equalTo: root.topAnchor),
            right.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            right.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            right.widthAnchor.constraint(equalToConstant: 320),
            scroll.topAnchor.constraint(equalTo: right.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: right.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: right.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: right.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: right.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: right.centerYAnchor),
            left.centerXAnchor.constraint(equalTo: root.leadingAnchor, constant: 220),
            left.centerYAnchor.constraint(equalTo: root.centerYAnchor, constant: -6),
            left.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -24),
            openFile.widthAnchor.constraint(equalToConstant: 240),
            newSet.widthAnchor.constraint(equalTo: openFile.widthAnchor),
            skillCard.widthAnchor.constraint(equalTo: openFile.widthAnchor),
        ])
        window?.contentView = root
    }

    /// The offer to install the agent skill: a title with a badge, a line about it, and the pill that acts.
    private func buildSkillCard() -> NSView {
        let title = NSTextField(labelWithString: "Agent Skill")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        skillBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        skillBadge.textColor = .secondaryLabelColor
        skillPitch.font = .systemFont(ofSize: 11)
        skillPitch.textColor = .secondaryLabelColor
        skillButton.bezelStyle = .rounded
        skillButton.controlSize = .small
        skillButton.target = self
        skillButton.action = #selector(installSkill(_:))
        skillButton.setAccessibilityIdentifier("welcome-skill-install")
        skillCard.setAccessibilityIdentifier("welcome-skill-card")

        let heading = NSStackView(views: [title, skillBadge])
        heading.spacing = 6
        let stack = NSStackView(views: [heading, skillPitch, skillButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        skillCard.translatesAutoresizingMaskIntoConstraints = false
        skillCard.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: skillCard.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: skillCard.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: skillCard.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: skillCard.trailingAnchor, constant: -12),
        ])
        skillPitch.preferredMaxLayoutWidth = 216
        return skillCard
    }

    /// Shows the skill's state on the card; the card is hidden while there is nothing to do, unless `keep`
    /// (right after installing, the card says Installed instead of vanishing).
    func showSkill(_ status: SkillStatus?, keep: Bool = false) {
        skill = status
        guard let status else { skillCard.isHidden = true; return }
        skillCard.isHidden = !status.needsAttention && !keep
        skillBadge.stringValue = status.badge ?? ""
        skillBadge.isHidden = status.badge == nil
        skillPitch.stringValue = status.pitch
        skillButton.title = status.buttonTitle
        skillButton.image = status.needsAttention ? nil : NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
        skillButton.imagePosition = .imageLeading
        skillButton.isEnabled = status.needsAttention
    }

    /// The card's pill: installs or updates the skill and shows what happened.
    @objc private func installSkill(_ sender: Any?) {
        app?.installSkill(self)
    }

    // MARK: content

    func reload() {
        var next: [Row] = []
        let sets = ((try? Rust.setNames()) ?? []).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if !sets.isEmpty {
            next.append(.header("Sets"))
            next += sets.map { .set(name: $0, files: (try? Rust.setLoad($0).allFiles.count) ?? 0) }
        }
        let recents = RecentFiles.list()
        if !recents.isEmpty {
            next.append(.header("Recent Files"))
            next += recents.map { .file($0) }
        }
        rows = next
        table.reloadData()
        empty.isHidden = !rows.isEmpty
    }

    private func isOpenable(_ row: Row) -> Bool {
        if case .header = row { return false }
        return true
    }

    // MARK: actions

    @objc private func openFile(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }
    @objc private func newSet(_ sender: Any?) { app?.newSet(sender) }

    @objc private func openClicked(_ sender: Any?) {
        if table.clickedRow >= 0 { open(rows[table.clickedRow]) }
    }

    func openSelected() {
        if table.selectedRow >= 0 { open(rows[table.selectedRow]) }
    }

    func open(_ row: Row) {
        switch row {
        case .header: break
        case .set(let name, _): app?.openSet(name)
        case .file(let url): app?.open(url)
        }
    }

    /// What a drop opens: the markdown files among the dropped ones.
    func openDropped(_ urls: [URL]) {
        for url in urls where WelcomeDropView.isMarkdown(url) { app?.open(url) }
    }

    /// Empties the list: ours, AppKit's (the Dock menu) and what is shown.
    func clearRecents() {
        RecentFiles.clear()
        NSDocumentController.shared.clearRecentDocuments(nil)
        reload()
    }

    /// Takes the file out of the list. AppKit's own list (the Dock menu) can only be cleared whole, so the rest
    /// are noted again, oldest first.
    func removeFromRecents(_ url: URL) {
        RecentFiles.remove(url)
        let controller = NSDocumentController.shared
        controller.clearRecentDocuments(nil)
        for other in RecentFiles.list().reversed() { controller.noteNewRecentDocumentURL(other) }
        reload()
    }

    /// Return opens the selection, as a double-click does.
    func pressReturn() {
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
    }

    func select(_ row: Row) {
        if let index = rows.firstIndex(of: row) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
    }

    // MARK: NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = rows[row] { return 28 }
        return tableView.rowHeight
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { isOpenable(rows[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        switch rows[row] {
        case .header(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
            ])
        case .set(let name, let files):
            fill(cell, icon: NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Set") ?? NSImage(),
                 tinted: true, title: name, detail: files == 1 ? "1 file" : "\(files) files", tip: name)
        case .file(let url):
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            fill(cell, icon: NSWorkspace.shared.icon(forFile: url.path), tinted: false,
                 title: url.lastPathComponent, detail: folder, tip: url.path)
        }
        return cell
    }

    private func fill(_ cell: NSTableCellView, icon image: NSImage, tinted: Bool, title: String, detail: String, tip: String) {
        let icon = NSImageView(image: image)
        if tinted {
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
        }
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        let sub = NSTextField(labelWithString: detail)
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingHead
        for label in [name, sub] { label.setContentCompressionResistancePriority(.init(1), for: .horizontal) }
        let text = NSStackView(views: [name, sub])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        cell.textField = name
        cell.imageView = icon
        cell.toolTip = tip
        for view in [icon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
    }

    // MARK: context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let index = table.clickedRow
        guard index >= 0 else { return }
        let row = rows[index]
        guard isOpenable(row) else { return }
        menu.addItem(withTitle: "Open", action: #selector(openClicked(_:)), keyEquivalent: "").target = self
        guard case .file(let url) = row else { return }
        let finder = menu.addItem(withTitle: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        finder.target = self
        finder.representedObject = url
        menu.addItem(.separator())
        let remove = menu.addItem(withTitle: "Remove from Recents", action: #selector(removeClicked(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = url
        menu.addItem(withTitle: "Clear All Recents", action: #selector(clearClicked(_:)), keyEquivalent: "").target = self
    }

    @objc private func showInFinder(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func clearClicked(_ sender: NSMenuItem) {
        clearRecents()
    }

    @objc private func removeClicked(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { removeFromRecents(url) }
    }
}

/// The list, with Return opening the selection.
private final class WelcomeTable: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() } else { super.keyDown(with: event) }
    }
}

/// A soft rounded fill, the same as behind the action buttons.
private final class WelcomeCard: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}

/// A wide button with a symbol and a title on a soft fill, like the actions of Xcode's welcome window.
private final class WelcomeActionButton: NSControl {
    private var pressed = false { didSet { needsDisplay = true } }

    convenience init(title: String, symbol: String, target: AnyObject, action: Selector) {
        self.init(frame: .zero)
        self.target = target
        self.action = action
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),
            icon.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(pressed ? 0.14 : 0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        // Track until the button is let go; it acts only if that is still over it.
        while let next = window?.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            if next.type == .leftMouseUp {
                pressed = false
                if inside { performClick(nil) }
                return
            }
            pressed = inside
        }
    }

    override func performClick(_ sender: Any?) { sendAction(action, to: target) }
    override func accessibilityPerformPress() -> Bool { performClick(nil); return true }
}

/// The window's content: takes dropped markdown files, outlined in the accent color while they hover.
final class WelcomeDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    let highlight = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        highlight.wantsLayer = true
        highlight.layer?.borderWidth = 3
        highlight.layer?.cornerRadius = 10
        highlight.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        highlight.frame = bounds.insetBy(dx: 2, dy: 2)
        highlight.layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    static func isMarkdown(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return AppDelegate.markdownTypes.contains { type.conforms(to: $0) }
    }

    private func markdownURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter(Self.isMarkdown)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let ok = !markdownURLs(sender).isEmpty
        highlight.isHidden = !ok
        return ok ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlight.isHidden = true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        let urls = markdownURLs(sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}
