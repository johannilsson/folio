import AppKit
import WebKit

/// Drives the real app: boots the editor, types, undoes, copies and pastes through the
/// Edit menu actions, toggles to preview and waits for the diagrams.
@MainActor
final class SelfTest {
    let app: AppDelegate
    private var failures = 0

    init(app: AppDelegate) {
        self.app = app
    }

    private var web: WKWebView { app.webView }

    func run() async -> Bool {
        await check("editor boots in source mode") { await self.waitFor("!!document.querySelector('.cm-content')") }
        await check("title comes from the bridge") {
            await self.js("document.getElementById('filename-display').textContent") as? String == self.app.file.lastPathComponent
        }
        await check("bridge served info, getFile and getFolio") {
            ["info", "getFile", "getFolio"].allSatisfy { self.app.bridge.count($0) > 0 }
        }

        // Typing.
        _ = await js("document.querySelector('.cm-content').focus()")
        _ = await js("document.execCommand('insertText', false, 'ZZ')")
        await check("typing reaches the editor") { await self.cmText().contains("ZZ") }
        await check("the edit is saved through the bridge") {
            await self.until { self.app.bridge.lastPutFile?.contains("ZZ") == true }
        }

        // Edit menu actions go through the responder chain, as the menu items do.
        app.window.makeFirstResponder(web)
        send("undo:")
        await check("undo from the Edit menu") { await self.until { !(await self.cmText()).contains("ZZ") } }
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

        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
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
