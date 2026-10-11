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
    private var failures = 0
    private var dirs: [URL] = []

    // Set once the first document is open.
    private var controller: FolioWindowController!

    init(app: AppDelegate, source: URL) {
        self.app = app
        self.source = source
    }

    private var web: WKWebView { controller.webView }
    private var file: URL { controller.files.file }
    private var dir: URL { file.deletingLastPathComponent() }
    private var name: String { file.lastPathComponent }

    private func disk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// A copy inside its own "repo", so the sidecar lands next to it and the CLI can be run from there.
    private func tempCopy() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-\(UUID().uuidString)").resolvingSymlinksInPath()
        let copy = folder.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        dirs.append(folder)
        return copy
    }

    func run() async -> Bool {
        guard let copy = try? tempCopy(), let first = await app.openForSelfTest(copy) else {
            print("FAIL  open the document")
            return false
        }
        controller = first

        await check("editor boots in source mode") { await self.waitFor("!!document.querySelector('.cm-content')") }
        await check("title comes from the bridge") {
            await self.js("document.getElementById('filename-display').textContent") as? String == self.name
        }
        await check("the window title is the file name, with its proxy icon") {
            self.controller.window?.title == self.name && self.controller.window?.representedURL == self.file
        }
        await check("the file is in Open Recent") {
            // AppKit records the resolved path (/private/var for /var).
            NSDocumentController.shared.recentDocumentURLs.contains { $0.resolvingSymlinksInPath() == self.file.resolvingSymlinksInPath() }
        }
        await check("bridge served info, getFile and getFolio") {
            ["info", "getFile", "getFolio"].allSatisfy { self.controller.bridge.count($0) > 0 }
        }
        await check("the in-page title pill and buttons are hidden in the native window") {
            await self.js("['title-pill', 'view-toggle-btn', 'toggle-gutter-btn'].every(id => document.getElementById(id).offsetParent === null)") as? Bool == true
        }
        await check("the native toolbar has the two toggles") {
            let ids = self.controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            return ids.filter { $0 == "source" || $0 == "comments" }.count == 2 && self.controller.sourceOn
        }

        // Typing is saved to the file.
        _ = await js("document.querySelector('.cm-content').focus()")
        _ = await js("document.execCommand('insertText', false, 'ZZ')")
        await check("typing reaches the editor") { await self.cmText().contains("ZZ") }
        await check("typing is written to the file") { await self.until { self.disk().contains("ZZ") } }

        // Edit menu actions go through the responder chain, as the menu items do.
        controller.window?.makeFirstResponder(web)
        send("undo:")
        await check("undo from the Edit menu") { await self.until { !(await self.cmText()).contains("ZZ") } }
        await check("undo is written to the file") { await self.until { !self.disk().contains("ZZ") } }
        send("redo:")
        await check("redo from the Edit menu") { await self.until { (await self.cmText()).contains("ZZ") } }

        NSPasteboard.general.clearContents()
        send("selectAll:")
        // CodeMirror adopts the DOM selection on the next selectionchange; copying
        // before that copies only the cursor's line.
        try? await Task.sleep(nanoseconds: 300_000_000)
        send("copy:")
        await check("copy puts the document on the pasteboard") {
            await self.until { NSPasteboard.general.string(forType: .string)?.contains("The last paragraph.") == true }
        }
        _ = await js("document.execCommand('delete')")
        await check("selection deleted") { !(await self.cmText()).contains("The last paragraph.") }
        send("paste:")
        await check("paste restores the document") {
            await self.until { (await self.cmText()).contains("The last paragraph.") }
        }
        await check("the restored document is on disk") { await self.until { self.disk().contains("The last paragraph.") } }

        // An agent annotates through the CLI; the app has to notice. The View menu opens the comments pane.
        send("toggleComments:")
        await check("the toolbar follows the comments toggle") { await self.until { self.controller.commentsOn } }
        let replaceCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "Natural wine is made with ", "--target", "minimal intervention",
            "--replacement", "no additives", "--author", "agent", "--source", "agent",
        ])
        await check("folio annotate succeeds") { replaceCLI.status == 0 }
        await check("the CLI's annotation appears in the app without a reload") {
            await self.waitFor("document.querySelectorAll('#raw-annotation-gutter .ann-card').length === 1")
        }
        await check("sidecar booleans reach the page as booleans") {
            await self.js("window.webkit.messageHandlers.folio.postMessage({op:'getFolio'}).then(s => s.annotations.map(a => typeof a.resolved).join())") as? String == "boolean"
        }

        // Accept in source mode: CodeMirror patches the text and saves both files.
        _ = await js("document.querySelector('#raw-annotation-gutter .ann-card button[title=Accept]').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}))")
        await check("accepting in source mode patches the file") {
            await self.until { self.disk().contains("made with no additives in both") }
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
        await check("mermaid renders (dynamic chunks load through folio://)") {
            await self.waitFor("!!document.querySelector('#editor-tiptap .diagram-block svg')", seconds: 15)
        }
        // Needs the network; a failure here says where, not that the scheme is broken.
        let plantuml = await waitFor(
            "(() => { const i = document.querySelector('#editor-tiptap .diagram-block img'); return !!i && i.complete && i.naturalWidth > 0 })()",
            seconds: 15
        )
        report("plantuml image loads from the external server", plantuml)

        // Accept in preview mode goes through the bridge's accept op (Rust anchoring).
        let secondCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "in both the vineyard and the ", "--target", "cellar",
            "--replacement", "cave", "--author", "agent", "--source", "agent",
        ])
        await check("second annotation added from the CLI") { secondCLI.status == 0 }
        await check("it appears in the preview gutter") {
            await self.waitFor("document.querySelectorAll('#annotation-gutter .ann-card').length === 1", seconds: 8)
        }
        _ = await js("document.querySelector('#annotation-gutter .ann-card button[title=Accept]').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}))")
        await check("accept goes through the bridge and patches the file") {
            await self.until { self.controller.bridge.count("accept") == 1 && self.disk().contains("vineyard and the cave.") }
        }
        await check("the preview reloads the patched text") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('vineyard and the cave.')")
        }
        await check("the CLI sees both annotations resolved") { await self.until { self.pendingFromCLI() == 0 } }

        // Another program replaces the file the way agents do: write a temp file, rename over it.
        let replacement = dir.appendingPathComponent("incoming.tmp")
        try? (disk() + "\nAdded by another program.\n").write(to: replacement, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: replacement)
        await check("an atomic replace from outside reloads the editor") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('Added by another program.')", seconds: 8)
        }

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
                (try? await second.webView.callAsyncJavaScript("return document.getElementById('filename-display').textContent", contentWorld: .page)) as? String == secondName
            }
        }
        await check("the first window kept its document") { self.controller.files.file == copy }

        let errors = await js("window.__errors") as? [String] ?? []
        await check("no script errors") {
            if !errors.isEmpty { print("    \(errors)") }
            return errors.isEmpty
        }
        return finish()
    }

    // MARK: pictures

    /// Pictures of the in-page controls, for judging how they look: annotation cards in
    /// the comments pane (one focused) and the floating comment button over a selection.
    private func tour(_ base: String) async {        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "no additives", "--comment", "Is this claim sourced anywhere?"],
            ["--kind", "replace", "--context-before", "vineyard and the ", "--target", "cave", "--replacement", "cellar"],
            ["--kind", "highlight", "--context-before", "The last ", "--target", "paragraph"],
        ] {
            _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"])
        }
        _ = await waitFor("document.querySelectorAll('#annotation-gutter .ann-card').length === 3", seconds: 8)
        let press = "new MouseEvent('mousedown', {bubbles: true, cancelable: true})"
        _ = await js("document.querySelector('#annotation-gutter .ann-card').dispatchEvent(\(press))")
        try? await Task.sleep(nanoseconds: 600_000_000)
        snapshot("\(base)-cards.png")

        _ = await js("document.querySelector('#annotation-gutter .ann-card-focused button[title=More]')?.dispatchEvent(\(press))")
        try? await Task.sleep(nanoseconds: 400_000_000)
        snapshot("\(base)-menu.png")
        _ = await js("document.body.dispatchEvent(\(press))")

        // Selecting text in the editor drops the focus from the card.
        _ = await js("document.dispatchEvent(new KeyboardEvent('keydown', {key: 'Escape', bubbles: true}))")

        // Select a word the way a reader would, and show the floating comment button.
        _ = await js("""
            (() => {
              const p = [...document.querySelectorAll('#editor-tiptap p')].find(p => p.textContent.includes('Natural wine'))
              const walker = document.createTreeWalker(p, NodeFilter.SHOW_TEXT)
              const node = walker.nextNode()
              const range = document.createRange()
              range.setStart(node, 0); range.setEnd(node, 7)
              const sel = getSelection(); sel.removeAllRanges(); sel.addRange(range)
              document.querySelector('#editor-tiptap .ProseMirror').dispatchEvent(new MouseEvent('mouseup', {bubbles: true}))
              return 1
            })()
            """)
        try? await Task.sleep(nanoseconds: 600_000_000)
        snapshot("\(base)-floater.png")

        _ = await js("document.querySelector('#comment-floater .af-btn').dispatchEvent(\(press))")
        _ = await js("""
            (() => {
              const t = document.querySelector('.cf-gutter-form textarea, #comment-form-overlay textarea')
              if (t) { t.focus(); t.value = 'Should this say wild yeast?'; t.dispatchEvent(new Event('input', {bubbles: true})) }
              return 1
            })()
            """)
        try? await Task.sleep(nanoseconds: 500_000_000)
        snapshot("\(base)-form.png")
    }

    /// The whole window, title bar and toolbar included.
    private func snapshot(_ path: String) {
        controller.window?.makeKeyAndOrderFront(nil)
        if let number = controller.window?.windowNumber,
           let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(number), [.boundsIgnoreFraming]),
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    private func finish() -> Bool {
        for folder in dirs { try? FileManager.default.removeItem(at: folder) }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: the folio CLI

    /// `folio` built from this checkout (or FOLIO_CLI), run from the document's folder
    /// the way an agent would.
    private func cli(_ arguments: [String]) -> (status: Int32, output: String) {
        let binary = ProcessInfo.processInfo.environment["FOLIO_CLI"]
            ?? AppConfig.dist.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target/debug/folio").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func pendingFromCLI() -> Int {
        let result = cli(["review", name, "--json"])
        guard result.status == 0,
              let list = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [Any] else { return -1 }
        return list.count
    }

    // MARK: helpers

    private func send(_ action: String) {
        NSApp.sendAction(Selector((action)), to: nil, from: nil)
    }

    private func check(_ name: String, _ body: () async -> Bool) async {
        report(name, await body())
    }

    private func report(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    private func js(_ source: String) async -> Any? {
        try? await web.callAsyncJavaScript("return \(source)", contentWorld: .page)
    }

    private func cmText() async -> String {
        await js("document.querySelector('.cm-content').innerText") as? String ?? ""
    }

    private func waitFor(_ condition: String, seconds: Double = 5) async -> Bool {
        await until(seconds: seconds) { await self.js(condition) as? Bool == true }
    }

    private func until(seconds: Double = 5, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}
