import AppKit
import FolioKit

/// A set of files in its own window.
extension SelfTest {
    // MARK: sets

    /// A set of two files in separate "repos", opened in its own window: the sidebar, switching
    /// files in place, badges, and the manifest kept in step with `folio set` from a terminal.
    func setScenario() async {
        // A throwaway config folder, so the real sets are never touched. The CLI inherits it.
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        guard let alpha = try? tempCopy(named: "alpha.md"), let beta = try? tempCopy(named: "beta.md"),
              let gamma = try? tempCopy(named: "gamma.md") else {
            report("set files are created", false)
            return
        }
        // The marker leads, since the source editor only renders what is near the top; the long
        // tail gives the scroll-position check something to scroll.
        let tail = (1...150).map { "Paragraph \($0) of the long file.\n\n" }.joined()
        try? ("BETA MARKER\n\n" + String(contentsOf: beta, encoding: .utf8) + "\n" + tail).write(to: beta, atomically: false, encoding: .utf8)
        do { try Rust.setAdd("demo", files: [alpha, beta]) } catch {
            report("the set is created: \(error)", false)
            return
        }
        guard let win = app.openSet("demo") else {
            report("the set opens", false)
            return
        }
        let alphaID = win.sidebar.fileIDs[0], betaID = win.sidebar.fileIDs[1]
        let betaDir = beta.deletingLastPathComponent()
        // The window's subtitle is the name of the file it shows.
        func filename() async -> String? { win.window?.subtitle }
        let sv = win.scrollHost.source

        await check("the set opens in a window titled by the set, with its files in a sidebar") {
            win.window?.title == "demo" && win.sidebar.fileIDs.count == 2 && win.sidebar.selectedID == alphaID
        }
        await check("files are grouped under their repo folders") { win.sidebar.headerTitles.count == 2 }
        await check("the sidebar runs to the top of the window, with the editor below the toolbar") {
            guard let window = win.window, let frame = window.contentView?.superview else { return false }
            let sidebarTop = win.sidebar.view.convert(win.sidebar.view.bounds, to: nil).maxY
            let editorTop = win.scrollHost.convert(win.scrollHost.bounds, to: nil).maxY
            let windowTop = frame.bounds.maxY
            let titlebarOnTop = frame.subviews.last.map { String(describing: type(of: $0)) == "NSTitlebarContainerView" } ?? false
            // The sidebar panel is inset a few points; the editor stops where the toolbar ends.
            return windowTop - sidebarTop < 16 && windowTop - editorTop > 30 && titlebarOnTop
        }
        await check("the selected file has the soft grey selection, as in Finder") {
            await self.until { win.sidebar.selectedRowIsSoft }
        }
        await check("the window opens on the first file, in the preview") {
            await self.until { await filename() == "alpha.md" && win.scrollHost.preview.textView.string.contains("The last paragraph.") }
        }
        // The typing checks below use the source editor.
        win.toggleSource(nil)
        await check("the source editor shows for the set, on the first file") {
            await self.until { win.sourceOn && !sv.isHidden && sv.textView.string.contains("The last paragraph.") }
        }

        // Picking a file in the sidebar swaps the document in place.
        win.sidebar.choose(betaID)
        await check("choosing a file in the sidebar shows it in place") {
            await self.until { await filename() == "beta.md" }
        }
        await check("it is the other file's content") {
            await self.until { sv.textView.string.contains("BETA MARKER") }
        }
        await check("the window subtitle follows") { win.window?.subtitle == "beta.md" && win.currentID == betaID }

        // Edits go to the file on screen, not the first one.
        win.window?.makeFirstResponder(sv.textView)
        sv.textView.insertText("QQ", replacementRange: NSRange(location: 0, length: 0))
        await check("typing is saved to the file shown") {
            await self.until { (try? String(contentsOf: beta, encoding: .utf8))?.contains("QQ") == true }
        }
        await check("and not to the other file") { !((try? String(contentsOf: alpha, encoding: .utf8))?.contains("QQ") ?? true) }

        // Scroll position comes back when a file is shown again, and a new file starts at the top.
        // The window's scroll view scrolls the text, which is as tall as it is.
        let host = win.scrollHost
        var scrolled = 0.0
        await check("the source is as tall as its text, and the long file scrolled") {
            await self.until(seconds: 15) {
                guard host.contentHeight > 1600, abs(sv.frame.height - host.contentHeight) < 2 else { return false }
                host.contentView.scroll(to: NSPoint(x: 0, y: 1500))
                host.reflectScrolledClipView(host.contentView)
                scrolled = host.scrollOffset
                return scrolled > 1000
            }
        }
        win.sidebar.choose(alphaID)
        _ = await until { await filename() == "alpha.md" }
        await check("another file starts at the top") {
            await self.until { host.scrollOffset == 0 }
        }
        win.sidebar.choose(betaID)
        _ = await until { await filename() == "beta.md" }
        await check("coming back restores the scroll position") {
            await self.until { abs(host.scrollOffset - scrolled) < 80 }
        }
        host.contentView.scroll(to: .zero)
        host.reflectScrolledClipView(host.contentView)

        await scrollingChecks(win)

        // An edit made just before switching is saved, and undo in the next file stays in that file.
        win.window?.makeFirstResponder(sv.textView)
        sv.textView.insertText("UNSAVED-MARKER", replacementRange: NSRange(location: 0, length: 0))
        win.sidebar.choose(alphaID)
        await check("an edit made just before switching is saved") {
            await self.until { (try? String(contentsOf: beta, encoding: .utf8))?.contains("UNSAVED-MARKER") == true }
        }
        _ = await until { await filename() == "alpha.md" && !sv.textView.string.contains("BETA MARKER") }
        let alphaBefore = (try? String(contentsOf: alpha, encoding: .utf8)) ?? ""
        win.window?.makeFirstResponder(sv.textView)
        sv.undo()
        try? await Task.sleep(nanoseconds: 700_000_000)
        await check("undo in the new file never reaches back into the previous one") {
            !sv.textView.string.contains("UNSAVED-MARKER")
                && (try? String(contentsOf: beta, encoding: .utf8))?.contains("UNSAVED-MARKER") == true
                && (try? String(contentsOf: alpha, encoding: .utf8)) == alphaBefore
        }
        win.sidebar.choose(betaID)
        _ = await until { await filename() == "beta.md" }

        // An agent annotates the second file; its badge appears.
        let annotate = cli([
            "annotate", "beta.md", "--kind", "comment", "--context-before", "Natural wine is made with ",
            "--target", "minimal intervention", "--comment", "check", "--author", "agent", "--source", "agent",
        ], in: betaDir)
        await check("folio annotate on a set file succeeds") { annotate.status == 0 }
        await check("the sidebar badge counts it") { await self.until { win.sidebar.badge(for: betaID) == 1 } }
        await check("the other file has no badge") { win.sidebar.badge(for: alphaID) == 0 }
        // Annotations stay with their file: the cards of the previous file do not linger after a swap.
        await check("the annotation's card shows on its own file") { await self.until { win.annotations.cards.count == 1 } }
        win.sidebar.choose(alphaID)
        await check("the other file shows no cards") {
            let swapped = await self.until { await filename() == "alpha.md" }
            let cleared = await self.until { win.annotations.cards.isEmpty }
            return swapped && cleared
        }
        win.sidebar.choose(betaID)
        await check("the cards come back with the file") {
            let swapped = await self.until { await filename() == "beta.md" }
            let back = await self.until { win.annotations.cards.count == 1 }
            return swapped && back
        }
        await check("back on its file, the card is anchored beside its text and the text is marked in the source") {
            await self.until {
                guard let card = win.annotations.cards.values.first, win.annotations.anchors[card.annotation.id] != nil else { return false }
                let range = (sv.textView.string as NSString).range(of: "minimal intervention")
                guard range.location != NSNotFound else { return false }
                let mark = sv.textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: range.location, effectiveRange: nil)
                return !card.isUnanchored && mark != nil
            }
        }
        // The comments pane of a set window, in the source view: the card is on screen, not just in the model.
        win.toggleComments(nil)
        await check("the card is visible in the comments pane of a set window") {
            await self.until { self.visibleCards(in: win).count == 1 }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-source-pane.png", of: win)
        }
        // The same in the preview: each file brings its own cards.
        win.toggleSource(nil)
        _ = await until { !win.sourceOn }
        await check("a set window's preview shows the open file's annotations in the pane") {
            await self.until(seconds: 8) { self.visibleCards(in: win).count == 1 }
        }
        win.sidebar.choose(alphaID)
        await check("the other file's preview has no cards, and the first file's do not linger") {
            let swapped = await self.until { await filename() == "alpha.md" }
            let cleared = await self.until { win.annotations.cards.isEmpty }
            return swapped && cleared
        }
        win.sidebar.choose(betaID)
        await check("the cards come back with the file in the preview") {
            await self.until(seconds: 8) { self.visibleCards(in: win).count == 1 }
        }
        // The preview scrolls with the wheel, Find, typing and dragging as the source does.
        _ = await until { await filename() == "beta.md" }
        await scrollingChecks(win)
        win.toggleSource(nil)
        _ = await until { win.sourceOn }
        win.toggleComments(nil)
        // Refreshing the badges must not move the window or the selection off the open file.
        try? await Task.sleep(nanoseconds: 700_000_000)
        await check("a sidebar refresh keeps the open file open") {
            win.currentID == betaID && win.sidebar.selectedID == betaID && win.window?.subtitle == "beta.md"
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-set.png", of: win)
        }

