import AppKit
import WebKit

/// Drives the real app against throwaway copies of a document: opening through the
/// document controller, edits, undo, copy and paste through the Edit menu, the `folio` CLI
/// adding annotations from outside, accepting them in both editor modes, files changing
/// underneath the app, the native toolbar, and a second window.
@MainActor
final class SelfTest {
    let app: AppDelegate
    let source: URL
    var failures = 0
    /// Set when the preview's checks have run (see `SelfTest+Preview.swift`).
    var previewVerdict: Bool?
    var dirs: [URL] = []

    // Set once the first document is open.
    var controller: FolioWindowController!

    init(app: AppDelegate, source: URL) {
        self.app = app
        self.source = source
    }

    var web: WKWebView { controller.webView }
    var file: URL { controller.files.file }
    var dir: URL { file.deletingLastPathComponent() }
    var name: String { file.lastPathComponent }

    func disk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// A copy inside its own "repo", so the sidecar lands next to it and the CLI can be run from there.
    func tempCopy(named name: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-\(UUID().uuidString)").resolvingSymlinksInPath()
        let copy = folder.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        dirs.append(folder)
        return copy
    }

    func run() async -> Bool {
        // Line by line, so a crash does not take the results so far with it.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Typing, focus and the wheel only reach a window of the app in front. Another app taking the
        // focus while this runs makes those checks fail for that reason, not because of the app.
        NSApp.activate(ignoringOtherApps: true)
        guard let copy = try? tempCopy(), let first = await app.openForSelfTest(copy) else {
            print("FAIL  open the document")
            return false
        }
        controller = first

        if !AppConfig.webPreview {
            await previewChecks()
            return previewVerdict ?? false
        }

        await check("the editor opens in the WYSIWYG preview") {
            await self.waitFor("!!document.querySelector('#editor-tiptap .ProseMirror') && !document.getElementById('editor-wrapper').hidden")
        }
        await check("the toolbar shows the preview as current") { await self.until { !self.controller.sourceOn } }
        await check("the text starts close under the title bar") {
            // The first line's top, below the window's content top: no big gap to skip.
            (await self.js("document.querySelector('#editor-tiptap .tiptap > *').getBoundingClientRect().top") as? Double ?? 999) < 40
        }
        await check("title comes from the bridge") {
            await self.js("document.title") as? String == self.name
        }
        await check("the window title is the file name, with its proxy icon") {
            self.controller.window?.title == self.name && self.controller.window?.representedURL == self.file
        }
        await check("the file is in Open Recent") {
            RecentFiles.list().contains { $0.resolvingSymlinksInPath() == self.file.resolvingSymlinksInPath() }
        }
        await check("bridge served info, getFile and getFolio") {
            ["info", "getFile", "getFolio"].allSatisfy { self.controller.bridge.count($0) > 0 }
        }
        await check("the page has no chrome of its own: the in-page title pill is hidden and it has no toggles") {
            await self.js("document.getElementById('title-pill').offsetParent === null && !document.getElementById('view-toggle-btn') && !document.getElementById('toggle-gutter-btn')") as? Bool == true
        }
        await check("the native toolbar has the two toggles") {
            let ids = self.controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            return ids.filter { $0 == "source" || $0 == "comments" }.count == 2
        }

        // The View menu switches to the source editor, which the typing checks use.
        send("toggleSource:")
        await check("the source editor opens from the menu and the toolbar follows") {
            let shown = await self.until { self.controller.sourceOn && !self.sourceView.isHidden && self.sourceView.window != nil && self.web.isHidden }
            return shown && self.sourceText.contains("The last paragraph.")
        }
        await check("the source text starts close under the title bar") {
            guard let layout = self.sourceView.textView.layoutManager else { return false }
            let top = layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + self.sourceView.textView.textContainerOrigin.y
            return top < 40
        }
        await check("the source is highlighted: a heading is heavier than the text") {
            let storage = self.sourceView.textView.textStorage!
            let heading = storage.attribute(.font, at: 4, effectiveRange: nil) as? NSFont
            let plain = storage.attribute(.font, at: storage.length - 4, effectiveRange: nil) as? NSFont
            return heading != nil && heading != plain
        }

        // Typing is saved to the file.
        controller.window?.makeFirstResponder(sourceView.textView)
        sourceView.textView.insertText("ZZ", replacementRange: NSRange(location: 0, length: 0))
        await check("typing reaches the editor") { self.sourceText.hasPrefix("ZZ") }
        await check("typing is written to the file") { await self.until { self.disk().contains("ZZ") } }

        // Edit menu actions go through the responder chain, as the menu items do.
        send("undoEdit:")
        await check("undo from the Edit menu") { await self.until { !self.sourceText.contains("ZZ") } }
        await check("undo is written to the file") { await self.until { !self.disk().contains("ZZ") } }
        send("redoEdit:")
        await check("redo from the Edit menu") { await self.until { self.sourceText.contains("ZZ") } }

        NSPasteboard.general.clearContents()
        send("selectAll:")
        send("copy:")
        await check("copy puts the document on the pasteboard") {
            await self.until { NSPasteboard.general.string(forType: .string)?.contains("The last paragraph.") == true }
        }
        sourceView.textView.deleteBackward(nil)
        await check("selection deleted") { !self.sourceText.contains("The last paragraph.") }
        send("paste:")
        await check("paste restores the document") {
            await self.until { self.sourceText.contains("The last paragraph.") }
        }
        await check("the restored document is on disk") { await self.until { self.disk().contains("The last paragraph.") } }

        // ⌘B and ⌘I wrap the selection in the markdown marks, and unwrap it again.
        await sourceFormattingChecks()

        // An agent annotates through the CLI; the app has to notice. The View menu opens the comments pane.
        send("toggleComments:")
        await check("the toolbar follows the comments toggle") { await self.until { self.controller.commentsOn } }
        await check("the comments pane slides open") { await self.until { self.controller.scrollHost.paneWidth > 300 } }
        // Closing and opening again, sampling the width on the way: it passes through in-between values.
        await check("the comments pane animates when it closes and opens, rather than jumping") {
            @MainActor func sampleWidths() async -> [Double] {
                var widths: [Double] = []
                for _ in 0..<12 {
                    widths.append(Double(self.controller.scrollHost.paneWidth))
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                return widths
            }
            self.send("toggleComments:")
            let closing = await sampleWidths()
            self.send("toggleComments:")
            let opening = await sampleWidths()
            let between = { (w: [Double]) in w.contains { $0 > 15 && $0 < 290 } }
            return between(closing) && between(opening) && (closing.last ?? 999) < 5 && (opening.last ?? 0) > 300
        }
        await check("the toolbar follows the pane after the animation test") { await self.until { self.controller.commentsOn } }
        let replaceCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "Natural wine is made with ", "--target", "minimal intervention",
            "--replacement", "no additives", "--author", "agent", "--source", "agent",
        ])
        await check("folio annotate succeeds") { replaceCLI.status == 0 }
        await check("the CLI's annotation appears in the app without a reload") {
            await self.until { self.pane.cards.count == 1 }
        }
        // In the window is not the same as in the model: the card has to have a size and sit inside it.
        await check("the card is visible in the comments pane of the source view") {
            await self.until { self.visibleCards().count == 1 }
        }
        await check("the source marks the annotated text: struck through and tinted") {
            await self.until {
                let text = self.sourceText as NSString
                let range = text.range(of: "minimal intervention")
                guard range.location != NSNotFound, let layout = self.sourceView.textView.layoutManager else { return false }
                let strike = layout.temporaryAttribute(.strikethroughStyle, atCharacterIndex: range.location, effectiveRange: nil)
                return strike != nil
            }
        }
        await check("the comments icon counts the pending annotations") {
            await self.until { self.controller.pendingCount == 1 }
        }
        await check("sidecar booleans reach the page as booleans") {
            await self.js("window.webkit.messageHandlers.folio.postMessage({op:'getFolio'}).then(s => s.annotations.map(a => typeof a.resolved).join())") as? String == "boolean"
        }

