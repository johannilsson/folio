import AppKit

/// The welcome window: what it lists, opening from it, and coming back when the last window closes.
/// It runs last, since it closes every document window.
extension SelfTest {
    func welcomeChecks() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        guard let member = try? tempCopy(named: "member.md"), let kept = try? tempCopy(named: "kept.md"),
              let dropped = try? tempCopy(named: "dropped.md"), (try? Rust.setAdd("welcome-demo", files: [member])) != nil else {
            report("the welcome window's files and set are created", false)
            return
        }
        // Two recent files, the one to remove noted last so it is first in the list.
        let documents = NSDocumentController.shared
        RecentFiles.note(kept)
        RecentFiles.note(member)
        func recents() -> [URL] { RecentFiles.list().map { $0.resolvingSymlinksInPath() } }
        let stored = config.appendingPathComponent("recents.json")
        let welcome = app.welcome
        func files() -> [URL] { welcome.rows.compactMap { if case .file(let url) = $0 { return url.resolvingSymlinksInPath() } else { return nil } } }

        app.showWelcome(nil)
        guard let window = welcome.window else {
            report("the welcome window exists", false)
            return
        }
        await check("Window ▸ Welcome to Folio has ⇧⌘1 and shows the welcome window") {
            let item = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Window" }?.item(withTitle: "Welcome to Folio")
            return item?.keyEquivalent == "1" && item?.keyEquivalentModifierMask == [.command, .shift] && window.isVisible
        }
        await check("the welcome window has only a close button, like Xcode's") {
            window.standardWindowButton(.closeButton)?.isHidden == false
                && window.standardWindowButton(.miniaturizeButton)?.isHidden == true
                && window.standardWindowButton(.zoomButton)?.isHidden == true
        }
        await check("it lists the sets, then the recent files, under their headings") {
            let headers = welcome.rows.compactMap { if case .header(let title) = $0 { return title } else { return nil } }
            return headers == ["Sets", "Recent Files"] && welcome.rows[1] == .set(name: "welcome-demo", files: 1)
                && Array(files().prefix(2)) == [member, kept]
        }
        await check("it has the Open File and New Set actions, and takes dropped files") {
            guard let content = window.contentView else { return false }
            return button("welcome-open", in: content) != nil && button("welcome-new-set", in: content) != nil
                && content.registeredDraggedTypes.contains(.fileURL)
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(nanoseconds: 700_000_000)
            WindowPicture.write(window, to: "\(base)-welcome.png")
        }

        welcome.removeFromRecents(member)
        await check("Remove from Recents takes the file out of the list and File ▸ Open Recent, keeping the rest in order") {
            let ok = await self.until {
                !files().contains(member) && !recents().contains(member) && recents().first == kept && files().first == kept
            }
            if !ok { print("    recents \(recents().prefix(3).map(\.lastPathComponent)), listed \(files().prefix(3).map(\.lastPathComponent))") }
            return ok
        }

        await check("the list is kept in recents.json, so it outlives a build") {
            let text = (try? String(contentsOf: stored, encoding: .utf8)) ?? ""
            return text.contains("kept.md") && !text.contains("member.md")
        }
        welcome.clearRecents()
        await check("Clear All Recents empties the list, File ▸ Open Recent and recents.json") {
            let text = (try? String(contentsOf: stored, encoding: .utf8)) ?? ""
            return files().isEmpty && recents().isEmpty && !text.contains("kept.md")
        }

        // Return opens the selection: the set, whose window puts the welcome window away.
        welcome.select(.set(name: "welcome-demo", files: 1))
        welcome.pressReturn()
        await check("Return opens the selected set and the welcome window goes away") {
            await self.until { self.app.openSetCount == 1 && !window.isVisible }
        }

        // Closing every window brings the welcome window back instead of quitting.
        for document in documents.documents { document.close() }
        for win in NSApp.windows where win.windowController is SetWindowController { win.close() }
        await check("closing the last window brings the welcome window back") {
            await self.until { window.isVisible && !NSApp.windows.contains { $0.isVisible && $0.windowController is EditorWindowController } }
        }

        // A drop opens the markdown files among the dropped ones.
        let text = dropped.deletingPathExtension().appendingPathExtension("txt")
        try? "not markdown".write(to: text, atomically: false, encoding: .utf8)
        welcome.openDropped([text, dropped])
        await check("dropping files opens the markdown one, and the welcome window goes away") {
            await self.until {
                let open = documents.documents.compactMap { $0.fileURL?.resolvingSymlinksInPath() }
                return open == [dropped] && !window.isVisible
            }
        }
    }
}