        // `folio set add` from a terminal changes the manifest; the sidebar follows.
        let added = cli(["set", "add", "demo", gamma.path])
        await check("folio set add succeeds") { added.status == 0 }
        await check("the sidebar picks up the new file") { await self.until(seconds: 6) { win.sidebar.fileIDs.count == 3 } }

        // Removing a file from the set leaves it on disk.
        let gammaID = win.sidebar.fileIDs.first { $0 != alphaID && $0 != betaID } ?? ""
        await withCheckedContinuation { continuation in win.remove(gammaID) { continuation.resume() } }
        await check("removing a file updates the manifest the CLI reads") {
            await self.until { self.cli(["set", "list", "demo"]).output.split(separator: "\n").count == 2 }
        }
        await check("the file itself stays") { FileManager.default.fileExists(atPath: gamma.path) }
        await check("the sidebar drops it") { win.sidebar.fileIDs.count == 2 }

        // Removing the file on screen moves the window to another file first, saving it.
        await withCheckedContinuation { continuation in win.remove(betaID) { continuation.resume() } }
        await check("removing the open file switches to another") {
            await self.until { await filename() == "alpha.md" && win.currentID == alphaID }
        }
        await check("the removed file kept its edit") { (try? String(contentsOf: beta, encoding: .utf8))?.contains("QQ") == true }
        await withCheckedContinuation { continuation in win.remove(alphaID) { continuation.resume() } }
        await check("the last file cannot be removed") { win.sidebar.fileIDs == [alphaID] }

        await check("opening the set again brings the same window forward") { self.app.openSet("demo") === win }

        win.performDeleteSet()
        await check("deleting the set removes its manifest and closes the window") {
            (try? Rust.setLoad("demo")) == nil && self.app.openSetCount == 0
        }
        await check("deleting the set leaves the files") { FileManager.default.fileExists(atPath: alpha.path) }
    }
}
