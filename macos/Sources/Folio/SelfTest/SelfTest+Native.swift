import AppKit

/// The native preview (`-NativePreview YES`): what is drawn, how the text maps to the file, the
/// annotation UI on it, and accepting. The web page is not loaded in this mode, so this replaces
/// the checks that drive it.
extension SelfTest {
    var nativeView: NativePreviewView { controller.scrollHost.native! }
    var nativeText: String { nativeView.textView.string }

    func nativePreviewChecks() async {
        guard controller.scrollHost.native != nil else {
            report("the native preview is on", false)
            return finishNative()
        }
        let textView = nativeView.textView
        await check("the native preview shows the document, and the web view stays hidden") {
            await self.until { self.nativeView.window != nil && !self.nativeView.isHidden && self.web.isHidden && self.nativeText.contains("The last paragraph.") }
        }
        await check("the toolbar shows the preview as current") { !self.controller.sourceOn }
        await check("markdown syntax is not shown: no heading mark, no fences, and diagrams are pictures, not their code") {
            self.nativeText.hasPrefix("Self-test document") && !self.nativeText.contains("```") && !self.nativeText.contains("flowchart TD")
        }
        await check("the heading is larger than the text") {
            let storage = textView.textStorage!
            let heading = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            let body = (self.nativeText as NSString).range(of: "The last paragraph.")
            let plain = storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
            return (heading?.pointSize ?? 0) > (plain?.pointSize ?? 99)
        }
        await check("the text starts close under the title bar") {
            guard let layout = textView.layoutManager else { return false }
            return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + textView.textContainerOrigin.y < 60
        }
        await check("a mermaid diagram is drawn (by the hidden web view) and shown as a picture") {
            await self.until(seconds: 20) { self.nativeView.hasPicture("mermaid:") }
        }
        await check("the page is as tall as its text, which the window scrolls") {
            self.controller.scrollHost.contentHeight >= textView.frame.height - 1 && textView.frame.height > 200
        }

        // The map between what is on screen and the file.
        await check("a displayed range maps to the same words in the file, and back") {
            let md = self.disk()
            let built = PreviewBuilder.build(md)
            let shown = (built.text.string as NSString).range(of: "minimal intervention")
            let inFile = (md as NSString).range(of: "minimal intervention")
            return built.sourceRange(forDisplay: shown) == inFile && built.displayRange(forSource: inFile) == shown
        }
        await check("emphasis marks and list bullets are skipped by the map") {
            let md = "A **bold** word\n\n- one\n- two\n"
            let built = PreviewBuilder.build(md)
            let shown = built.text.string as NSString
            let bold = built.sourceRange(forDisplay: shown.range(of: "bold word"))
            let bullet = built.sourceRange(forDisplay: NSRange(location: shown.range(of: "one").location - 2, length: 1))
            let one = built.sourceRange(forDisplay: shown.range(of: "one"))
            return bold == (md as NSString).range(of: "bold** word") && bullet == nil && one == (md as NSString).range(of: "one")
        }

        // An agent annotates through the CLI; the cards and marks follow.
        send("toggleComments:")
        _ = await until { self.controller.commentsOn && self.controller.scrollHost.paneWidth > 300 }
        for args in [
            ["--kind", "comment", "--context-before", "Natural wine is made with ", "--target", "minimal intervention", "--comment", "Is this claim sourced anywhere?"],
            ["--kind", "replace", "--context-before", "vineyard and the ", "--target", "cellar", "--replacement", "cave"],
            ["--kind", "highlight", "--context-before", "The last ", "--target", "paragraph"],
        ] { _ = cli(["annotate", name] + args + ["--author", "agent", "--source", "agent"]) }
        await check("the annotations are anchored, with a card in the pane for each") {
            await self.until(seconds: 10) { self.visibleCards().count == 3 && self.nativeView.ranges.count == 3 && self.pane.anchors.count == 3 }
        }
        func pendingID(_ kind: AnnotationKind) -> String { self.controller.currentStore.pending.first { $0.kind == kind }?.id ?? "" }
        func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
            textView.layoutManager?.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil)
        }
        await check("each range is the text its annotation is about") {
            let text = self.nativeText as NSString
            guard let comment = self.nativeView.ranges[pendingID(.comment)], let replace = self.nativeView.ranges[pendingID(.replace)],
                  let highlight = self.nativeView.ranges[pendingID(.highlight)] else { return false }
            return text.substring(with: comment) == "minimal intervention" && text.substring(with: replace) == "cellar" && text.substring(with: highlight) == "paragraph"
        }
        await check("a comment is tinted, a replaced word struck through") {
            guard let comment = self.nativeView.ranges[pendingID(.comment)], let replace = self.nativeView.ranges[pendingID(.replace)] else { return false }
            return attribute(.backgroundColor, at: comment.location) != nil && attribute(.strikethroughStyle, at: comment.location) == nil
                && attribute(.strikethroughStyle, at: replace.location) != nil
        }
        await check("the replacement is previewed right after the word, in green, and is not in the file") {
            let text = self.nativeText as NSString
            let at = text.range(of: "cellarcave.")
            guard at.location != NSNotFound else { return false }
            let ghost = textView.textStorage!.attribute(.folioGhost, at: at.location + 6, effectiveRange: nil) as? String
            return ghost == pendingID(.replace) && !self.disk().contains("cellarcave")
        }
        await check("the cards sit where their text is, in document order") {
            let tops = ["comment", "replace", "highlight"].compactMap { self.pane.anchors[pendingID(AnnotationKind(name: $0))]?.top }
            return tops.count == 3 && tops == tops.sorted() && tops[0] > 0
        }

        // Selecting text offers the Comment button, and the words are the rendered ones.
        controller.window?.makeFirstResponder(textView)
        let natural = (nativeText as NSString).range(of: "Natural wine")
        textView.setSelectedRange(natural)
        await check("selecting text shows the Comment button, with the words and their place in the file") {
            let shown = await self.until { self.pane.selection?.target == "Natural wine" && !self.pane.adderIsHidden }
            return shown && self.pane.selection?.from == (self.disk() as NSString).range(of: "Natural wine").location
        }
        pane.pressCommentButton()
        await check("the Comment button opens the form with the keyboard in it, and the text stays highlighted") {
            guard let form = self.pane.form else { return false }
            return (self.controller.window?.firstResponder as? NSView)?.isDescendant(of: form) == true
                && attribute(.backgroundColor, at: natural.location) != nil
        }
        pane.form?.onSend?("A native comment")
        await check("sending the form writes a comment anchored on those words, and the CLI sees it") {
            let found = await self.until(seconds: 8) { self.controller.currentStore.pending.contains { $0.comment == "A native comment" } }
            return found && self.pendingFromCLI() == 4
        }
        await check("the new comment is anchored on the same words") {
            await self.until(seconds: 8) {
                guard let id = self.controller.currentStore.pending.first(where: { $0.comment == "A native comment" })?.id,
                      let range = self.nativeView.ranges[id] else { return false }
                return (self.nativeText as NSString).substring(with: range) == "Natural wine"
            }
        }

        // Clicks and ⌃J/⌃K.
        let commentID = pendingID(.comment)
        if let range = nativeView.ranges[commentID] { textView.onClick?(range.location + 2) }
        await check("a click on annotated text focuses its card") { self.pane.focusedID == commentID }
        textView.onClick?(0)
        await check("a click on plain text clears the focus") { self.pane.focusedID == nil }
        await check("⌃J focuses the first annotation and puts the caret at its start") {
            let used = self.pane.handleKey(self.keyEvent("j", .control, code: 38))
            let first = self.pane.focusedID.flatMap { self.nativeView.ranges[$0] }
            return used && first != nil && textView.selectedRange().location == first?.location
        }
        textView.onClick?(0)

        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            controller.scrollHost.contentView.scroll(to: .zero)
            controller.scrollHost.reflectScrolledClipView(controller.scrollHost.contentView)
            if let id = controller.currentStore.pending.first?.id, let card = pane.cards[id] { click(card) }
            await snapshot("\(base)-cards.png")
        }

        // Accepting patches the file; the preview follows it and the preview of the suggestion goes.
        press("accept", inCardOf: pendingID(.replace))
        await check("accepting a replacement patches the file") { await self.until { self.disk().contains("vineyard and the cave.") } }
        await check("the preview shows the patched text, once") {
            await self.until { self.nativeText.contains("vineyard and the cave.") && !self.nativeText.contains("cavecave") }
        }
        await check("accepting shows a toast") { self.pane.toastMessage == "Accepted replace" }

        // Rejecting, and Undo taking it back.
        let highlightID = pendingID(.highlight)
        textView.onClick?((nativeText as NSString).range(of: "paragraph").location + 1)
        controller.window?.makeFirstResponder(textView)
        _ = pane.handleKey(keyEvent("\u{7f}", .control, code: 51))
        await check("⌃⌫ rejects the focused annotation") {
            await self.until { self.controller.currentStore.annotation(highlightID)?.resolved == true }
        }
        await check("its mark is gone from the text") {
            let at = (self.nativeText as NSString).range(of: "paragraph").location
            return await self.until { attribute(.backgroundColor, at: at) == nil }
        }
        send("undoEdit:")
        await check("Undo takes the rejection back, and the mark returns") {
            await self.until { self.controller.currentStore.annotation(highlightID)?.resolved == false && self.nativeView.ranges[highlightID] != nil }
        }

        // The source and back.
        send("toggleSource:")
        await check("the source replaces the preview, and the comments stay") {
            await self.until(seconds: 8) { self.controller.sourceOn && self.nativeView.isHidden && !self.sourceView.isHidden && self.visibleCards().count > 0 }
        }
        sourceView.textView.insertText("ZZ", replacementRange: NSRange(location: 0, length: 0))
        _ = await until { self.disk().hasPrefix("ZZ") }
        send("toggleSource:")
        await check("back in the preview, what was typed in the source is shown") {
            await self.until(seconds: 8) { !self.controller.sourceOn && !self.nativeView.isHidden && self.nativeText.hasPrefix("ZZ# Self-test document") }
        }

        await blockChecks()
        await nativeParityChecks()

        // Another program replaces the file the way agents do.
        replaceFile(disk() + "\nAdded by another program.\n")
        await check("an atomic replace from outside shows in the preview") {
            await self.until(seconds: 8) { self.nativeText.contains("Added by another program.") }
        }
        await check("the annotations are anchored again in the new text") {
            await self.until { self.nativeView.ranges.count == self.controller.currentStore.pending.count }
        }
        finishNative()
    }

    /// Tables, images and diagrams, on a document of their own.
    func blockChecks() async {
        let textView = nativeView.textView
        replaceSidecar([])
        let image = NSImage(size: NSSize(width: 80, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("pic.png"))
        }
        let md = """
        # Blocks

        ![a picture](pic.png)

        | Name | Count |
        |:-----|------:|
        | one  | 1 |
        | two  | 2 |

        1. first
        2. second

        - [x] done
        - [ ] open

        ```plantuml
        @startuml
        Alice -> Bob: hello
        @enduml
        ```

        After.
        """
        replaceFile(md)
        await check("a table is drawn as cells, without its pipes and rule row") {
            await self.until(seconds: 8) { self.nativeText.contains("Count") }
                && !self.nativeText.contains("|") && !self.nativeText.contains("---")
        }
        await check("each cell is in a table block of the text view") {
            let at = (self.nativeText as NSString).range(of: "two").location
            guard at != NSNotFound,
                  let style = textView.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle else { return false }
            return !style.textBlocks.isEmpty
        }
        await check("a selection in a cell maps to its words in the file") {
            let shown = (self.nativeText as NSString).range(of: "two")
            textView.setSelectedRange(shown)
            return await self.until { self.pane.selection?.target == "two" }
                && self.pane.selection?.from == (md as NSString).range(of: "two").location
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        await check("numbers and task boxes are drawn, and are not in the file") {
            self.nativeText.contains("1.\tfirst") && self.nativeText.contains("☑\tdone") && self.nativeText.contains("☐\topen")
        }
        await check("a local image is loaded and shown at its own size") {
            await self.until(seconds: 8) {
                guard let storage = textView.textStorage else { return false }
                var found = false
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let attachment = value as? NSTextAttachment, attachment.image != nil, attachment.bounds.width == 80 { found = true }
                }
                return found
            }
        }
        // Needs the network, like the page's check: a failure says where.
        report("a PlantUML block is drawn from the server", await until(seconds: 20) { self.nativeView.hasPicture("plantuml:") })
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            controller.scrollHost.contentView.scroll(to: .zero)
            controller.scrollHost.reflectScrolledClipView(controller.scrollHost.contentView)
            await snapshot("\(base)-blocks.png")
        }
    }

    private func finishNative() {
        // finish() prints the verdict; run() returns it.
        nativeVerdict = finish()
    }
}
