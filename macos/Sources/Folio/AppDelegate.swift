import AppKit
import FolioKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Files named on the command line (`Folio notes.md`); Finder and `open` go through AppKit.
    let initialFiles: [URL]

    init(initialFiles: [URL]) {
        self.initialFiles = initialFiles
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: AppConfig.dist.appendingPathComponent("diagram.html").path) else {
            fputs("no diagram.html in \(AppConfig.dist.path); run `pnpm build` in frontend/\n", stderr)
            exit(66)
        }
        // From `swift run` there is no bundle to hold the icon; use the one in the checkout.
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
            let checkoutIcon = AppConfig.dist.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("macos/Resources/AppIcon.icns")
            if let icon = NSImage(contentsOf: checkoutIcon) { NSApp.applicationIconImage = icon }
        }
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)
        watchWindowsForWelcome()

        switch AppConfig.appearance {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        // Claude's MCP server asks this app what the reader has open, once the person has allowed MCP clients
        // (Folio ▸ Allow MCP Clients). The self-test starts it on a socket of its own.
        if !AppConfig.selfTest && Rust.mcpAllowed { MainActor.assumeIsolated { _ = AppServer.start() } }

        if AppConfig.selfTest {
            runSelfTest()
        } else if let name = AppConfig.openSet {
            let window = openSet(name)
            if let path = AppConfig.screenshot, let window {
                Task { @MainActor in
                    await Screenshot.run(window, to: path)
                    exit(0)
                }
            }
        } else {
            for url in initialFiles { open(url) }
        }
    }

    func open(_ url: URL, completion: ((FolioDocument?) -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error) }
            completion?(document as? FolioDocument)
        }
    }

    // MARK: sets

    static let markdownTypes: [UTType] = [UTType("net.daringfireball.markdown"), UTType(filenameExtension: "md")]
        .compactMap { $0 }

    /// The open set windows by set name, so opening a set again brings its window forward.
    private var setWindows: [String: SetWindowController] = [:]

    /// Opens the set in a window, or brings its window forward. A set with no files yet asks
    /// for some first, since the window needs a file to open on.
    @discardableResult
    func openSet(_ name: String) -> SetWindowController? {
        if let existing = setWindows[name] {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            return existing
        }
        do {
            var info = try Rust.setLoad(name)
            if info.files.isEmpty {
                guard let files = chooseMarkdownFiles(message: "“\(name)” has no files yet. Choose some to add."), !files.isEmpty else { return nil }
                try Rust.setAdd(name, files: files)
                info = try Rust.setLoad(name)
            }
            let controller = SetWindowController(set: info)
            setWindows[name] = controller
            controller.onClose = { [weak self] in self?.setWindows[name] = nil }
            controller.showWindow(nil)
            return controller
        } catch {
            NSApp.presentError(error)
            return nil
        }
    }

    /// File > New Set…: a name, then the files to start with.
    @objc func newSet(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "New Set"
        alert.informativeText = "A set groups markdown files, from any folders, in one window. Name it with letters, digits, “-”, “_” and “.”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "checkout-redesign"
        alert.accessoryView = field
        alert.addButton(withTitle: "Choose Files…")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let files = chooseMarkdownFiles(message: "Choose the markdown files for “\(name)”"), !files.isEmpty else { return }
        do {
            try Rust.setAdd(name, files: files)
            openSet(name)
        } catch {
            NSApp.presentError(error)
        }
    }

    private func chooseMarkdownFiles(message: String) -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : nil
    }

    @objc private func openSetFromMenu(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String { openSet(name) }
    }

    // `folio open --set <name>` arrives as folio://set/<name>, `folio link` URLs as
    // folio://annotation/<id>?file=<path>; files as file URLs, which the document controller handles.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "folio", url.host == "set" {
                openSet(url.lastPathComponent)
            } else if url.scheme == "folio", url.host == "annotation" {
                openAnnotation(url)
            } else if url.isFileURL {
                open(url)
            }
        }
    }

    /// Opens the file of a folio://annotation/<id>?file=<path> link and brings the annotation into view.
    /// A link to an annotation that is resolved, or gone, just opens the file.
    func openAnnotation(_ link: URL) {
        let id = link.lastPathComponent
        guard let path = URLComponents(url: link, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "file" })?.value, !id.isEmpty, id != "/" else { return }
        // Same as the MCP `reveal`: a file that a set window has opens there, not in a window of its own.
        MainActor.assumeIsolated { _ = AppServer.reveal(URL(fileURLWithPath: path), annotation: id) }
    }

    // MARK: launching without a file

    private(set) lazy var welcome = WelcomeWindowController(app: self)

    private func watchWindowsForWelcome() {
        let center = NotificationCenter.default
        // A document or set window coming forward puts the welcome window away.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.object as? NSWindow)?.windowController is EditorWindowController,
                  self?.welcome.window?.isVisible == true else { return }
            self?.welcome.close()
        }
        // Closing the last one brings it back, in the same turn so the app is never without a
        // window: it quits only when the welcome window itself is closed.
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let closing = note.object as? NSWindow, closing.windowController is EditorWindowController else { return }
            let others = NSApp.windows.contains {
                $0 !== closing && $0.windowController is EditorWindowController && ($0.isVisible || $0.isMiniaturized)
            }
            if !others { self?.showWelcome(nil) }
        }
    }

    /// Window ▸ Welcome to Folio, and what launching with nothing to open shows.
    @objc func showWelcome(_ sender: Any?) { welcome.show() }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        initialFiles.isEmpty && !AppConfig.selfTest && AppConfig.openSet == nil
    }

    /// Nothing to show yet: the welcome window, at launch and when the Dock icon is clicked.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        showWelcome(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppServer.stop() }
    }

    // MARK: MCP

    /// Folio ▸ Allow MCP Clients: MCP clients read and annotate documents only while this is on, and it is off
    /// until the person turns it on, here or in Connect to MCP Clients….
    @MainActor @objc func toggleMCP(_ sender: Any?) {
        do {
            try AppServer.allow(!Rust.mcpAllowed)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Folio could not change who it lets in"
            alert.informativeText = (error as? RustError)?.description ?? error.localizedDescription
            alert.runModal()
        }
    }

    /// Folio ▸ Connect to MCP Clients…: what to run or paste to register the app's MCP server in each tool,
    /// and for some tools a button that writes it into their config.
    @MainActor @objc func connectTools(_ sender: Any?) {
        do {
            ConnectToolsAlert(snippets: try AppServer.clientSnippets()).run()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Folio could not prepare the settings"
            alert.informativeText = (error as? RustError)?.description ?? error.localizedDescription
            alert.runModal()
        }
    }

    // MARK: self-test

    private func runSelfTest() {
        Task { @MainActor in
            let ok = await SelfTest(app: self, source: initialFiles[0]).run()
            exit(ok ? 0 : 1)
        }
    }

    func openForSelfTest(_ url: URL) async -> FolioWindowController? {
        await withCheckedContinuation { continuation in
            open(url) { document in
                continuation.resume(returning: document?.windowControllers.first as? FolioWindowController)
            }
        }
    }

    var openSetCount: Int { setWindows.count }

    // MARK: menus

    // MARK: undo

    /// In the source, Undo goes back through the text view's history, which has the annotation
    /// actions in it. In the preview it takes back the last annotation action (a rejected
    /// suggestion, a reply). A text field of the annotation UI keeps its own undo.
    @MainActor @objc private func undoEdit(_ sender: Any?) {
        let responder = frontWindow?.firstResponder
        if frontEditor?.annotations.undo(from: responder) == true { return }
        responder?.tryToPerform(Selector(("undo:")), with: sender)
    }

    @MainActor @objc private func redoEdit(_ sender: Any?) {
        let responder = frontWindow?.firstResponder
        if frontEditor?.annotations.redo(from: responder) == true { return }
        responder?.tryToPerform(Selector(("redo:")), with: sender)
    }

    /// Undo and Redo are greyed out when there is nothing to undo; Allow MCP Clients is ticked while it is on.
    @MainActor func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let responder = frontWindow?.firstResponder
        switch item.action {
        case #selector(undoEdit(_:)):
            return frontEditor?.annotations.canUndo(from: responder) ?? responder?.undoManager?.canUndo ?? false
        case #selector(redoEdit(_:)):
            return frontEditor?.annotations.canRedo(from: responder) ?? responder?.undoManager?.canRedo ?? false
        case #selector(toggleMCP(_:)):
            item.state = Rust.mcpAllowed ? .on : .off
            return true
        default: return true
        }
    }

    @MainActor private var frontEditor: EditorWindowController? {
        frontWindow?.windowController as? EditorWindowController
    }

    /// The window Undo is for: the key window, or the front editor window if the app is not active.
    @MainActor private var frontWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.orderedWindows.first { $0.windowController is EditorWindowController }
    }

    /// File ▸ Open Recent ▸ Clear Menu: the list in `recents.json`, AppKit's (the Dock menu) and the welcome window's.
    @objc private func clearRecents(_ sender: Any?) {
        welcome.clearRecents()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu.title == "Open Set" {
            let names = (try? Rust.setNames()) ?? []
            for name in names {
                let item = NSMenuItem(title: name, action: #selector(openSetFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                menu.addItem(item)
            }
            if names.isEmpty {
                let none = NSMenuItem(title: "No Sets", action: nil, keyEquivalent: "")
                none.isEnabled = false
                menu.addItem(none)
            }
            return
        }
        let urls = RecentFiles.list()
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecents(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        func add(_ title: String, _ build: (NSMenu) -> Void) -> NSMenu {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
            return menu
        }

        _ = add("Folio") { m in
            m.addItem(withTitle: "About Folio", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Allow MCP Clients", action: #selector(toggleMCP(_:)), keyEquivalent: "").target = self
            m.addItem(withTitle: "Connect to MCP Clients…", action: #selector(connectTools(_:)), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Hide Folio", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            let others = m.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            others.keyEquivalentModifierMask = [.command, .option]
            m.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        }

        _ = add("File") { m in
            m.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
            let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu(title: "Open Recent")
            recentMenu.delegate = self
            recent.submenu = recentMenu
            m.addItem(recent)
            m.addItem(.separator())

            // Sets: the first two act on the app, the next three on the set window in front.
            let new = m.addItem(withTitle: "New Set…", action: #selector(newSet(_:)), keyEquivalent: "n")
            new.keyEquivalentModifierMask = [.command, .shift]
            new.target = self
            let sets = NSMenuItem(title: "Open Set", action: nil, keyEquivalent: "")
            let setsMenu = NSMenu(title: "Open Set")
            setsMenu.delegate = self
            sets.submenu = setsMenu
            m.addItem(sets)
            m.addItem(withTitle: "Add Files to Set…", action: #selector(SetWindowController.addFilesToSet(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Remove from Set", action: #selector(SetWindowController.removeFromSet(_:)), keyEquivalent: "")
            m.addItem(withTitle: "Delete Set…", action: #selector(SetWindowController.deleteSet(_:)), keyEquivalent: "")
            m.addItem(.separator())
            m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }

        // Cut/copy/paste have no target, so they reach the first responder. Undo and Redo first ask the
        // window's annotation actions.
        _ = add("Edit") { m in
            m.addItem(withTitle: "Undo", action: #selector(undoEdit(_:)), keyEquivalent: "z").target = self
            let redo = m.addItem(withTitle: "Redo", action: #selector(redoEdit(_:)), keyEquivalent: "z")
            redo.target = self
            redo.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            m.addItem(.separator())
            m.addItem(withTitle: "Find…", action: #selector(EditorWindowController.showFind(_:)), keyEquivalent: "f")
            m.addItem(withTitle: "Find Next", action: #selector(EditorWindowController.findNext(_:)), keyEquivalent: "g")
            let previous = m.addItem(withTitle: "Find Previous", action: #selector(EditorWindowController.findPrevious(_:)), keyEquivalent: "g")
            previous.keyEquivalentModifierMask = [.command, .shift]
        }

        _ = add("View") { m in
            // Only set windows have a sidebar, so this is dimmed in the others.
            let sidebar = m.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
            sidebar.keyEquivalentModifierMask = [.command, .control]
            m.addItem(.separator())
            let source = m.addItem(withTitle: "Toggle Markdown Source", action: #selector(FolioWindowController.toggleSource(_:)), keyEquivalent: "p")
            source.keyEquivalentModifierMask = [.command, .shift]
            let comments = m.addItem(withTitle: "Toggle Comments", action: #selector(FolioWindowController.toggleComments(_:)), keyEquivalent: "m")
            comments.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            let full = m.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            full.keyEquivalentModifierMask = [.command, .control]
        }

        let window = add("Window") { m in
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
            m.addItem(.separator())
            let welcome = m.addItem(withTitle: "Welcome to Folio", action: #selector(showWelcome(_:)), keyEquivalent: "1")
            welcome.keyEquivalentModifierMask = [.command, .shift]
            welcome.target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
        NSApp.windowsMenu = window

        return main
    }
}
