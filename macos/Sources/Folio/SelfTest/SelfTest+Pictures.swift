import AppKit
import WebKit

/// Window pictures, for judging how things look (`FOLIO_SNAPSHOT`).
extension SelfTest {
    // MARK: pictures

    /// Pictures of the in-page controls, for judging how they look: annotation cards in
    /// the comments pane (one focused) and the floating comment button over a selection.
    func tour(_ base: String) async {
        controller.window?.makeFirstResponder(controller.webView)
        // The checks before this one left the document as they needed it; the pictures are of the fixture.
        replaceFile((try? String(contentsOf: source, encoding: .utf8)) ?? "")
        _ = await waitFor("document.querySelector('#editor-tiptap').innerText.includes('The last paragraph.')", seconds: 8)
        replaceSidecar([])
        _ = await until { self.controller.currentStore.annotations.isEmpty }
        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "minimal intervention", "--comment", "Is this claim sourced anywhere?"],
            ["--kind", "replace", "--context-before", "vineyard and the ", "--target", "cellar", "--replacement", "cave"],
            ["--kind", "highlight", "--context-before", "The last ", "--target", "paragraph"],
        ] {
            _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"])
        }
        if !pane.commentsOn {
            send("toggleComments:")
            _ = await until { self.pane.commentsOn && self.controller.scrollHost.paneWidth > 300 }
        }
        let settled = await until(seconds: 8) { self.visibleCards().count == 3 && self.pane.anchors.count == 3 }
        if !settled { print("    the tour's cards did not settle: \(visibleCards().count) visible, \(pane.anchors.count) anchored") }
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
        let clicked = await js("""
            (() => {
              const el = document.querySelector('#editor-tiptap .ann-comment-target')
              if (!el) return 0
              const r = el.getBoundingClientRect()
              const o = {bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5, button: 0}
              for (const type of ['mousedown', 'mouseup', 'click']) el.dispatchEvent(new MouseEvent(type, o))
              return 1
            })()
            """)
        let opened = await until { self.pane.focusedID != nil }
        if !opened {
            print("    the click on annotated text did not focus its annotation (page answered \(String(describing: clicked)), pane open \(pane.commentsOn))")
        }
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
            let found = await self.until { (await self.js("getSelection().toString()") as? String) == "last paragraph" }
            if !found {
                let selected = await self.js("getSelection().toString()") as? String
                let onPage = await self.js("document.body.innerText.includes('last paragraph')") as? Bool
                print("    selection \(String(describing: selected)), the text is on the page: \(String(describing: onPage))")
            }
            return found
        }
        await snapshot("\(base)-find.png")
    }

    /// The whole window, title bar and toolbar included.
    func snapshot(_ path: String, of target: EditorWindowController? = nil) async {
        let window = (target ?? controller).window
        window?.makeKeyAndOrderFront(nil)
        // A window that was behind another does not repaint until it is in front.
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let window { WindowPicture.write(window, to: path) }
    }
}
