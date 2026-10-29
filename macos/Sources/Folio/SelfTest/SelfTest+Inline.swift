import AppKit
import FolioKit

/// The cards in the text under their rows (View ▸ Comments Inline), in the preview and the source.
extension SelfTest {
    /// The preview is showing with the comments pane open; left that way, with the file as it was.
    func inlineChecks() async {
        let original = disk()
        let wasInline = AppConfig.commentsInline
        AppConfig.commentsInline = false
        // Filler after it, so the window can scroll the lines with cards to its top.
        let filler = (1...30).map { "Filler paragraph \($0)." }.joined(separator: "\n\n")
        replaceFile("# Inline\n\nFirst paragraph with two notes in it.\n\nSecond paragraph stays plain.\n\nLast line here.\n\n\(filler)\n")
        _ = await until(seconds: 8) { self.previewText.contains("Last line here.") }
        // A thread a collapsed card has something to cut short in: a long comment and a reply.
        var longThread = commentJSON("in3", before: "Last ", target: "line here")
        longThread["comment"] = "A longer comment, so the collapsed card has more to cut off: it runs past the width of the column, on to a second line."
        longThread["replies"] = [["id": "in3-r1", "author": "me", "source": "local", "body": "And a reply, which the collapsed card counts.",
                                  "created": "2026-01-01T00:01:00Z"]]
        replaceSidecar([
            commentJSON("in1", before: "First paragraph ", target: "with two"),
            commentJSON("in2", before: "First paragraph with two ", target: "notes"),
            longThread,
            commentJSON("in4", before: "no such text anywhere ", target: "nowhere"),
        ])
        _ = await until(seconds: 8) { self.pane.anchorsKnown && self.pane.anchors.count == 3 && self.pane.cards.count == 4 }

        let toggle = NSMenuItem(title: "", action: #selector(EditorWindowController.toggleCommentsInline(_:)), keyEquivalent: "")
        await check("Comments Inline is dimmed while the comments pane is open") { !self.controller.validateMenuItem(toggle) }
        send("toggleComments:")
        _ = await until { !self.controller.commentsOn && self.controller.scrollHost.paneWidth == 0 }

        /// The top of the line where `words` start, in the text that is showing.
        func top(of words: String) -> CGFloat? {
            let textView: NSTextView = controller.sourceOn ? sourceView.textView : previewView.textView
            let at = (textView.string as NSString).range(of: words).location
            guard at != NSNotFound, let spot = TextSurface.position(of: at, in: textView) else { return nil }
            return CGFloat(spot.top)
        }
        let canvas = controller.scrollHost.floatingHost
        func card(_ id: String) -> AnnotationCardView? { pane.cards[id] }
        /// Each card in the text under its row, the two of the first row in document order, and the text
        /// after a row below its cards.
        func underRows(next: String) -> Bool {
            guard let in1 = card("in1"), let in2 = card("in2"), let in3 = card("in3"),
                  let row1 = pane.anchors["in1"]?.row, let row3 = pane.anchors["in3"]?.row,
                  let after = top(of: next) else { return false }
            let inText = [in1, in2, in3].allSatisfy { $0.superview === canvas && $0.isInline && abs($0.frame.minX - pane.surface.inlineColumn.left) < 1 }
            return inText && in1.frame.minY >= row1.bottom && in1.frame.maxY <= in2.frame.minY && in2.frame.maxY < after
                && in3.frame.minY >= row3.bottom
        }

        let plainTop = top(of: "Second paragraph")
        send("toggleCommentsInline:")
        await check("Comments Inline is ticked and can be turned off again while the pane is closed") {
            AppConfig.commentsInline && self.controller.validateMenuItem(toggle) && toggle.state == .on
        }
        await check("in the preview, every card sits under its paragraph, in document order") {
            await self.until(seconds: 8) { underRows(next: "Second paragraph") }
        }
        await check("Collapse All Comments folds every inline card and Expand All Comments opens them again") {
            let fold = NSMenuItem(title: "", action: #selector(EditorWindowController.collapseAllComments(_:)), keyEquivalent: "")
            guard self.controller.validateMenuItem(fold) else { return false }
            send("collapseAllComments:")
            guard await self.until(seconds: 4, { self.pane.cards.values.allSatisfy(\.isCollapsed) }) else { return false }
            send("expandAllComments:")
            return await self.until(seconds: 4) { self.pane.cards.values.allSatisfy { !$0.isCollapsed } }
        }
        await check("the text after a paragraph with cards moves down to make room for them") {
            guard let plainTop, let moved = top(of: "Second paragraph"), let in1 = card("in1"), let in2 = card("in2") else { return false }
            return moved >= plainTop + in1.frame.height + in2.frame.height
        }
        await check("a card not found in the document is parked after the text, dimmed") {
            guard let lost = card("in4"), let in3 = card("in3") else { return false }
            return lost.superview === canvas && lost.isUnanchored && lost.frame.minY > in3.frame.maxY
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-inline-preview.png") }

        // Collapsing folds a card to one line; focusing it opens it again.
        press("collapse", inCardOf: "in1")
        await check("Collapse folds an inline card to its header and one line, the card under it right below") {
            await self.until {
                guard let in1 = card("in1"), let in2 = card("in2") else { return false }
                return in1.isCollapsed && in1.frame.height == AnnotationCardView.collapsedHeight && abs(in2.frame.minY - (in1.frame.maxY + 6)) < 1
            }
        }
        await check("focusing a collapsed card opens it") {
            self.pane.reveal(annotation: "in1")
            return await self.until { card("in1")?.isCollapsed == false && card("in1")?.isFocused == true }
        }
        previewView.textView.onPointer?()
        previewView.textView.onClick?(nil)
        await check("a click on plain text drops the focus and leaves the cards in the text") {
            await self.until { self.pane.focusedID == nil && underRows(next: "Second paragraph") }
        }
        press("collapse", inCardOf: "in3")
        _ = await until { card("in3")?.isCollapsed == true }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 400_000_000)
            await snapshot("\(base)-inline-collapsed.png")
        }

        // The source: the cards under the lines, and they follow the text as it is typed.
        send("toggleSource:")
        _ = await until { self.controller.sourceOn && !self.sourceView.isHidden }
        await check("in the source, every card sits under its line") {
            await self.until(seconds: 8) { underRows(next: "Second paragraph") }
        }
        await check("a card collapsed in the preview is still collapsed in the source") { card("in3")?.isCollapsed == true }
        let textView = sourceView.textView
        let before = card("in1")?.frame.minY ?? 0
        controller.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.insertText("A line typed above.\n\n", replacementRange: NSRange(location: 0, length: 0))
        await check("typing above a line moves its cards down with it") {
            await self.until { (card("in1")?.frame.minY ?? 0) > before + 10 && underRows(next: "Second paragraph") }
        }
        // After the annotated words, so both annotations are still found when the preview anchors them again.
        let notes = (textView.string as NSString).range(of: "notes in it")
        textView.insertText(" really", replacementRange: NSRange(location: notes.location + 5, length: 0))
        await check("typing in the annotated line keeps its cards under it") {
            await self.until { underRows(next: "Second paragraph") }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-inline-source.png") }
        _ = await until(seconds: 5) { !self.sourceView.hasUnsavedEdits }
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn }

        // Opening the pane takes the cards out of the text.
        send("toggleComments:")
        await check("opening the pane moves the cards into it and gives the text its room back") {
            await self.until {
                guard let in1 = card("in1"), let next = top(of: "Second paragraph"), let row = self.pane.anchors["in1"]?.row else { return false }
                return self.controller.scrollHost.paneWidth > 300 && in1.superview === self.controller.scrollHost.gutter && !in1.isInline
                    && abs(next - row.next) < 1
            }
        }

        // Room coming and going above the line at the top of the window does not move that line.
        let host = controller.scrollHost
        if let second = top(of: "Second paragraph") {
            host.contentView.scroll(to: NSPoint(x: 0, y: second + 5 - host.contentInsets.top))
            host.reflectScrolledClipView(host.contentView)
        }
        func onScreen() -> CGFloat { (top(of: "Second paragraph") ?? 0) - host.visibleDocumentRect.minY }
        let shownAt = onScreen()
        let scrolledTo = host.visibleDocumentRect.minY
        send("toggleComments:")
        await check("closing the pane puts the cards in the text without moving the line at the top of the window") {
            let kept = await self.until {
                !self.controller.commentsOn && host.paneWidth == 0 && card("in1")?.superview === canvas && abs(onScreen() - shownAt) < 2
            }
            if !kept {
                print("    the line was \(shownAt) from the top, now \(onScreen()); the window was at \(scrolledTo), now \(host.visibleDocumentRect.minY);"
                      + " the document is \(host.documentView?.frame.height ?? 0) tall, in1 is in the text: \(card("in1")?.superview === canvas)")
            }
            return kept
        }
        send("toggleComments:")
        _ = await until { self.controller.commentsOn && host.paneWidth > 300 }

        AppConfig.commentsInline = wasInline
        replaceSidecar([])
        replaceFile(original)
        _ = await until(seconds: 8) { !self.previewText.contains("Last line here.") }
    }
}
