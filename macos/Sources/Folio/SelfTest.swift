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
    private func tempCopy(named name: String? = nil) throws -> URL {
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
        guard let copy = try? tempCopy(), let first = await app.openForSelfTest(copy) else {
            print("FAIL  open the document")
            return false
        }
        controller = first

        await check("the editor opens in the WYSIWYG preview") {
            await self.waitFor("!!document.querySelector('#editor-tiptap .ProseMirror') && !document.getElementById('editor-wrapper').hidden")
        }
        await check("the toolbar shows the preview as current") { await self.until { !self.controller.sourceOn } }
        await check("the text starts close under the title bar") {
            // The first line's top, below the window's content top: no big gap to skip.
            (await self.js("document.querySelector('#editor-tiptap .tiptap > *').getBoundingClientRect().top") as? Double ?? 999) < 40
        }
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
            return ids.filter { $0 == "source" || $0 == "comments" }.count == 2
        }

        // The View menu switches to the source editor, which the typing checks use.
        send("toggleSource:")
        await check("the source editor opens from the menu and the toolbar follows") {
            let shown = await self.waitFor("!!document.querySelector('.cm-content') && document.getElementById('raw-pane').hidden === false")
            let mirrored = await self.until { self.controller.sourceOn }
            return shown && mirrored
        }
        await check("the source text starts close under the title bar") {
            (await self.js("document.querySelector('#raw-pane .cm-line').getBoundingClientRect().top") as? Double ?? 999) < 40
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
        await check("the comments pane slides open") {
            // It animates its width (like the sidebar) rather than appearing: a transition is set and it ends up open.
            let animated = await self.js("getComputedStyle(document.getElementById('raw-annotation-gutter')).transitionProperty.includes('width')") as? Bool == true
            let open = await self.waitFor("document.getElementById('raw-annotation-gutter').getBoundingClientRect().width > 270")
            return animated && open
        }
        // Closing and opening again, sampling the width on the way: it passes through in-between values.
        await check("the comments pane animates when it closes and opens, rather than jumping") {
            func sampleWidths() async -> [Double] {
                var widths: [Double] = []
                for _ in 0..<12 {
                    widths.append(await self.js("document.getElementById('raw-annotation-gutter').getBoundingClientRect().width") as? Double ?? -1)
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                return widths
            }
            self.send("toggleComments:")
            let closing = await sampleWidths()
            self.send("toggleComments:")
            let opening = await sampleWidths()
            let between = { (w: [Double]) in w.contains { $0 > 15 && $0 < 265 } }
            return between(closing) && between(opening) && (closing.last ?? 999) < 5 && (opening.last ?? 0) > 270
        }
        await check("the toolbar follows the pane after the animation test") { await self.until { self.controller.commentsOn } }
        let replaceCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "Natural wine is made with ", "--target", "minimal intervention",
            "--replacement", "no additives", "--author", "agent", "--source", "agent",
        ])
        await check("folio annotate succeeds") { replaceCLI.status == 0 }
        await check("the CLI's annotation appears in the app without a reload") {
            await self.waitFor("document.querySelectorAll('#raw-annotation-gutter .ann-card').length === 1")
        }
        // In the DOM is not the same as on screen: the card has to have a size and sit inside the window.
        await check("the card is visible in the comments pane of the source view") {
            await self.waitFor("""
                (() => {
                  const r = document.querySelector('#raw-annotation-gutter .ann-card').getBoundingClientRect()
                  return r.width > 200 && r.height > 20 && r.left >= 0 && r.right <= window.innerWidth && r.top >= 0
                })()
                """)
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
            await self.waitFor("document.querySelector('#raw-annotation-gutter').innerText.includes('Reply from the agent')", seconds: 8)
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
            await self.waitFor("""
                (() => {
                  const r = document.querySelector('#raw-annotation-gutter .ann-card')?.getBoundingClientRect()
                  return !!r && r.width > 200 && r.height > 20 && r.left >= 0 && r.right <= window.innerWidth && r.top >= 0
                })()
                """, seconds: 8)
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-source-after-preview.png") }
        send("toggleSource:")
        _ = await waitFor("!document.getElementById('editor-wrapper').hidden", seconds: 8)

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

        await setScenario()

        let errors = await js("window.__errors") as? [String] ?? []
        await check("no script errors") {
            if !errors.isEmpty { print("    \(errors)") }
            return errors.isEmpty
        }
        return finish()
    }

    // MARK: behaviour ported from the browser e2e suite

    /// Replaces the document the way an agent does: write a temp file, rename it over.
    private func replaceFile(_ text: String) {
        let tmp = dir.appendingPathComponent("incoming.tmp")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    private func replaceSidecar(_ annotations: [[String: Any]]) {
        let sidecar = controller.files.sidecar
        let tmp = sidecar.deletingLastPathComponent().appendingPathComponent("incoming-sidecar.tmp")
        let object: [String: Any] = ["version": 1, "annotations": annotations]
        try? JSONSerialization.data(withJSONObject: object).write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(sidecar, withItemAt: tmp)
    }

    private func commentJSON(_ id: String, before: String, target: String) -> [String: Any] {
        [
            "id": id, "kind": "comment", "source": "agent", "author": "agent", "comment": "Check",
            "context_before": before, "target": target, "created": "2026-01-01T00:00:00Z", "resolved": false,
        ]
    }

    /// Whether the preview marks `text` as the target of a comment.
    private func previewHighlights(_ text: String) async -> Bool {
        let quoted = text.replacingOccurrences(of: "'", with: "\\'")
        return await waitFor("[...document.querySelectorAll('#editor-wrapper .ann-comment-target')].some(e => e.textContent === '\(quoted)')", seconds: 8)
    }

    /// The annotation store: each action is applied to the sidecar as it is on disk, and can be undone.
    private func storeChecks() async {
        replaceSidecar([])
        let store = controller.currentStore
        _ = await until { store.reload(); return store.annotations.isEmpty }

        let first = cli(["annotate", name, "--kind", "comment", "--context-before", "Natural wine is made with ",
                         "--target", "no additives", "--comment", "First", "--author", "agent", "--source", "agent"])
        await check("the store sees an annotation an agent wrote") {
            let seen = await self.until { store.pending.count == 1 }
            return first.status == 0 && seen
        }
        let firstID = store.pending.first?.id ?? ""

        // An agent annotates again, and the reader acts before the store has noticed: the new
        // annotation must survive, because the action is applied to the file, not to the store's copy.
        let second = cli(["annotate", name, "--kind", "comment", "--context-before", "The last ", "--target", "paragraph",
                          "--comment", "Second", "--author", "agent", "--source", "agent"])
        var resolved: AnnotationStore.Entry?
        do { resolved = try store.resolve(firstID) } catch { print("    resolve failed: \(error)") }
        await check("resolving keeps an annotation an agent wrote in the meantime") {
            second.status == 0 && resolved != nil && self.pendingFromCLI() == 1
                && store.pending.map(\.comment) == ["Second"] && store.annotation(firstID)?.resolvedAs == "dismissed"
        }
        await check("the CLI accepts the sidecar the app wrote") { self.cli(["check", self.name]).status == 0 }

        await check("undo puts the annotation back") {
            store.undo() && store.pending.count == 2 && self.pendingFromCLI() == 2
                && store.annotation(firstID)?.resolved == false && store.annotation(firstID)?.resolvedAs == nil
        }
        await check("redo resolves it again") { store.redo() && store.pending.count == 1 && self.pendingFromCLI() == 1 }

        var added: AnnotationStore.Entry?
        do { added = try store.addComment(contextBefore: "The last ", target: "paragraph", comment: "From the reader") } catch {
            print("    add failed: \(error)")
        }
        await check("a comment from the reader is saved as local, by me") {
            let ann = store.annotation(added?.id ?? "")
            return ann?.author == "me" && ann?.source == "local" && ann?.comment == "From the reader"
                && ann?.id.hasPrefix("ann_") == true && self.pendingFromCLI() == 2
        }
        await check("undoing an added comment removes it, and redo brings it back") {
            let undone = store.undo() && store.annotation(added?.id ?? "") == nil && self.pendingFromCLI() == 1
            return undone && store.redo() && store.annotation(added?.id ?? "") != nil
        }

        let target = added?.id ?? ""
        _ = try? store.reply(to: target, body: "A reply")
        _ = try? store.editComment(target, to: "Edited")
        await check("a reply and an edited comment are saved") {
            let ann = store.annotation(target)
            return ann?.replies?.map(\.body) == ["A reply"] && ann?.replies?.first?.author == "me" && ann?.comment == "Edited"
        }
        await check("undo steps back through the edit and the reply") {
            store.undo() && store.annotation(target)?.comment == "From the reader"
                && store.undo() && store.annotation(target)?.replies?.isEmpty != false
        }

        // Someone else changing the sidecar makes the undo history stale.
        _ = try? store.resolve(target)
        replaceSidecar([])
        await check("a change from outside empties the history") {
            await self.until { !store.canUndo && store.annotations.isEmpty }
        }
    }

    /// A table wider than the window must not widen the page: nothing in the page scrolls, so
    /// the extra width would push the comments pane off screen. The preview is showing and the
    /// comments pane is open.
    private func wideTableChecks() async {
        let original = disk()
        let cells = (1...8).map { _ in String(repeating: "W", count: 60) }
        let row = "| " + cells.joined(separator: " | ") + " |"
        let header = "| " + (1...8).map { "Column\($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 8)
        replaceFile("# Wide\n\n\(header)\n\(rule)\n\(row)\n\(row)\n\nFinal line after the table.\n")
        _ = await waitFor("document.querySelector('#editor-tiptap').innerText.includes('Final line after the table.')", seconds: 8)
        replaceSidecar([commentJSON("wt1", before: "Final ", target: "line after")])

        // The page is no wider than the window, and the pane's card is on screen.
        func onScreen(_ gutter: String) -> String {
            """
            (() => {
              const r = document.querySelector('\(gutter) .ann-card')?.getBoundingClientRect()
              return document.documentElement.scrollWidth <= window.innerWidth + 1
                && !!r && r.width > 200 && r.left >= 0 && r.right <= window.innerWidth
            })()
            """
        }
        await check("a wide table in the preview does not push the comments pane off screen") {
            let narrow = await self.waitFor("document.documentElement.scrollWidth <= window.innerWidth + 1", seconds: 8)
            let shown = await self.until(seconds: 8) { self.visibleCards().count == 1 }
            return narrow && shown
        }
        await check("the wide table scrolls sideways inside itself") {
            await self.js("""
                (() => {
                  const w = document.querySelector('#editor-tiptap .tableWrapper')
                  w.scrollLeft = 200
                  return w.scrollWidth > w.clientWidth + 200 && w.scrollLeft > 0
                })()
                """) as? Bool == true
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-wide-table.png") }
        send("toggleSource:")
        await check("a wide table in the source view does not push the comments pane off screen") {
            let shown = await self.waitFor("document.getElementById('raw-pane').hidden === false", seconds: 8)
            let visible = await self.waitFor(onScreen("#raw-annotation-gutter"), seconds: 8)
            return shown && visible
        }
        send("toggleSource:")
        _ = await waitFor("!document.getElementById('editor-wrapper').hidden", seconds: 8)
        replaceSidecar([])
        replaceFile(original)
        _ = await waitFor("!document.querySelector('#editor-tiptap').innerText.includes('Final line after the table.')", seconds: 8)
    }

    /// The checks that used to be Playwright specs and apply to the app as it is: anchoring
    /// against the preview's own text, reloads, and the bridge's error path. The preview is showing.
    private func portedBrowserChecks() async {
        let original = disk()

        // Markdown the preview renders differently from `folio render` must not shift a highlight.
        replaceFile("""
        # Title with `code` and *emph*

        Escapes: 1\\. not a list, \\*not emph\\*, a\\_b, back\\\\slash.

        Entities: &amp; &copy; and emoji 🎉 done.

        Autolink <https://example.com> here.

        Line with trailing backslash\\
        next line.

        A paragraph that is
        soft wrapped.

        **Summary:**
        After a hard break.

        1) paren list

        - [ ] task one

        > quote one
        >
        > > nested quote

        Setext heading
        ==============

            indented code block

        | A | B |
        |:--|--:|
        | c \\| d | e |

        Text with <span>inline html</span> and [ref link][r].

        [r]: http://ref.com

        Final target sentence here.

        """)
        _ = await waitFor("document.querySelector('#editor-tiptap').innerText.includes('Final target sentence')", seconds: 8)
        replaceSidecar([commentJSON("pa1", before: "Final ", target: "target sentence")])
        await check("a highlight after markdown the CLI renders differently lands on its target") {
            await self.previewHighlights("target sentence")
        }

        // Anchors after a hard break (two trailing spaces), written with and without them.
        replaceFile("# Hard break\n\nA second paragraph gives the tests something else to select and annotate.\n\n**Description:**  \nThe sample application processes incoming requests.\n")
        _ = await waitFor("document.querySelector('#editor-tiptap').innerText.includes('The sample application')", seconds: 8)
        replaceSidecar([commentJSON("hb1", before: "A second paragraph gives the tests something else to select and annotate.Description:", target: "The sample application")])
        await check("an annotation after a hard break highlights its target in preview") {
            await self.previewHighlights("The sample application")
        }
        replaceSidecar([commentJSON("hb2", before: "Description:  The ", target: "sample application")])
        await check("an anchor saved with the hard break spaces highlights its target in preview") {
            await self.previewHighlights("sample application")
        }
        replaceSidecar([])

        // Reloading changed text into the live preview must not leave it read-only.
        replaceFile(original + "\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n```js\nlet a = 1\n```\n")
        await check("the preview shows text that changed underneath it") {
            await self.waitFor("document.querySelector('#editor-tiptap').innerText.includes('let a = 1')", seconds: 8)
        }
        await check("the preview stays editable after the reload") {
            await self.js("document.getElementById('preview-readonly-notice').hidden && document.querySelector('#editor-tiptap .ProseMirror').getAttribute('contenteditable') === 'true'") as? Bool == true
        }
        replaceFile(original)
        _ = await waitFor("!document.querySelector('#editor-tiptap').innerText.includes('let a = 1')", seconds: 8)

        // A failing bridge op rejects rather than hanging the page.
        await check("a bridge failure rejects instead of hanging") {
            let message = await self.js("window.webkit.messageHandlers.folio.postMessage({op: 'nope'}).catch(e => e.message)") as? String
            return message?.contains("unsupported op") == true
        }
    }

    /// The page never scrolls, so the scroll view has to follow the wheel, the caret, Find
    /// and a selection dragged past the window's edge. Run on a long document in the source
    /// editor, scrolled to the top.
    private func scrollingChecks(_ win: SetWindowController, page: (String) async -> Any?) async {
        let host = win.scrollHost
        func toTop() {
            host.contentView.scroll(to: .zero)
            host.reflectScrolledClipView(host.contentView)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }

        // The web view gets the wheel; it has nothing to scroll, so the scroll view must.
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            win.webView.scrollWheel(with: wheel)
        }
        await check("a wheel event over the page scrolls the window's scroll view") {
            await self.until { host.scrollOffset > 100 }
        }
        toTop()

        // Typing at the end of a long document keeps the caret in view.
        _ = await page("(() => { const c = document.querySelector('.cm-content'); c.focus(); const s = getSelection(); s.selectAllChildren(c); s.collapseToEnd(); return 1 })()")
        _ = await page("document.execCommand('insertText', false, 'X')")
        await check("typing at the end of the document scrolls the caret into view") {
            await self.until {
                // The line around the caret: a collapsed range has no box of its own in some positions.
                guard let rect = await page("(() => { const n = getSelection().focusNode; const r = (n instanceof Element ? n : n.parentElement).getBoundingClientRect(); return [r.top, r.bottom] })()") as? [Double],
                      rect.count == 2, rect[0] > 1000 else { return false }
                return rect[0] >= host.scrollOffset && rect[1] <= host.scrollOffset + host.contentSize.height
            }
        }
        toTop()

        // Find selects a match far down, and the window goes to it.
        win.findItem.searchField.stringValue = "Paragraph 100 of"
        win.findNext(nil)
        await check("Find scrolls the window to the match") { await self.until { host.scrollOffset > 1000 } }
        toTop()

        // A selection dragged below the window's bottom edge scrolls the document.
        if let area = Optional(host.convert(host.bounds, to: nil)) {
            let start = NSPoint(x: area.minX + 160, y: area.maxY - 90)
            let outside = NSPoint(x: area.minX + 300, y: area.minY - 40)
            if let down = mouse(.leftMouseDown, at: start) { win.webView.mouseDown(with: down) }
            for _ in 0..<8 {
                if let drag = mouse(.leftMouseDragged, at: outside) { win.webView.mouseDragged(with: drag) }
                try? await Task.sleep(nanoseconds: 60_000_000)
            }
            if let up = mouse(.leftMouseUp, at: outside) { win.webView.mouseUp(with: up) }
        }
        await check("dragging a selection past the edge scrolls the window") { host.scrollOffset > 40 }
        toTop()
    }

    // MARK: sets

    /// A set of two files in separate "repos", opened in its own window: the sidebar, switching
    /// files in place, badges, and the manifest kept in step with `folio set` from a terminal.
    private func setScenario() async {
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
        func page(_ source: String) async -> Any? { await js(source, in: win.webView) }
        func filename() async -> String? { await page("document.getElementById('filename-display')?.textContent") as? String }

        await check("the set opens in a window titled by the set, with its files in a sidebar") {
            win.window?.title == "demo" && win.sidebar.fileIDs.count == 2 && win.sidebar.selectedID == alphaID
        }
        await check("files are grouped under their repo folders") { win.sidebar.headerTitles.count == 2 }
        await check("the sidebar runs to the top of the window, with the editor below the toolbar") {
            guard let window = win.window, let frame = window.contentView?.superview else { return false }
            let sidebarTop = win.sidebar.view.convert(win.sidebar.view.bounds, to: nil).maxY
            let editorTop = win.webView.convert(win.webView.bounds, to: nil).maxY
            let windowTop = frame.bounds.maxY
            let titlebarOnTop = frame.subviews.last.map { String(describing: type(of: $0)) == "NSTitlebarContainerView" } ?? false
            // The sidebar panel is inset a few points; the editor stops where the toolbar ends.
            return windowTop - sidebarTop < 16 && windowTop - editorTop > 30 && titlebarOnTop
        }
        await check("the selected file has the soft grey selection, as in Finder") {
            await self.until { win.sidebar.selectedRowIsSoft }
        }
        await check("the page opens on the first file") { await self.until { await filename() == "alpha.md" } }
        // The set's page also opens in the preview; the typing checks below use the source editor.
        _ = await self.waitFor("document.getElementById('raw-pane').hidden === true", in: win.webView)
        _ = await page("document.getElementById('view-toggle-btn').click()")
        await check("the source editor shows for the set") {
            await self.waitFor("!!document.querySelector('.cm-content') && document.getElementById('raw-pane').hidden === false", in: win.webView)
        }
        await check("the bridge answers for the set's files") {
            await self.until { win.bridge.count("info") > 0 && win.bridge.count("getFile") > 0 }
        }

        // Picking a file in the sidebar swaps the document in place.
        win.sidebar.choose(betaID)
        await check("choosing a file in the sidebar shows it in place") {
            await self.until { await filename() == "beta.md" }
        }
        await check("it is the other file's content") {
            await self.until { (await page("document.querySelector('.cm-content').innerText") as? String)?.contains("BETA MARKER") == true }
        }
        await check("the window subtitle follows") { win.window?.subtitle == "beta.md" && win.currentID == betaID }

        // Edits go to the file on screen, not the first one.
        _ = await page("document.querySelector('.cm-content').focus()")
        _ = await page("document.execCommand('insertText', false, 'QQ')")
        await check("typing is saved to the file shown") {
            await self.until { (try? String(contentsOf: beta, encoding: .utf8))?.contains("QQ") == true }
        }
        await check("and not to the other file") { !((try? String(contentsOf: alpha, encoding: .utf8))?.contains("QQ") ?? true) }

        // Scroll position comes back when a file is shown again, and a new file starts at the top.
        // The window's scroll view scrolls the page, which is as tall as its text.
        let host = win.scrollHost
        var scrolled = 0.0
        await check("the page is as tall as its text, and the long file scrolled") {
            await self.until(seconds: 15) {
                let height = await page("Math.ceil(document.body.getBoundingClientRect().height)") as? Double ?? 0
                guard height > 1600, abs(host.contentHeight - height) < 2, abs(win.webView.frame.height - height) < 2 else { return false }
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

        await scrollingChecks(win, page: page)

        // An edit made just before switching is saved, and undo in the next file stays in that file.
        _ = await page("document.querySelector('.cm-content').focus()")
        _ = await page("document.execCommand('insertText', false, 'UNSAVED-MARKER')")
        win.sidebar.choose(alphaID)
        await check("an edit made just before switching is saved") {
            await self.until { (try? String(contentsOf: beta, encoding: .utf8))?.contains("UNSAVED-MARKER") == true }
        }
        _ = await until { await filename() == "alpha.md" }
        let alphaBefore = (try? String(contentsOf: alpha, encoding: .utf8)) ?? ""
        _ = await page("document.querySelector('.cm-content').focus()")
        _ = await page("document.execCommand('undo')")
        try? await Task.sleep(nanoseconds: 700_000_000)
        await check("undo in the new file never reaches back into the previous one") {
            let shown = await page("document.querySelector('.cm-content').innerText") as? String ?? ""
            return !shown.contains("UNSAVED-MARKER")
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
        let cards = "document.querySelectorAll('#raw-annotation-gutter .ann-card').length"
        await check("the annotation's card shows on its own file") { await self.waitFor("\(cards) === 1", in: win.webView) }
        win.sidebar.choose(alphaID)
        await check("the other file shows no cards") { await self.waitFor("document.getElementById('filename-display').textContent === 'alpha.md' && \(cards) === 0", in: win.webView) }
        win.sidebar.choose(betaID)
        await check("the cards come back with the file") { await self.waitFor("document.getElementById('filename-display').textContent === 'beta.md' && \(cards) === 1", in: win.webView) }
        // The comments pane of a set window, in the source view: the card is on screen, not just in the page.
        win.toggleComments(nil)
        await check("the card is visible in the comments pane of a set window") {
            await self.waitFor("""
                (() => {
                  const r = document.querySelector('#raw-annotation-gutter .ann-card')?.getBoundingClientRect()
                  return !!r && r.width > 200 && r.height > 20 && r.left >= 0 && r.right <= window.innerWidth && r.top >= 0
                })()
                """, in: win.webView)
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-source-pane.png", of: win)
        }
        win.toggleComments(nil)
        // Refreshing the badges must not move the page or the selection off the open file.
        try? await Task.sleep(nanoseconds: 700_000_000)
        await check("a sidebar refresh keeps the open file open") {
            let shown = await filename()
            return win.currentID == betaID && win.sidebar.selectedID == betaID
                && win.window?.subtitle == "beta.md" && shown == "beta.md"
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

        // Removing the file on screen moves the page to another file first, saving it.
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
        await snapshot("\(base)-cards.png")

        _ = await js("document.querySelector('#annotation-gutter .ann-card-focused button[title=More]')?.dispatchEvent(\(press))")
        try? await Task.sleep(nanoseconds: 400_000_000)
        await snapshot("\(base)-menu.png")
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
        await snapshot("\(base)-floater.png")

        _ = await js("document.querySelector('#comment-floater .af-btn').dispatchEvent(\(press))")
        _ = await js("""
            (() => {
              const t = document.querySelector('.cf-gutter-form textarea, #comment-form-overlay textarea')
              if (t) { t.focus(); t.value = 'Should this say wild yeast?'; t.dispatchEvent(new Event('input', {bubbles: true})) }
              return 1
            })()
            """)
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapshot("\(base)-form.png")

        // Find: the Edit menu focuses the toolbar's search field, Return selects the match in the page.
        _ = await js("document.activeElement?.blur(); getSelection().removeAllRanges()")
        controller.window?.makeFirstResponder(controller.webView)
        let find = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }?.item(withTitle: "Find…")
        await check("Edit has Find with ⌘F") { find?.keyEquivalent == "f" && find?.keyEquivalentModifierMask == .command }
        if let find { NSApp.sendAction(find.action!, to: nil, from: find) }
        await check("Find focuses the search field") {
            (controller.window?.firstResponder as? NSText)?.delegate === controller.findItem.searchField
        }
        controller.findItem.searchField.stringValue = "last paragraph"
        controller.findNext(nil)
        await check("Find selects the match in the page") {
            await self.until { (await self.js("getSelection().toString()") as? String) == "last paragraph" }
        }
        await snapshot("\(base)-find.png")
    }

    /// The whole window, title bar and toolbar included.
    private func snapshot(_ path: String, of target: EditorWindowController? = nil) async {
        let window = (target ?? controller).window
        window?.makeKeyAndOrderFront(nil)
        // A window that was behind another does not repaint until it is in front.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let window { WindowPicture.write(window, to: path) }
    }

    private func finish() -> Bool {
        for folder in dirs { try? FileManager.default.removeItem(at: folder) }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: the native annotation UI

    private var pane: AnnotationController { controller.annotations }

    /// The cards that are in the window: in the comments pane, with a size, inside it from side to side.
    /// Where they are down the page is where their text is, and may be below the fold.
    private func visibleCards(in win: EditorWindowController? = nil) -> [AnnotationCardView] {
        let target = win ?? controller!
        let host = target.scrollHost
        return target.annotations.cards.values.filter { card in
            guard card.window != nil, !card.isHidden, card.frame.width > 200, card.frame.height > 20 else { return false }
            let rect = host.convert(card.bounds, from: card)
            return rect.minX >= 0 && rect.maxX <= host.bounds.width + 1
        }
    }

    /// The button with this accessibility identifier, somewhere below `view`.
    private func button(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews { if let found = button(id, in: sub) { return found } }
        return nil
    }

    /// Clicks a button of an annotation's card the way a reader does.
    private func press(_ id: String, inCardOf annotationID: String?, in win: EditorWindowController? = nil) {
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
    private func cli(_ arguments: [String], in folder: URL? = nil) -> (status: Int32, output: String) {
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
        await js(source, in: web)
    }

    private func js(_ source: String, in view: WKWebView) async -> Any? {
        try? await view.callAsyncJavaScript("return \(source)", contentWorld: .page)
    }

    private func cmText() async -> String {
        await js("document.querySelector('.cm-content').innerText") as? String ?? ""
    }

    private func waitFor(_ condition: String, seconds: Double = 5, in view: WKWebView? = nil) async -> Bool {
        await until(seconds: seconds) { await self.js(condition, in: view ?? self.web) as? Bool == true }
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
