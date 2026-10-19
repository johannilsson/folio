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
        // Typing, focus and the wheel only reach a window of the app in front. Another app taking the
        // focus while this runs makes those checks fail for that reason, not because of the app.
        NSApp.activate(ignoringOtherApps: true)
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
            await self.js("document.title") as? String == self.name
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

    /// A key press, as the window would deliver it.
    private func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16, in win: EditorWindowController? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: (win ?? controller!).window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// A click on a native view, delivered to it.
    private func click(_ view: NSView) {
        let point = view.convert(NSPoint(x: 20, y: 20), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
    }

    /// Selects the first `length` characters of the preview paragraph that contains `needle`, as the reader would.
    private func selectInPreview(_ needle: String, from start: Int = 0, length: Int) async {
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

    /// The preview's own annotation UI: the pane, the card that opens next to the text, the Comment
    /// button and form, shortcuts, and Edit ▸ Undo. The preview is showing, with the pane open.
    private func nativeAnnotationChecks() async {
        controller.window?.makeFirstResponder(controller.webView)
        // Three annotations, in document order: a comment, a suggestion, a comment far down.
        replaceSidecar([])
        _ = await until { self.controller.currentStore.annotations.isEmpty }
        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "no additives", "--comment", "Is this sourced?"],
            ["--kind", "replace", "--context-before", "in both the ", "--target", "vineyard", "--replacement", "orchard"],
            ["--kind", "comment", "--context-before", "The last ", "--target", "paragraph", "--comment", "Far down"],
        ] { _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"]) }
        await check("the pane shows a card for each annotation") {
            await self.until(seconds: 8) { self.visibleCards().count == 3 && self.pane.anchorsKnown && self.pane.anchors.count == 3 }
        }
        let anchors = pane.anchors
        let byPosition: [AnnotationCardView] = pane.cards.values.sorted {
            (anchors[$0.annotation.id]?.from ?? 0) < (anchors[$1.annotation.id]?.from ?? 0)
        }
        await check("the cards are in document order and do not overlap") {
            let separate = zip(byPosition, byPosition.dropFirst()).allSatisfy { $0.frame.maxY <= $1.frame.minY }
            let texts: [String?] = byPosition.map { $0.annotation.comment ?? $0.annotation.replacement }
            return separate && texts == ["Is this sourced?", "orchard", "Far down"]
        }
        await check("a card sits beside its text") {
            guard let first = byPosition.first, let anchor = self.pane.anchors[first.annotation.id] else { return false }
            return abs(first.frame.minY - (CGFloat(anchor.top) - 4)) < 1
        }

        // Clicking a card focuses it, which opens its reply field.
        let commentID = byPosition[0].annotation.id, replaceID = byPosition[1].annotation.id
        click(byPosition[0])
        await check("clicking a card focuses it and shows its reply field") {
            let focused = self.pane.focusedID == commentID && byPosition[0].isFocused
            return focused && byPosition[0].replyBox.superview != nil && byPosition[1].replyBox.superview == nil
        }
        byPosition[0].replyBox.textView.string = "It is, in the notes"
        byPosition[0].replyBox.textView.didChangeText()
        byPosition[0].replyBox.submit()
        await check("sending a reply saves it, and the card shows it") {
            let bodies: [String]? = self.pane.cards[commentID]?.annotation.replies?.map { $0.body }
            let author = self.controller.currentStore.annotation(commentID)?.replies?.first?.author
            return bodies == ["It is, in the notes"] && author == "me" && byPosition[0].replyBox.textView.string.isEmpty
        }
        let replyField = byPosition[0].replyBox.textView
        replyField.string = "Posted with the keyboard"
        replyField.didChangeText()
        controller.window?.makeFirstResponder(replyField)
        let controlReturn = keyEvent("\r", .control, code: 36)
        await check("⌃↩ in a reply field posts the reply instead of accepting the annotation") {
            let leftAlone = !self.pane.handleKey(controlReturn)
            let posted = replyField.performKeyEquivalent(with: controlReturn)
            let bodies = self.controller.currentStore.annotation(commentID)?.replies?.map { $0.body }
            return leftAlone && posted && bodies?.last == "Posted with the keyboard"
                && self.controller.currentStore.annotation(commentID)?.resolved == false
        }
        await check("the card with a reply is taller, and still does not overlap the next") {
            byPosition[0].frame.maxY <= byPosition[1].frame.minY
        }

        // ⌃J and ⌃K walk through the annotations, wrapping round.
        let j = keyEvent("j", .control, code: 38), k = keyEvent("k", .control, code: 40)
        await check("⌃J focuses the next annotation, ⌃K the previous, wrapping round") {
            let next = self.pane.handleKey(j) && self.pane.focusedID == replaceID
            let previous = self.pane.handleKey(k) && self.pane.focusedID == commentID
            let wrapped = self.pane.handleKey(k) && self.pane.focusedID == byPosition[2].annotation.id
            return next && previous && wrapped
        }
        await check("walking to an annotation scrolls it into view") {
            await self.until {
                guard let anchor = self.pane.anchors[byPosition[2].annotation.id] else { return false }
                let visible = self.controller.scrollHost.visibleDocumentRect
                return CGFloat(anchor.top) >= visible.minY && CGFloat(anchor.bottom) <= visible.maxY
            }
        }

        // ⌃⌫ rejects the one in focus; the toast offers to undo it.
        _ = pane.handleKey(keyEvent("j", .control, code: 38))   // wraps to the first
        _ = pane.handleKey(keyEvent("j", .control, code: 38))   // the suggestion
        await check("⌃⌫ rejects the focused suggestion") {
            let handled = self.pane.handleKey(self.keyEvent("\u{7f}", .control, code: 51))
            return handled && self.controller.currentStore.annotation(replaceID)?.resolvedAs == "rejected"
                && self.pane.toastMessage == "Rejected replace" && self.pane.cards[replaceID] == nil
        }
        if let undo = button("toast-undo", in: controller.scrollHost) as? NSControl { undo.performClick(nil) }
        await check("the toast's Undo brings it back") {
            await self.until { self.controller.currentStore.annotation(replaceID)?.resolved == false && self.pane.cards[replaceID] != nil }
        }

        // Edit ▸ Undo, with the web view in front, undoes the last annotation action.
        press("accept", inCardOf: commentID)   // a comment: Resolve dismisses it
        await check("resolving a comment dismisses it") {
            self.controller.currentStore.annotation(commentID)?.resolvedAs == "dismissed"
        }
        controller.window?.makeFirstResponder(controller.webView)
        send("undoEdit:")
        await check("Edit ▸ Undo brings the dismissed comment back") {
            await self.until { self.controller.currentStore.annotation(commentID)?.resolved == false }
        }
        send("redoEdit:")
        await check("Edit ▸ Redo dismisses it again") {
            await self.until { self.controller.currentStore.annotation(commentID)?.resolved == true }
        }
        await check("⌘Z does the same from the keyboard, ⇧⌘Z redoes") {
            let undone = self.pane.handleKey(self.keyEvent("z", .command, code: 6))
                && self.controller.currentStore.annotation(commentID)?.resolved == false
            let redone = self.pane.handleKey(self.keyEvent("z", [.command, .shift], code: 6))
                && self.controller.currentStore.annotation(commentID)?.resolved == true
            return undone && redone
        }
        // After typing in the page, Undo is the page's again: it takes the typing back and leaves the annotation.
        _ = await js("document.querySelector('#editor-tiptap .ProseMirror').focus()")
        _ = await js("document.execCommand('insertText', false, 'QZX')")
        _ = await until { self.pane.lastTypingAt > self.controller.currentStore.lastActionAt }
        await check("⌘Z after typing is left to the page") { !self.pane.handleKey(self.keyEvent("z", .command, code: 6)) }
        send("undoEdit:")
        await check("Edit ▸ Undo after typing takes the typing back and leaves the annotation") {
            let typedBackOut = await self.until {
                (await self.js("document.querySelector('#editor-tiptap').innerText.includes('QZX')") as? Bool) == false
            }
            return typedBackOut && self.controller.currentStore.annotation(commentID)?.resolved == true
        }
        controller.currentStore.undo()
        _ = await until { self.controller.currentStore.annotation(commentID)?.resolved == false }

        // Accepting with ⌃↩: the suggestion is applied to the text.
        _ = pane.handleKey(keyEvent("j", .control, code: 38))
        while pane.focusedID != replaceID, pane.handleKey(keyEvent("j", .control, code: 38)) {}
        await check("⌃↩ accepts the focused suggestion") {
            let handled = self.pane.handleKey(self.keyEvent("\r", .control, code: 36))
            let patched = await self.until { self.disk().contains("both the orchard") }
            return handled && patched
        }

        // Editing and "not found".
        replaceSidecar([commentJSON("lost", before: "no such text anywhere ", target: "nowhere")])
        await check("an annotation that is not in the document is marked, and parked at the end") {
            await self.until(seconds: 8) {
                guard let card = self.pane.cards["lost"] else { return false }
                return card.isUnanchored && card.alphaValue < 1
            }
        }
        replaceSidecar([commentJSON("edit", before: "Natural wine is made with ", target: "no additives")])
        _ = await until(seconds: 8) { self.pane.cards["edit"] != nil && self.pane.anchors["edit"] != nil }
        self.pane.cards["edit"]?.editComment()
        await check("Edit comment opens the text for editing, and Save keeps it") {
            guard let card = self.pane.cards["edit"] else { return false }
            let box = self.button("save-edit", in: card)
            guard box != nil else { return false }
            // The text field is the edit box's; set what the reader typed and press Save.
            func textView(_ view: NSView) -> GrowingTextView? {
                (view as? GrowingTextView) ?? view.subviews.lazy.compactMap(textView).first
            }
            let editor = card.subviews.compactMap { $0 as? EditBoxView }.first
            editor?.textView.string = "Reworded comment"
            (box as? NSControl)?.performClick(nil)
            return await self.until { self.controller.currentStore.annotation("edit")?.comment == "Reworded comment" }
        }

        // Agents write the ids: one with quotes and a backslash reaches the page as it is.
        let quotedID = #"it's \"quoted\" \ ')"#
        replaceSidecar([commentJSON(quotedID, before: "Natural wine is made with ", target: "no additives")])
        _ = await until(seconds: 8) { self.pane.anchors[quotedID] != nil }
        _ = await js("(() => { const c = document.querySelector('#editor-tiptap .ProseMirror'); c.focus(); const s = getSelection(); s.selectAllChildren(c); s.collapseToEnd(); return 1 })()")
        await check("⌃J puts the page's caret on an annotation whose id has quotes and a backslash") {
            guard self.pane.handleKey(self.keyEvent("j", .control, code: 38)), self.pane.focusedID == quotedID else { return false }
            return await self.waitFor("""
                (() => {
                  const s = getSelection(), p = s.focusNode && (s.focusNode.nodeType === 1 ? s.focusNode : s.focusNode.parentElement).closest('p')
                  if (!p) return false
                  const before = document.createRange(); before.setStart(p, 0); before.setEnd(s.focusNode, s.focusOffset)
                  return before.toString().length === p.textContent.indexOf('no additives')
                })()
                """, seconds: 5)
        }

        await commentFormChecks()

        replaceSidecar([])
        _ = await until { self.controller.currentStore.annotations.isEmpty }
    }

    /// The annotation UI in the source: the marks on the text, ranges that follow the text as it is
    /// edited, clicks, ⌃J/⌃K, the Comment button and form, Undo in order, and the file changing underneath.
    private func sourceAnnotationChecks() async {
        replaceSidecar([])
        _ = await until { self.controller.currentStore.annotations.isEmpty }
        if !controller.commentsOn { send("toggleComments:") }
        _ = await until { self.controller.commentsOn && self.controller.scrollHost.paneWidth > 300 }
        send("toggleSource:")
        _ = await until { self.controller.sourceOn && !self.sourceView.isHidden }
        let textView = sourceView.textView
        controller.window?.makeFirstResponder(textView)

        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "no additives", "--comment", "Sourced?"],
            ["--kind", "replace", "--context-before", "in both the ", "--target", "orchard", "--replacement", "vineyard"],
            ["--kind", "delete", "--context-before", "orchard and the ", "--target", "cave"],
            ["--kind", "highlight", "--context-before", "The last ", "--target", "paragraph"],
            ["--kind", "insert", "--context-before", "The last paragraph", "--replacement", " (end)"],
        ] { _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"]) }
        await check("every kind of annotation is anchored in the source, with a card in the pane") {
            await self.until(seconds: 10) { self.visibleCards().count == 5 && self.sourceView.ranges.count == 5 && self.pane.anchors.count == 5 }
        }

        func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
            textView.layoutManager?.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil)
        }
        func range(of kind: String) -> NSRange? {
            guard let annotation = self.controller.currentStore.pending.first(where: { $0.kind == kind }) else { return nil }
            return self.sourceView.ranges[annotation.id]
        }
        await check("comments and highlights are tinted, replaced and deleted text struck through, a deletion underlined too") {
            guard let comment = range(of: "comment"), let highlight = range(of: "highlight"),
                  let replace = range(of: "replace"), let delete = range(of: "delete") else { return false }
            return attribute(.backgroundColor, at: comment.location) != nil && attribute(.strikethroughStyle, at: comment.location) == nil
                && attribute(.backgroundColor, at: highlight.location) != nil
                && attribute(.strikethroughStyle, at: replace.location) != nil && attribute(.underlineStyle, at: replace.location) == nil
                && attribute(.strikethroughStyle, at: delete.location) != nil && attribute(.underlineStyle, at: delete.location) != nil
        }
        await check("an insertion is marked at its place") {
            guard let insert = range(of: "insert") else { return false }
            return textView.insertPoints == [insert.location]
        }
        await check("each range is the text the annotation is about") {
            let text = self.sourceText as NSString
            guard let comment = range(of: "comment"), let delete = range(of: "delete"), let highlight = range(of: "highlight") else { return false }
            return text.substring(with: comment) == "no additives" && text.substring(with: delete) == "cave" && text.substring(with: highlight) == "paragraph"
        }

        // Typing earlier in the text moves the annotations with the words they are about.
        let before = range(of: "comment")
        textView.insertText("XX", replacementRange: NSRange(location: 0, length: 0))
        await check("typing before an annotation moves its range along, and the card follows its line") {
            guard let before, let after = range(of: "comment") else { return false }
            let text = self.sourceText as NSString
            return after.location == before.location + 2 && text.substring(with: after) == "no additives"
        }
        textView.insertText("", replacementRange: NSRange(location: 0, length: 2))

        // Click on annotated text focuses its annotation; with the pane closed its card opens beside it.
        let commentID = controller.currentStore.pending.first { $0.kind == "comment" }?.id ?? ""
        if let comment = range(of: "comment") { textView.onClick?(comment.location + 2) }
        await check("a click on annotated text focuses its card") { self.pane.focusedID == commentID }
        textView.onClick?(0)
        await check("a click on plain text clears the focus") { self.pane.focusedID == nil }

        // ⌃J walks to the next annotation, putting the caret at its start.
        await check("⌃J focuses the first annotation and puts the caret at its start, ⌃K goes back round to the last") {
            let first = self.pane.handleKey(self.keyEvent("j", .control, code: 38))
            let firstRange = self.sourceView.ranges[self.pane.focusedID ?? ""]
            let caret = textView.selectedRange().location
            let wrapped = self.pane.handleKey(self.keyEvent("k", .control, code: 40))
            return first && firstRange != nil && caret == firstRange?.location && wrapped && self.pane.focusedID != nil
        }
        textView.onClick?(0)

        // The Comment button and form work on the source as they do in the preview.
        await commentFormChecks(inSource: true)
        if !controller.commentsOn {
            send("toggleComments:")
            _ = await until { self.controller.commentsOn && self.controller.scrollHost.paneWidth > 300 }
        }

        // Undo goes back through typing and annotation actions in the order they happened.
        // (A comment's check button dismisses it, which is an action that can be undone.)
        let toDismiss = controller.currentStore.pending.first { $0.kind == "comment" && $0.author == "agent" }?.id ?? ""
        controller.window?.makeFirstResponder(textView)
        press("accept", inCardOf: toDismiss)
        _ = await until { self.controller.currentStore.annotation(toDismiss)?.resolved == true }
        // The history groups by run-loop turn and the test never leaves its turn, so it ends each
        // action's group itself, as the reader's events would.
        let history = textView.history
        history.groupsByEvent = false
        while history.groupingLevel > 0 { history.endUndoGrouping() }
        history.beginUndoGrouping()
        textView.insertText("QZ", replacementRange: NSRange(location: 0, length: 0))
        history.endUndoGrouping()
        history.groupsByEvent = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        send("undoEdit:")
        await check("Undo takes the typing back first") {
            !self.sourceText.hasPrefix("QZ") && self.controller.currentStore.annotation(toDismiss)?.resolved == true
        }
        send("undoEdit:")
        await check("and then the annotation action, in the same history") {
            await self.until { self.controller.currentStore.annotation(toDismiss)?.resolved == false }
        }

        // The file changing underneath: followed when nothing is waiting to be saved, not otherwise.
        _ = await until(seconds: 5) { !self.sourceView.hasUnsavedEdits }
        replaceFile(disk() + "\nAdded under the source.\n")
        await check("the source follows a change to the file") {
            await self.until(seconds: 8) { self.sourceText.contains("Added under the source.") }
        }
        await check("its annotations are anchored again in the new text") {
            await self.until {
                let pending = self.controller.currentStore.pending.count
                return pending > 0 && self.sourceView.ranges.count == pending
            }
        }
        textView.insertText("LOCAL", replacementRange: NSRange(location: 0, length: 0))
        replaceFile("# Replaced while typing\n")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await check("typing waiting to be saved is not overwritten by a change to the file") {
            await self.until { self.disk().hasPrefix("LOCAL") && self.sourceText.hasPrefix("LOCAL") }
        }
        replaceFile(sourceText)

        await check("the line numbers count the lines of the file") {
            let newlines = self.sourceText.filter { $0 == "\n" }.count
            return self.sourceView.lineStartsForTest.count == newlines + 1
        }

        // A save that fails is shown, and the typing stays: not replaced, not left behind by the preview.
        _ = await until(seconds: 5) { !self.sourceView.hasUnsavedEdits }
        let saved = disk()
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        textView.insertText("UNWRITTEN", replacementRange: NSRange(location: 0, length: 0))
        await check("a save that fails is shown, and the typing stays unsaved") {
            await self.until(seconds: 3) { self.controller.window?.attachedSheet != nil }
                && self.sourceView.hasUnsavedEdits && self.disk() == saved
        }
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        send("toggleSource:")
        try? await Task.sleep(nanoseconds: 500_000_000)
        await check("the preview does not open while the typing is not saved") {
            self.controller.sourceOn && self.controller.window?.attachedSheet != nil
        }
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        replaceFile("# Changed while the save failed\n")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await check("a change to the file does not replace typing whose save failed") { self.sourceText.hasPrefix("UNWRITTEN") }
        await check("the next save writes it") { self.sourceView.flushSave() && self.disk().hasPrefix("UNWRITTEN") }
        replaceFile(saved)

        replaceSidecar([])
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn }
    }

    /// Annotation actions in the preview and the source are in different histories: Undo after a
    /// switch must not reach back past what was done in the other mode. Starts and ends in the preview.
    private func undoAcrossModesChecks() async {
        replaceSidecar([commentJSON("modes", before: "Natural wine is made with ", target: "no additives")])
        let store = controller.currentStore
        _ = await until(seconds: 8) { store.annotation("modes") != nil }
        _ = try? store.reply(to: "modes", body: "Replied in the preview")
        send("toggleSource:")
        _ = await until { self.controller.sourceOn && !self.sourceView.isHidden }
        _ = try? store.reply(to: "modes", body: "Replied in the source")
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn }
        await check("⌘Z in the preview after a switch leaves what was done in the source") {
            _ = self.pane.handleKey(self.keyEvent("z", .command, code: 6))
            let bodies = store.annotation("modes")?.replies?.map { $0.body }
            return bodies == ["Replied in the preview", "Replied in the source"]
        }
        replaceSidecar([])
        _ = await until { store.annotations.isEmpty }
    }

    /// The Comment button over a selection, and the form it opens, with the pane open and closed.
    private func commentFormChecks(inSource: Bool = false) async {
        let textResponder: NSResponder = inSource ? sourceView.textView : controller.webView
        // Selects `length` characters of "Natural wine" from `offset`, as the reader would.
        func select(from offset: Int, length: Int) async {
            if inSource {
                let start = (sourceText as NSString).range(of: "Natural wine").location
                sourceView.textView.setSelectedRange(NSRange(location: start + offset, length: length))
            } else {
                await selectInPreview("Natural wine", from: offset, length: length)
            }
        }
        // Whether the text being commented on is highlighted (the pending range).
        func highlighted() async -> Bool {
            if inSource {
                let start = (sourceText as NSString).range(of: "Natural wine").location
                return sourceView.textView.layoutManager?.temporaryAttribute(.backgroundColor, atCharacterIndex: start, effectiveRange: nil) != nil
            }
            return await waitFor("!!document.querySelector('#editor-tiptap .ann-comment-pending')", seconds: 2)
        }
        controller.window?.makeFirstResponder(textResponder)
        for paneOpen in [true, false] {
            if pane.commentsOn != paneOpen {
                send("toggleComments:")
                _ = await until { self.pane.commentsOn == paneOpen && (paneOpen ? self.controller.scrollHost.paneWidth > 300 : self.controller.scrollHost.paneWidth == 0) }
            }
            let label = (paneOpen ? "pane open" : "pane closed") + (inSource ? ", source" : "")
            controller.window?.makeFirstResponder(textResponder)
            await select(from: 0, length: 7)
            await check("selecting text shows the Comment button (\(label))") {
                let shown = await self.until { self.pane.selection?.target == "Natural" && !self.pane.adderIsHidden }
                if !shown {
                    let responder = self.controller.window?.firstResponder
                    print("    selection \(String(describing: self.pane.selection)) adderHidden \(self.pane.adderIsHidden) form \(self.pane.form != nil) sourceOn \(self.pane.sourceOn) responder \(String(describing: responder.map { type(of: $0) })) inPage \((responder as? NSView)?.isDescendant(of: self.controller.webView) ?? false)")
                }
                return shown
            }
            if paneOpen == false, let selection = pane.selection {
                await check("the Comment button sits above the selection, in the text column") {
                    guard let frame = self.pane.adderFrame else { return false }
                    return frame.maxY <= CGFloat(selection.top) || frame.minY >= CGFloat(selection.bottom)
                }
            }
            pane.pressCommentButton()
            await check("the Comment button opens the form, with the keyboard in it (\(label))") {
                self.pane.form != nil && self.pane.adderIsHidden
                    && (self.controller.window?.firstResponder as? NSView)?.isDescendant(of: self.pane.form!) == true
            }
            await check("the form is in the pane when it is open, next to the text when closed (\(label))") {
                guard let form = self.pane.form else { return false }
                return paneOpen ? form.superview === self.controller.scrollHost.gutter : (form.superview === self.controller.scrollHost.floatingHost && form.isFloating)
            }
            await check("the selected text stays highlighted while the form is open (\(label))") {
                await highlighted()
            }
            // Esc cancels.
            _ = self.pane.handleKey(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                                                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!)
            await check("Escape cancels the form (\(label))") {
                let stillHighlighted = inSource ? await highlighted() : await self.waitFor("!!document.querySelector('#editor-tiptap .ann-comment-pending')", seconds: 1)
                return self.pane.form == nil && !stillHighlighted
            }
            // Send.
            controller.window?.makeFirstResponder(textResponder)
            await select(from: 8, length: 4)
            _ = await until { self.pane.selection?.target == "wine" && !self.pane.adderIsHidden }
            pane.pressCommentButton()
            pane.form?.field.textView.string = "From the form (\(label))"
            pane.form?.field.textView.didChangeText()
            pane.form?.field.submit()
            await check("sending the form adds a local comment anchored to the selection (\(label))") {
                await self.until(seconds: 8) {
                    self.controller.currentStore.annotations.contains { $0.comment == "From the form (\(label))" && $0.target == "wine" && $0.author == "me" }
                }
            }
            await check("the CLI anchors the comment the form wrote (\(label))") {
                let dry = self.cli(["accept", self.name, "--all", "--source", "local", "--dry-run"])
                return dry.status == 0
            }
            await check("the form is gone after sending (\(label))") { self.pane.form == nil }
        }
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
        await check("a wide table in the source view wraps and does not push the comments pane off screen") {
            let shown = await self.until(seconds: 8) { self.controller.sourceOn && self.visibleCards().count == 1 }
            let host = self.controller.scrollHost
            let fits = (host.documentView?.frame.width ?? 9999) <= host.contentSize.width + 1
                && self.sourceView.frame.maxX <= host.contentSize.width - host.paneWidth + 1
            return shown && fits
        }
        send("toggleSource:")
        _ = await until(seconds: 8) { !self.controller.sourceOn }
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
        let preview = !win.sourceOn
        let label = preview ? "preview" : "source"
        func toTop() {
            host.contentView.scroll(to: .zero)
            host.reflectScrolledClipView(host.contentView)
        }
        func mouse(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: win.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let textView = host.source.textView

        // The text gets the wheel; it has nothing to scroll by itself, so the scroll view must.
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            if preview { win.webView.scrollWheel(with: wheel) } else { textView.scrollWheel(with: wheel) }
        }
        await check("a wheel event over the \(label) scrolls the window's scroll view") {
            await self.until { host.scrollOffset > 100 }
        }
        toTop()

        // Typing at the end of a long document keeps the caret in view.
        if preview {
            _ = await page("(() => { const c = document.querySelector('#editor-tiptap .ProseMirror'); c.focus(); const s = getSelection(); s.selectAllChildren(c); s.collapseToEnd(); return 1 })()")
            _ = await page("document.execCommand('insertText', false, 'X')")
        } else {
            win.window?.makeFirstResponder(textView)
            let end = NSRange(location: (textView.string as NSString).length, length: 0)
            textView.setSelectedRange(end)
            textView.insertText("X", replacementRange: end)
        }
        await check("typing at the end of the \(label) scrolls the caret into view") {
            await self.until {
                if preview {
                    // The line around the caret: a collapsed range has no box of its own in some positions.
                    guard let rect = await page("(() => { const n = getSelection().focusNode; const r = (n instanceof Element ? n : n.parentElement).getBoundingClientRect(); return [r.top, r.bottom] })()") as? [Double],
                          rect.count == 2, rect[0] > 1000 else { return false }
                    return rect[0] >= host.scrollOffset && rect[1] <= host.scrollOffset + host.contentSize.height
                }
                guard let layout = textView.layoutManager else { return false }
                let glyph = layout.glyphIndexForCharacter(at: max(0, (textView.string as NSString).length - 1))
                let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let top = textView.frame.minY + line.minY + textView.textContainerOrigin.y
                return top > 1000 && top >= host.scrollOffset && top + line.height <= host.scrollOffset + host.contentSize.height
            }
        }
        toTop()

        // Find selects a match far down, and the window goes to it.
        win.findItem.searchField.stringValue = "Paragraph 100 of"
        win.findNext(nil)
        await check("Find scrolls the window to the match in the \(label)") { await self.until { host.scrollOffset > 1000 } }
        toTop()

        // A selection dragged below the window's bottom edge scrolls the document. The text view
        // follows the mouse until the button is released, so the drag and the release are queued first.
        let area = host.convert(host.bounds, to: nil)
        let start = NSPoint(x: area.minX + 160, y: area.maxY - 90)
        let outside = NSPoint(x: area.minX + 300, y: area.minY - 40)
        if let down = mouse(.leftMouseDown, at: start) {
            if preview {
                win.webView.mouseDown(with: down)
                for _ in 0..<8 {
                    if let drag = mouse(.leftMouseDragged, at: outside) { win.webView.mouseDragged(with: drag) }
                    try? await Task.sleep(nanoseconds: 60_000_000)
                }
                if let up = mouse(.leftMouseUp, at: outside) { win.webView.mouseUp(with: up) }
            } else {
                // mouseDown tracks until the button comes up, with a timer driving the autoscroll
                // while it is held outside: the events arrive over time, as a held mouse's would.
                // The main thread is inside that loop, so another thread posts them.
                let drags = (0..<10).compactMap { _ in mouse(.leftMouseDragged, at: outside) }
                let up = mouse(.leftMouseUp, at: outside)
                DispatchQueue.global().async {
                    for drag in drags {
                        Thread.sleep(forTimeInterval: 0.06)
                        NSApp.postEvent(drag, atStart: false)
                    }
                    Thread.sleep(forTimeInterval: 0.3)
                    if let up { NSApp.postEvent(up, atStart: false) }
                }
                textView.mouseDown(with: down)
            }
        }
        await check("dragging a selection past the edge of the \(label) scrolls the window") {
            if host.scrollOffset <= 40 { print("    offset \(host.scrollOffset) selection \(textView.selectedRange()) area \(area)") }
            return host.scrollOffset > 40
        }
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
        func filename() async -> String? { await page("document.title") as? String }
        let sv = win.scrollHost.source

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
        // The set's window also opens in the preview; the typing checks below use the source editor.
        win.toggleSource(nil)
        await check("the source editor shows for the set, on the first file") {
            await self.until { win.sourceOn && !sv.isHidden && sv.textView.string.contains("The last paragraph.") }
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

        await scrollingChecks(win, page: page)

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
        _ = await until { await page("document.title") as? String == "beta.md" }
        await scrollingChecks(win, page: page)
        win.toggleSource(nil)
        _ = await until { win.sourceOn }
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
    private func tour(_ base: String) async {
        controller.window?.makeFirstResponder(controller.webView)
        replaceSidecar([])
        _ = await until { self.controller.currentStore.annotations.isEmpty }
        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "no additives", "--comment", "Is this claim sourced anywhere?"],
            ["--kind", "replace", "--context-before", "vineyard and the ", "--target", "cave", "--replacement", "cellar"],
            ["--kind", "highlight", "--context-before", "The last ", "--target", "paragraph"],
        ] {
            _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"])
        }
        if !pane.commentsOn {
            send("toggleComments:")
            _ = await until { self.pane.commentsOn && self.controller.scrollHost.paneWidth > 300 }
        }
        _ = await until(seconds: 8) { self.visibleCards().count == 3 && self.pane.anchors.count == 3 }
        // Pictures are of the top of the document, where the first annotations are.
        let toTop = {
            self.controller.scrollHost.contentView.scroll(to: .zero)
            self.controller.scrollHost.reflectScrolledClipView(self.controller.scrollHost.contentView)
        }
        toTop()

        // The pane, with the first card focused.
        let first = pane.cards.values.min { (pane.anchors[$0.annotation.id]?.from ?? 0) < (pane.anchors[$1.annotation.id]?.from ?? 0) }
        if let first { click(first) }
        try? await Task.sleep(nanoseconds: 600_000_000)
        await snapshot("\(base)-cards.png")

        // Select a word the way a reader would: the Comment button over it, then the form.
        await selectInPreview("Natural wine", length: 7)
        _ = await until { !self.pane.adderIsHidden }
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapshot("\(base)-floater.png")
        pane.pressCommentButton()
        pane.form?.field.textView.string = "Should this say wild yeast?"
        pane.form?.field.textView.didChangeText()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapshot("\(base)-form.png")
        pane.cancelForm()

        // With the pane closed, clicking annotated text opens its card next to it.
        send("toggleComments:")
        _ = await until { !self.pane.commentsOn && self.controller.scrollHost.paneWidth == 0 }
        _ = await js("""
            (() => {
              const el = document.querySelector('#editor-tiptap .ann-comment-target')
              const r = el.getBoundingClientRect()
              const o = {bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5, button: 0}
              for (const type of ['mousedown', 'mouseup', 'click']) el.dispatchEvent(new MouseEvent(type, o))
              return 1
            })()
            """)
        let opened = await until { self.pane.focusedID != nil }
        if !opened { print("    the click on annotated text did not focus its annotation") }
        toTop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapshot("\(base)-overlay.png")
        send("toggleComments:")
        _ = await until { self.pane.commentsOn }

        // Find: the Edit menu focuses the toolbar's search field, Return selects the match in the page.
        _ = await js("document.activeElement?.blur(); getSelection().removeAllRanges()")
        controller.window?.makeFirstResponder(controller.webView)
        let find = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }?.item(withTitle: "Find…")
        await check("Edit has Find with ⌘F") { find?.keyEquivalent == "f" && find?.keyEquivalentModifierMask == .command }
        if let find, let action = find.action { send(NSStringFromSelector(action)) }
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

    /// The native source editor of the first window, and what is in it.
    private var sourceView: SourceEditorView { controller.scrollHost.source }
    private var sourceText: String { sourceView.textView.string }

    /// ⌘B and ⌘I in the source: wrap the selection in the marks, unwrap it when it is wrapped, and with
    /// nothing selected put a pair down with the caret between. Leaves the text as it found it.
    private func sourceFormattingChecks() async {
        let textView = sourceView.textView
        controller.window?.makeFirstResponder(textView)
        let original = textView.string
        let word = (original as NSString).range(of: "Self-test")
        textView.setSelectedRange(word)
        let bold = keyEvent("b", .command, code: 11)
        await check("⌘B wraps the selection in bold marks, keeping it selected") {
            let handled = textView.performKeyEquivalent(with: bold)
            return handled && textView.string.contains("**Self-test**")
                && textView.selectedRange() == NSRange(location: word.location + 2, length: word.length)
        }
        await check("⌘B again unwraps it") {
            let handled = textView.performKeyEquivalent(with: bold)
            return handled && textView.string == original && textView.selectedRange() == word
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        let italic = keyEvent("i", .command, code: 34)
        await check("⌘I with nothing selected puts a pair of marks down with the caret between") {
            let handled = textView.performKeyEquivalent(with: italic)
            return handled && textView.string.hasPrefix("**") && textView.selectedRange() == NSRange(location: 1, length: 0)
        }
        textView.insertText("", replacementRange: NSRange(location: 0, length: 2))
        await check("the text is as it was after the formatting checks") { textView.string == original }
    }

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

    /// A menu action, sent down the window's responder chain from what has the keyboard (the web
    /// view, a card's field), then to the app. Not through the key window: that is nil while another
    /// app has the focus, and the action would be lost.
    private func send(_ action: String) {
        let selector = Selector((action))
        if controller.window?.firstResponder?.tryToPerform(selector, with: nil) == true { return }
        if controller.window?.tryToPerform(selector, with: nil) == true { return }
        NSApp.sendAction(selector, to: nil, from: nil)
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

    private func waitFor(_ condition: String, seconds: Double = 10, in view: WKWebView? = nil) async -> Bool {
        await until(seconds: seconds) { await self.js(condition, in: view ?? self.web) as? Bool == true }
    }

    private func until(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}
