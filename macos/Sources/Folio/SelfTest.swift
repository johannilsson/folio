import AppKit
import WebKit

/// Drives the real app against a throwaway copy of the document: edits, undo, copy and
/// paste through the Edit menu, the `folio` CLI adding annotations from outside, accepting
/// them in both editor modes, and files changing underneath the app.
@MainActor
final class SelfTest {
    let app: AppDelegate
    private var failures = 0

    init(app: AppDelegate) {
        self.app = app
    }

    private var web: WKWebView { app.webView }
    private var dir: URL { app.file.deletingLastPathComponent() }
    private var name: String { app.file.lastPathComponent }

    private func disk() -> String { (try? String(contentsOf: app.file, encoding: .utf8)) ?? "" }

    func run() async -> Bool {
        await check("editor boots in source mode") { await self.waitFor("!!document.querySelector('.cm-content')") }
        await check("title comes from the bridge") {
            await self.js("document.getElementById('filename-display').textContent") as? String == self.name
        }
        await check("bridge served info, getFile and getFolio") {
            ["info", "getFile", "getFolio"].allSatisfy { self.app.bridge.count($0) > 0 }
        }

        // Typing is saved to the file.
        _ = await js("document.querySelector('.cm-content').focus()")
        _ = await js("document.execCommand('insertText', false, 'ZZ')")
        await check("typing reaches the editor") { await self.cmText().contains("ZZ") }
        await check("typing is written to the file") { await self.until { self.disk().contains("ZZ") } }

        // Edit menu actions go through the responder chain, as the menu items do.
        app.window.makeFirstResponder(web)
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

        // An agent annotates through the CLI; the app has to notice.
        _ = await js("document.getElementById('toggle-gutter-btn').click()")
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
        _ = await js("document.getElementById('view-toggle-btn').click()")
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
        let deleteCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "in both the vineyard and the ", "--target", "cellar",
            "--replacement", "cave", "--author", "agent", "--source", "agent",
        ])
        await check("second annotation added from the CLI") { deleteCLI.status == 0 }
        await check("it appears in the preview gutter") {
            await self.waitFor("document.querySelectorAll('#annotation-gutter .ann-card').length === 1", seconds: 8)
        }
        _ = await js("document.querySelector('#annotation-gutter .ann-card button[title=Accept]').dispatchEvent(new MouseEvent('mousedown', {bubbles: true, cancelable: true}))")
        await check("accept goes through the bridge and patches the file") {
            await self.until { self.app.bridge.count("accept") == 1 && self.disk().contains("vineyard and the cave.") }
        }
        await check("the preview reloads the patched text") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('vineyard and the cave.')")
        }
        await check("the CLI sees both annotations resolved") { await self.until { self.pendingFromCLI() == 0 } }

        // Another program replaces the file the way agents do: write a temp file, rename over it.
        let replacement = dir.appendingPathComponent("incoming.tmp")
        try? (disk() + "\nAdded by another program.\n").write(to: replacement, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(app.file, withItemAt: replacement)
        await check("an atomic replace from outside reloads the editor") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('Added by another program.')", seconds: 8)
        }

        // For a human to look at: FOLIO_SNAPSHOT=/path/to.png
        if let path = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let image = try? await web.takeSnapshot(configuration: nil),
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }

        let errors = await js("window.__errors") as? [String] ?? []
        await check("no script errors") {
            if !errors.isEmpty { print("    \(errors)") }
            return errors.isEmpty
        }

        try? FileManager.default.removeItem(at: dir)
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: the folio CLI

    /// `folio` built from this checkout (or FOLIO_CLI), run from the document's folder
    /// the way an agent would.
    private func cli(_ arguments: [String]) -> (status: Int32, output: String) {
        let binary = ProcessInfo.processInfo.environment["FOLIO_CLI"]
            ?? app.dist.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target/debug/folio").path
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