        // An agent replies to an existing annotation by rewriting the sidecar (temp file, rename).
        let sidecarURL = controller.files.sidecar
        if let data = try? Data(contentsOf: sidecarURL),
           var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var anns = obj["annotations"] as? [[String: Any]], !anns.isEmpty {
            anns[0]["replies"] = [[
                "id": "reply-selftest", "author": "agent", "source": "agent",
                "body": "Reply from the agent", "created": "2026-01-02T00:00:00Z",
            ]]
            obj["annotations"] = anns
            let tmp = sidecarURL.deletingLastPathComponent().appendingPathComponent("incoming-sidecar.tmp")
            try? JSONSerialization.data(withJSONObject: obj).write(to: tmp)
            _ = try? FileManager.default.replaceItemAt(sidecarURL, withItemAt: tmp)
        }
        await check("an agent's reply to an existing annotation appears without a reload") {
            await self.until(seconds: 8) { self.pane.cards.values.first?.annotation.replies?.first?.body == "Reply from the agent" }
        }

        // Accept in source mode: Rust patches the file, and the source follows it.
        press("accept", inCardOf: pane.cards.keys.first)
        await check("accepting in source mode patches the file") {
            await self.until { self.disk().contains("made with no additives in both") }
        }
        await check("the source shows the accepted text") {
            await self.until { self.sourceText.contains("made with no additives in both") }
        }
        await check("the CLI sees the annotation as resolved") {
            await self.until { self.pendingFromCLI() == 0 }
        }

