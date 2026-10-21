import AppKit

/// The preview (the default; `-WebPreview YES` is the web one): what is drawn, how the text maps to the file, the
/// annotation UI on it, and accepting. The web page is not loaded in this mode, so this replaces
/// the checks that drive it.
extension SelfTest {
    var previewView: PreviewView { controller.scrollHost.preview! }
    var previewText: String { previewView.textView.string }

    func previewChecks() async {
        guard controller.scrollHost.preview != nil else {
            report("the preview is on", false)
            return finishPreview()
        }
        let textView = previewView.textView
        await check("the preview shows the document, and the web view stays hidden") {
            await self.until { self.previewView.window != nil && !self.previewView.isHidden && self.web.isHidden && self.previewText.contains("The last paragraph.") }
        }
        await check("the toolbar shows the preview as current") { !self.controller.sourceOn }
        await check("markdown syntax is not shown: no heading mark, no fences, and diagrams are pictures, not their code") {
            self.previewText.hasPrefix("Self-test document") && !self.previewText.contains("```") && !self.previewText.contains("flowchart TD")
        }
        await check("the heading is larger than the text") {
            let storage = textView.textStorage!
            let heading = storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont
            let body = (self.previewText as NSString).range(of: "The last paragraph.")
            let plain = storage.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
            return (heading?.pointSize ?? 0) > (plain?.pointSize ?? 99)
        }
        await check("the text starts close under the title bar") {
            guard let layout = textView.layoutManager else { return false }
            return layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + textView.textContainerOrigin.y < 60
        }
        await check("a mermaid diagram is drawn (by the hidden web view) and shown as a picture") {
            await self.until(seconds: 40) { self.previewView.picture("mermaid:") != nil }
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

        await check("fenced code in a list keeps its line-by-line map to the file, though the file indents it") {
            let md = "- item\n\n  ```js\n  const y = 1\n  let z = 2\n  ```\n"
            let built = PreviewBuilder.build(md)
            let shown = built.text.string as NSString
            let y = built.sourceRange(forDisplay: shown.range(of: "y = 1"))
            let z = built.sourceRange(forDisplay: shown.range(of: "z = 2"))
            return y == (md as NSString).range(of: "y = 1") && z == (md as NSString).range(of: "z = 2")
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
            await self.until(seconds: 10) { self.visibleCards().count == 3 && self.previewView.ranges.count == 3 && self.pane.anchors.count == 3 }
        }
        func pendingID(_ kind: AnnotationKind) -> String { self.controller.currentStore.pending.first { $0.kind == kind }?.id ?? "" }
        func attribute(_ key: NSAttributedString.Key, at index: Int) -> Any? {
            textView.layoutManager?.temporaryAttribute(key, atCharacterIndex: index, effectiveRange: nil)
        }
        await check("each range is the text its annotation is about") {
            let text = self.previewText as NSString
            guard let comment = self.previewView.ranges[pendingID(.comment)], let replace = self.previewView.ranges[pendingID(.replace)],
                  let highlight = self.previewView.ranges[pendingID(.highlight)] else { return false }
            return text.substring(with: comment) == "minimal intervention" && text.substring(with: replace) == "cellar" && text.substring(with: highlight) == "paragraph"
        }
        await check("a comment is tinted, a replaced word struck through") {
            guard let comment = self.previewView.ranges[pendingID(.comment)], let replace = self.previewView.ranges[pendingID(.replace)] else { return false }
            return attribute(.backgroundColor, at: comment.location) != nil && attribute(.strikethroughStyle, at: comment.location) == nil
                && attribute(.strikethroughStyle, at: replace.location) != nil
        }
        await check("the replacement is previewed right after the word, in green, and is not in the file") {
            let text = self.previewText as NSString
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
        let natural = (previewText as NSString).range(of: "Natural wine")
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
        pane.form?.onSend?("A preview comment")
        await check("sending the form writes a comment anchored on those words, and the CLI sees it") {
            let found = await self.until(seconds: 8) { self.controller.currentStore.pending.contains { $0.comment == "A preview comment" } }
            return found && self.pendingFromCLI() == 4
        }
        await check("the new comment is anchored on the same words") {
            await self.until(seconds: 8) {
                guard let id = self.controller.currentStore.pending.first(where: { $0.comment == "A preview comment" })?.id,
                      let range = self.previewView.ranges[id] else { return false }
                return (self.previewText as NSString).substring(with: range) == "Natural wine"
            }
        }

        // Clicks and ⌃J/⌃K.
        let commentID = pendingID(.comment)
        if let range = previewView.ranges[commentID] { textView.onClick?(range.location + 2) }
        await check("a click on annotated text focuses its card") { self.pane.focusedID == commentID }
        textView.onClick?(0)
        await check("a click on plain text clears the focus") { self.pane.focusedID == nil }
        await check("⌃J focuses the first annotation and puts the caret at its start") {
            let used = self.pane.handleKey(self.keyEvent("j", .control, code: 38))
            let first = self.pane.focusedID.flatMap { self.previewView.ranges[$0] }
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
            await self.until { self.previewText.contains("vineyard and the cave.") && !self.previewText.contains("cavecave") }
        }
        await check("accepting shows a toast") { self.pane.toastMessage == "Accepted replace" }

        // Rejecting, and Undo taking it back.
        let highlightID = pendingID(.highlight)
        textView.onClick?((previewText as NSString).range(of: "paragraph").location + 1)
        controller.window?.makeFirstResponder(textView)
        _ = pane.handleKey(keyEvent("\u{7f}", .control, code: 51))
        await check("⌃⌫ rejects the focused annotation") {
            await self.until { self.controller.currentStore.annotation(highlightID)?.resolved == true }
        }
        await check("its mark is gone from the text") {
            let at = (self.previewText as NSString).range(of: "paragraph").location
            return await self.until { attribute(.backgroundColor, at: at) == nil }
        }
        send("undoEdit:")
        await check("Undo takes the rejection back, and the mark returns") {
            await self.until { self.controller.currentStore.annotation(highlightID)?.resolved == false && self.previewView.ranges[highlightID] != nil }
        }

        // The source and back.
        send("toggleSource:")
        await check("the source replaces the preview, and the comments stay") {
            await self.until(seconds: 8) { self.controller.sourceOn && self.previewView.isHidden && !self.sourceView.isHidden && self.visibleCards().count > 0 }
        }
        sourceView.textView.insertText("ZZ", replacementRange: NSRange(location: 0, length: 0))
        _ = await until { self.disk().hasPrefix("ZZ") }
        send("toggleSource:")
        await check("back in the preview, what was typed in the source is shown") {
            await self.until(seconds: 8) { !self.controller.sourceOn && !self.previewView.isHidden && self.previewText.hasPrefix("ZZ# Self-test document") }
        }

        await blockChecks()
        await wideBlockChecks()
        await previewParityChecks()

        // Another program replaces the file the way agents do.
        replaceFile(disk() + "\nAdded by another program.\n")
        await check("an atomic replace from outside shows in the preview") {
            await self.until(seconds: 8) { self.previewText.contains("Added by another program.") }
        }
        await check("the annotations are anchored again in the new text") {
            await self.until { self.previewView.ranges.count == self.controller.currentStore.pending.count }
        }
        finishPreview()
    }

    /// Tables, images and diagrams, on a document of their own.
    func blockChecks() async {
        let textView = previewView.textView
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
        ---
        title: Hello there
        tags: [wine, notes]
        ---

        # Blocks

        ![a picture](pic.png)

        | Name | Count |
        |:-----|------:|
        | one  | 1 |
        | two  | 2 |

        > quoted text
        >
        > > deeper

        ---

        1. first
        2. second

        - [x] done
        - [ ] open

        ```js
        const x = 'a' // note
        ```

        ```plantuml
        @startuml
        Alice -> Bob: hello
        @enduml
        ```

        After.
        """
        replaceFile(md)
        await check("the frontmatter is a box of rows, not markdown: no rules, no heading, the values shown") {
            await self.until(seconds: 8) { self.previewText.hasPrefix("title\tHello there\ntags\twine, notes\n") }
                && !self.previewText.contains("---") && self.previewText.contains("Blocks")
        }
        await check("the box is marked for painting, in a small type, and the heading after it is large") {
            guard let storage = textView.textStorage else { return false }
            let text = self.previewText as NSString
            let box = storage.attribute(.folioBlock, at: 0, effectiveRange: nil) as? String
            let small = (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
            let heading = (storage.attribute(.font, at: text.range(of: "Blocks").location, effectiveRange: nil) as? NSFont)?.pointSize ?? 0
            return box == "box" && small < 14 && heading > 20
        }
        await check("a value in the box and the heading after it map to their place in the file") {
            let built = PreviewBuilder.build(md)
            let shown = built.text.string as NSString
            let hello = built.sourceRange(forDisplay: shown.range(of: "Hello there"))
            let heading = built.sourceRange(forDisplay: shown.range(of: "Blocks"))
            return hello == (md as NSString).range(of: "Hello there") && heading == (md as NSString).range(of: "Blocks")
        }
        await check("a quote has its bars (two deep for the inner one), a rule and a code block are painted, and no rule characters are typed") {
            guard let storage = textView.textStorage else { return false }
            let text = self.previewText as NSString
            let quoted = storage.attribute(.folioQuote, at: text.range(of: "quoted").location, effectiveRange: nil) as? Int
            let deeper = storage.attribute(.folioQuote, at: text.range(of: "deeper").location, effectiveRange: nil) as? Int
            let code = storage.attribute(.folioBlock, at: text.range(of: "const").location, effectiveRange: nil) as? String
            var rules = 0
            storage.enumerateAttribute(.folioBlock, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value as? String == "rule" { rules += 1 } }
            return quoted == 1 && deeper == 2 && code == "code" && rules == 1 && !self.previewText.contains("─")
        }
        await check("a table is drawn as cells, without its pipes and rule row") {
            await self.until(seconds: 8) { self.previewText.contains("Count") }
                && !self.previewText.contains("|") && !self.previewText.contains("---")
        }
        await check("each cell is in a table block of the text view") {
            let at = (self.previewText as NSString).range(of: "two").location
            guard at != NSNotFound,
                  let style = textView.textStorage?.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle else { return false }
            return !style.textBlocks.isEmpty
        }
        await check("a selection in a cell maps to its words in the file") {
            let shown = (self.previewText as NSString).range(of: "two")
            textView.setSelectedRange(shown)
            return await self.until { self.pane.selection?.target == "two" }
                && self.pane.selection?.from == (md as NSString).range(of: "two").location
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        await check("numbers and task boxes are drawn, and are not in the file") {
            self.previewText.contains("1.\tfirst") && self.previewText.contains("☑\tdone") && self.previewText.contains("☐\topen")
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
        await check("code in a block with a language is coloured: a keyword, a string and a comment differ from plain text") {
            await self.until(seconds: 20) {
                let text = self.previewText as NSString
                guard let storage = textView.textStorage else { return false }
                func color(_ word: String, offset: Int = 0) -> NSColor? {
                    let at = text.range(of: word).location
                    return at == NSNotFound ? nil : storage.attribute(.foregroundColor, at: at + offset, effectiveRange: nil) as? NSColor
                }
                guard let keyword = color("const x"), let string = color("'a'"), let comment = color("// note"),
                      let plain = color("const x", offset: 6) else { return false }
                return !keyword.isEqual(plain) && !string.isEqual(plain) && !comment.isEqual(plain) && !keyword.isEqual(string)
            }
        }
        // Needs the network, like the page's check: a failure says where.
        report("a PlantUML block is drawn from the server", await until(seconds: 20) { self.previewView.picture("plantuml:") != nil })
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            controller.scrollHost.contentView.scroll(to: .zero)
            controller.scrollHost.reflectScrolledClipView(controller.scrollHost.contentView)
            await snapshot("\(base)-blocks.png")
        }
    }

    /// Tables and pictures may be wider than the text column, up to the right side of a wide window;
    /// the text, and anything narrower, keeps the column.
    func wideBlockChecks() async {
        let textView = previewView.textView
        if pane.commentsOn {
            send("toggleComments:")
            _ = await until { !self.pane.commentsOn && self.controller.scrollHost.paneWidth == 0 }
        }
        controller.window?.setContentSize(NSSize(width: 1500, height: 800))
        let wide = NSImage(size: NSSize(width: 1300, height: 100), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        if let tiff = wide.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: dir.appendingPathComponent("wide.png"))
        }
        let headers = (1...8).map { "Alphabetical\($0)" }
        let md = """
        # Wide

        A paragraph of text that stays in its column however wide the window is, so that its margins can be compared.

        ![wide](wide.png)

        | \(headers.joined(separator: " | ")) |
        |\(String(repeating: "---|", count: 8))
        | \((1...8).map { "value-number-\($0)" }.joined(separator: " | ")) |

        | Short | Table |
        |---|---|
        | a | b |
        """
        replaceFile(md)
        _ = await until(seconds: 8) { self.previewText.contains("Alphabetical8") }
        guard let layout = textView.layoutManager, let container = textView.textContainer else {
            report("the text view has a layout", false)
            return
        }
        let origin = textView.textContainerOrigin
        func extent(_ word: String) -> (min: CGFloat, max: CGFloat)? {
            let at = (self.previewText as NSString).range(of: word)
            guard at.location != NSNotFound else { return nil }
            let rect = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: at, actualCharacterRange: nil), in: container)
            return (rect.minX + origin.x, rect.maxX + origin.x)
        }
        let column: CGFloat = 760
        let side = (container.size.width - column) / 2
        let textLeft = origin.x + side
        await check("a window wider than the text column leaves the text in its column") {
            guard let paragraph = extent("A paragraph") else { return false }
            return abs(paragraph.min - textLeft) < 2 && textView.columnInset > 100
        }
        await check("a picture wider than the column starts at the column's left edge and runs past its right edge") {
            let ok = await self.until(seconds: 10) {
                guard let storage = textView.textStorage else { return false }
                var width: CGFloat = 0
                storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
                    if let attachment = value as? NSTextAttachment, attachment.image != nil { width = max(width, attachment.bounds.width) }
                }
                return width > column + 100
            }
            if !ok { print("    container \(container.size.width), column inset \(textView.columnInset)") }
            return ok
        }
        await check("a table whose content is wider than the column is wider than it, from the same left edge") {
            guard let first = extent("Alphabetical1"), let last = extent("value-number-8") else {
                print("    cells not found")
                return false
            }
            let ok = abs(first.min - textLeft) < 16 && last.max > textLeft + column + 20 && last.max < origin.x + container.size.width
            if !ok { print("    text left \(textLeft), first cell \(first), last cell \(last), container \(container.size.width)") }
            return ok
        }
        await check("a small table is as wide as the text column") {
            guard let a = extent("Short"), let b = extent("Table") else { return false }
            // Two equal columns across the text column: the second starts half way (plus its padding).
            let ok = abs(a.min - textLeft) < 16 && abs(b.min - (textLeft + column / 2)) < 20
            if !ok { print("    text left \(textLeft), cells \(a) \(b)") }
            return ok
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            controller.scrollHost.contentView.scroll(to: .zero)
            controller.scrollHost.reflectScrolledClipView(controller.scrollHost.contentView)
            await snapshot("\(base)-wide.png")
        }
        controller.window?.setContentSize(NSSize(width: 1100, height: 800))
    }

    private func finishPreview() {
        // finish() prints the verdict; run() returns it.
        previewVerdict = finish()
    }
}
