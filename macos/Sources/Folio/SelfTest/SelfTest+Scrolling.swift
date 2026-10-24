import AppKit

/// The text's layout and the window's scrolling: wide tables, anchoring on markdown that renders differently,
/// the wheel, the caret and drags.
extension SelfTest {
    /// A table wider than the window must not widen the document: the extra width would push the
    /// comments pane off screen. The preview is showing and the comments pane is open.
    func wideTableChecks() async {
        let original = disk()
        let cells = (1...8).map { _ in String(repeating: "W", count: 60) }
        let row = "| " + cells.joined(separator: " | ") + " |"
        let header = "| " + (1...8).map { "Column\($0)" }.joined(separator: " | ") + " |"
        let rule = "|" + String(repeating: " --- |", count: 8)
        replaceFile("# Wide\n\n\(header)\n\(rule)\n\(row)\n\(row)\n\nFinal line after the table.\n")
        _ = await until(seconds: 8) { self.previewText.contains("Final line after the table.") }
        replaceSidecar([commentJSON("wt1", before: "Final ", target: "line after")])

        let host = controller.scrollHost
        // The document is no wider than the window, and the pane's card is on screen.
        await check("a wide table in the preview does not push the comments pane off screen") {
            let shown = await self.until(seconds: 8) { self.visibleCards().count == 1 }
            let fits = (host.documentView?.frame.width ?? 9999) <= host.contentSize.width + 1
                && self.previewView.frame.maxX <= host.contentSize.width - host.paneWidth + 1
            return shown && fits
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-wide-table.png") }
        send("toggleSource:")
        await check("a wide table in the source view wraps and does not push the comments pane off screen") {
            let shown = await self.until(seconds: 8) { self.controller.sourceOn && self.visibleCards().count == 1 }
            let fits = (host.documentView?.frame.width ?? 9999) <= host.contentSize.width + 1
                && self.sourceView.frame.maxX <= host.contentSize.width - host.paneWidth + 1
            return shown && fits
        }
        send("toggleSource:")
        _ = await until(seconds: 8) { !self.controller.sourceOn }
        replaceSidecar([])
        replaceFile(original)
        _ = await until(seconds: 8) { !self.previewText.contains("Final line after the table.") }
    }

    /// Anchoring against the preview's own text, and reloads. The preview is showing.
    func anchoringChecks() async {
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
        _ = await until(seconds: 8) { self.previewText.contains("Final target sentence") }
        replaceSidecar([commentJSON("pa1", before: "Final ", target: "target sentence")])
        await check("a highlight after markdown the CLI renders differently lands on its target") {
            await self.previewHighlights("target sentence")
        }

        // Anchors after a hard break (two trailing spaces), written with and without them.
        replaceFile("# Hard break\n\nA second paragraph gives the tests something else to select and annotate.\n\n**Description:**  \nThe sample application processes incoming requests.\n")
        _ = await until(seconds: 8) { self.previewText.contains("The sample application") }
        replaceSidecar([commentJSON("hb1", before: "A second paragraph gives the tests something else to select and annotate.Description:", target: "The sample application")])
        await check("an annotation after a hard break highlights its target in preview") {
            await self.previewHighlights("The sample application")
        }
        replaceSidecar([commentJSON("hb2", before: "Description:  The ", target: "sample application")])
        await check("an anchor saved with the hard break spaces highlights its target in preview") {
            await self.previewHighlights("sample application")
        }
        replaceSidecar([])

        // Reloading changed text into the live preview shows it.
        replaceFile(original + "\n\n- a\n- b\n\n| x | y |\n|---|---|\n| 1 | 2 |\n\n```js\nlet a = 1\n```\n")
        await check("the preview shows text that changed underneath it") {
            await self.until(seconds: 8) { self.previewText.contains("let a = 1") }
        }
        replaceFile(original)
        _ = await until(seconds: 8) { !self.previewText.contains("let a = 1") }

        // A selection right after a code block: its context is the rendered text, without the code.
        replaceFile("# Code\n\nIntro text.\n\n```js\nlet a = 1\n```\n\nAfter the code block here.\n")
        _ = await until(seconds: 8) { self.previewText.contains("After the code block") }
        await selectInPreview("After the code block", from: 10, length: 10)
        await check("the context of a selection after a code block leaves the code out, and anchors") {
            guard await self.until(seconds: 5, { self.pane.selection?.target == "code block" }),
                  let context = self.pane.selection?.contextBefore, context == "CodeIntro text.After the " else { return false }
            self.replaceSidecar([self.commentJSON("cb1", before: context, target: "code block")])
            return await self.previewHighlights("code block")
        }
        replaceSidecar([])
        replaceFile(original)
        _ = await until(seconds: 8) { !self.previewText.contains("After the code block") }
    }

    /// The scroll view has to follow the wheel, Find and a selection dragged past the window's edge, and
    /// the caret when typing in the source. Run on a long document, scrolled to the top, in whichever
    /// of the preview and the source the window shows.
    func scrollingChecks(_ win: SetWindowController) async {
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
        let textView = preview ? host.preview.textView : host.source.textView

        // The text gets the wheel; it has nothing to scroll by itself, so the scroll view must.
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -400, wheel2: 0, wheel3: 0),
           let wheel = NSEvent(cgEvent: cg) {
            textView.scrollWheel(with: wheel)
        }
        await check("a wheel event over the \(label) scrolls the window's scroll view") {
            await self.until { host.scrollOffset > 100 }
        }
        toTop()

        // Typing at the end of a long document keeps the caret in view. The preview is read-only.
        if !preview {
            win.window?.makeFirstResponder(textView)
            let end = NSRange(location: (textView.string as NSString).length, length: 0)
            textView.setSelectedRange(end)
            textView.insertText("X", replacementRange: end)
            await check("typing at the end of the source scrolls the caret into view") {
                await self.until {
                    guard let layout = textView.layoutManager else { return false }
                    let glyph = layout.glyphIndexForCharacter(at: max(0, (textView.string as NSString).length - 1))
                    let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                    let top = textView.frame.minY + line.minY + textView.textContainerOrigin.y
                    return top > 1000 && top >= host.scrollOffset && top + line.height <= host.scrollOffset + host.contentSize.height
                }
            }
            toTop()
        }

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
        await check("dragging a selection past the edge of the \(label) scrolls the window") {
            if host.scrollOffset <= 40 { print("    offset \(host.scrollOffset) selection \(textView.selectedRange()) area \(area)") }
            return host.scrollOffset > 40
        }
        toTop()
    }
}
