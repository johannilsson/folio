import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Files named on the command line (`Folio notes.md`); Finder and `open` go through AppKit.
    let initialFiles: [URL]

    init(initialFiles: [URL]) {
        self.initialFiles = initialFiles
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: AppConfig.dist.appendingPathComponent("index.html").path) else {
            fputs("no index.html in \(AppConfig.dist.path); run `pnpm build` in frontend/\n", stderr)
            exit(66)
        }
        NSApp.mainMenu = buildMenu()
        NSApp.activate(ignoringOtherApps: true)

        if AppConfig.selfTest {
            runSelfTest()
        } else {
            for url in initialFiles { open(url) }
        }
    }

    private func open(_ url: URL, completion: ((FolioDocument?) -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, error in
            if let error { NSApp.presentError(error) }
            completion?(document as? FolioDocument)
        }
    }

    // MARK: launching without a file

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        initialFiles.isEmpty && !AppConfig.selfTest
    }

    /// Nothing to show yet: ask for a file, at launch and when the Dock icon is clicked.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.openDocument(nil)
        return true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.openDocument(nil) }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

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

    // MARK: menus

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            menu.addItem(item)
        }
        if !urls.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
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
            m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }

        // WKWebView only gets cut/copy/paste/undo from the responder chain; these items
        // have no target, so they reach it as first responder.
        _ = add("Edit") { m in
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            let redo = m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            redo.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }

        _ = add("View") { m in
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
            m.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        }
        NSApp.windowsMenu = window

        return main
    }
}