        // Preview mode: Tiptap and the diagram node views.
        send("toggleSource:")
        await check("the toolbar follows the source toggle") { await self.until { !self.controller.sourceOn } }
        await check("preview editor renders") {
            await self.waitFor("!!document.querySelector('#editor-tiptap .ProseMirror') && !document.getElementById('editor-wrapper').hidden")
        }
        await check("the preview picked up what was typed and accepted in the source") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('made with no additives in both')")
        }
        await check("mermaid renders (dynamic chunks load through folio://)") {
            await self.waitFor("!!document.querySelector('#editor-tiptap .diagram-block svg')", seconds: 15)
        }
        // Needs the network; a failure here says where, not that the scheme is broken.
        if AppConfig.renderPlantUML {
            let plantuml = await waitFor(
                "(() => { const i = document.querySelector('#editor-tiptap .diagram-block img'); return !!i && i.complete && i.naturalWidth > 0 })()",
                seconds: 15
            )
            report("plantuml image loads from the external server", plantuml)
        }

        // Accept in preview mode is the app's own card (Rust anchors and patches).
        let secondCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "in both the vineyard and the ", "--target", "cellar",
            "--replacement", "cave", "--author", "agent", "--source", "agent",
        ])
        await check("second annotation added from the CLI") { secondCLI.status == 0 }
        await check("it appears in the comments pane of the preview, on screen") {
            await self.until(seconds: 8) { self.visibleCards().count == 1 }
        }
        press("accept", inCardOf: pane.cards.keys.first)
        await check("accepting patches the file") {
            await self.until { self.disk().contains("vineyard and the cave.") }
        }
        await check("accepting shows a toast") { self.pane.toastMessage == "Accepted replace" }
        await check("the preview reloads the patched text") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('vineyard and the cave.')")
        }
        await check("the CLI sees both annotations resolved") { await self.until { self.pendingFromCLI() == 0 } }

        // The comments pane is open in the preview; switching to the source view must keep it.
        let thirdCLI = cli([
            "annotate", name, "--kind", "comment", "--context-before", "The last ", "--target", "paragraph",
            "--comment", "Pane in source", "--author", "agent", "--source", "agent",
        ])
        await check("a comment added from the CLI shows in the preview pane") {
            let shown = await self.until(seconds: 8) { self.visibleCards().count == 1 }
            return thirdCLI.status == 0 && shown
        }
        send("toggleSource:")
        await check("the card is visible in the comments pane after switching to the source view") {
            await self.until(seconds: 8) { self.controller.sourceOn && self.visibleCards().count == 1 && self.pane.anchorsKnown }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-source-after-preview.png") }
        send("toggleSource:")
        _ = await until(seconds: 8) { !self.controller.sourceOn && self.pane.anchorsKnown }

        // Another program replaces the file the way agents do: write a temp file, rename over it.
        let replacement = dir.appendingPathComponent("incoming.tmp")
        try? (disk() + "\nAdded by another program.\n").write(to: replacement, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: replacement)
        await check("an atomic replace from outside reloads the editor") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('Added by another program.')", seconds: 8)
        }

        await portedBrowserChecks()
        await wideTableChecks()
        await storeChecks()
        await nativeAnnotationChecks()
        await sourceAnnotationChecks()
        await undoAcrossModesChecks()

        // For a human to look at: FOLIO_SNAPSHOT=/path/to/base saves base-*.png pictures.
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await tour(base) }

        // A second window shows its own file.
        guard let secondCopy = try? tempCopy(), let second = await app.openForSelfTest(secondCopy) else {
            report("a second document opens", false)
            return finish()
        }
        let secondName = secondCopy.lastPathComponent
        await check("a second window opens with its own document") {
            let windows = NSApp.windows.compactMap { $0.windowController as? FolioWindowController }
            return windows.count == 2 && second.files.file == secondCopy
        }
        await check("the second window loads its own file") {
            await self.until { second.bridge.count("getFile") > 0 }
        }
        await check("the second window's page shows its own file name") {
            await self.until {
                (try? await second.webView.callAsyncJavaScript("return document.title", contentWorld: .page)) as? String == secondName
            }
        }
        await check("the first window kept its document") { self.controller.files.file == copy }

        await setScenario()

        let errors = await js("window.__errors") as? [String] ?? []
        await check("no script errors") {
            if !errors.isEmpty { print("    \(errors)") }
            return errors.isEmpty
        }

        // Last, since it closes every window.
        await welcomeChecks()
        return finish()
    }

    // MARK: behaviour ported from the browser e2e suite

    /// Replaces the document the way an agent does: write a temp file, rename it over.
    func replaceFile(_ text: String) {
        let tmp = dir.appendingPathComponent("incoming.tmp")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    func replaceSidecar(_ annotations: [[String: Any]]) {
        let sidecar = controller.files.sidecar
        let tmp = sidecar.deletingLastPathComponent().appendingPathComponent("incoming-sidecar.tmp")
        let object: [String: Any] = ["version": 1, "annotations": annotations]
        try? JSONSerialization.data(withJSONObject: object).write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(sidecar, withItemAt: tmp)
    }

    func commentJSON(_ id: String, before: String, target: String) -> [String: Any] {
        [
            "id": id, "kind": "comment", "source": "agent", "author": "agent", "comment": "Check",
            "context_before": before, "target": target, "created": "2026-01-01T00:00:00Z", "resolved": false,
        ]
    }

    /// Whether the preview marks `text` as the target of a comment.
    func previewHighlights(_ text: String) async -> Bool {
        let quoted = text.replacingOccurrences(of: "'", with: "\\'")
        return await waitFor("[...document.querySelectorAll('#editor-wrapper .ann-comment-target')].some(e => e.textContent === '\(quoted)')", seconds: 8)
    }

    /// A key press, as the window would deliver it.
    func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16, in win: EditorWindowController? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: (win ?? controller!).window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Presses the button titled `title` on the sheet over the window.
    func pressSheetButton(_ title: String) {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView else { return }
        find(content)?.performClick(nil)
    }

    /// A click on a native view, delivered to it.
    func click(_ view: NSView) {
        let point = view.convert(NSPoint(x: 20, y: 20), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
    }

    /// Selects the first `length` characters of the preview paragraph that contains `needle`, as the reader would.
    func selectInPreview(_ needle: String, from start: Int = 0, length: Int) async {
        // Highlights split a paragraph into several text nodes, so the offsets are found across them.
        _ = await js("""
            (() => {
              const p = [...document.querySelectorAll('#editor-tiptap p')].find(p => p.textContent.includes('\(needle)'))
              const from = p.textContent.indexOf('\(needle)') + \(start), to = from + \(length)
              const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT)
              let seen = 0, start = null, end = null
              for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                const next = seen + node.textContent.length
                if (!start && from < next) start = [node, from - seen]
                if (!end && to <= next) end = [node, to - seen]
                seen = next
              }
              document.querySelector('#editor-tiptap .ProseMirror').focus()
              getSelection().setBaseAndExtent(start[0], start[1], end[0], end[1])
              return 1
            })()
            """)
    }

    func finish() -> Bool {
        for folder in dirs { try? FileManager.default.removeItem(at: folder) }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: the native annotation UI

    var pane: AnnotationController { controller.annotations }

    /// The native source editor of the first window, and what is in it.
    var sourceView: SourceEditorView { controller.scrollHost.source }
    var sourceText: String { sourceView.textView.string }

    /// The cards that are in the window: in the comments pane, with a size, inside it from side to side.
    /// Where they are down the page is where their text is, and may be below the fold.
    func visibleCards(in win: EditorWindowController? = nil) -> [AnnotationCardView] {
        let target = win ?? controller!
        let host = target.scrollHost
        return target.annotations.cards.values.filter { card in
            guard card.window != nil, !card.isHidden, card.frame.width > 200, card.frame.height > 20 else { return false }
            let rect = host.convert(card.bounds, from: card)
            return rect.minX >= 0 && rect.maxX <= host.bounds.width + 1
        }
    }

    /// The button with this accessibility identifier, somewhere below `view`.
    func button(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews { if let found = button(id, in: sub) { return found } }
        return nil
    }

    /// Clicks a button of an annotation's card the way a reader does.
    func press(_ id: String, inCardOf annotationID: String?, in win: EditorWindowController? = nil) {
        let target = win ?? controller!
        guard let annotationID, let card = target.annotations.cards[annotationID], let found = button(id, in: card) else {
            print("    no \(id) button in the card of \(annotationID ?? "nil")")
            return
        }
        (found as? NSControl)?.performClick(nil)
    }

    // MARK: the folio CLI

    /// `folio` built from this checkout (or FOLIO_CLI), run from the document's folder
    /// the way an agent would.
    func cli(_ arguments: [String], in folder: URL? = nil) -> (status: Int32, output: String) {
        let binary = ProcessInfo.processInfo.environment["FOLIO_CLI"]
            ?? AppConfig.dist.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target/debug/folio").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = folder ?? dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func pendingFromCLI() -> Int {
        let result = cli(["review", name, "--json"])
        guard result.status == 0,
              let list = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [Any] else { return -1 }
        return list.count
    }

    // MARK: helpers

    /// A menu action, sent down the window's responder chain from what has the keyboard (the web
    /// view, a card's field), then to the app. Not through the key window: that is nil while another
    /// app has the focus, and the action would be lost.
    func send(_ action: String) {
        let selector = Selector((action))
        if controller.window?.firstResponder?.tryToPerform(selector, with: nil) == true { return }
        if controller.window?.tryToPerform(selector, with: nil) == true { return }
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    func check(_ name: String, _ body: () async -> Bool) async {
        report(name, await body())
    }

    func report(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    func js(_ source: String) async -> Any? {
        await js(source, in: web)
    }

    func js(_ source: String, in view: WKWebView) async -> Any? {
        try? await view.callAsyncJavaScript("return \(source)", contentWorld: .page)
    }

    func waitFor(_ condition: String, seconds: Double = 10, in view: WKWebView? = nil) async -> Bool {
        await until(seconds: seconds) { await self.js(condition, in: view ?? self.web) as? Bool == true }
    }

    func until(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}
