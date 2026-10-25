import AppKit

/// Window pictures, for judging how things look (`FOLIO_SNAPSHOT`).
extension SelfTest {
    // MARK: pictures

    /// Pictures of the annotation controls, for judging how they look: annotation cards in
    /// the comments pane (one focused) and the floating comment button over a selection.
    func tour(_ base: String) async {
        let textView = previewView.textView
        controller.window?.makeFirstResponder(textView)
        // The checks before this one left the document as they needed it; the pictures are of the fixture.
        replaceFile(fixture)
        _ = await until(seconds: 8) { self.previewText.contains("The last paragraph.") }
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
        let target = pane.cards.values
            .compactMap { previewView.ranges[$0.annotation.id] }
            .min { $0.location < $1.location }
        if let target { textView.onClick?(target.location + 2) }
        let opened = await until { self.pane.focusedID != nil }
        if !opened {
            print("    the click on annotated text did not focus its annotation (a target \(target != nil), pane open \(pane.commentsOn))")
        }
        toTop()
        try? await Task.sleep(nanoseconds: 500_000_000)
        await snapshot("\(base)-overlay.png")
        send("toggleComments:")
        _ = await until { self.pane.commentsOn }

        // Find: the Edit menu focuses the toolbar's search field, Return selects the match in the text.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        controller.window?.makeFirstResponder(textView)
        controller.setFindExpanded(false)
        await check("the search folds into its icon") {
            await self.until { !controller.findExpanded && controller.findItem.searchField.frame.width < 60 }
        }
        await snapshot("\(base)-find-collapsed.png")
        controller.findItem.searchField.stringValue = ""
        // A click on the folded field focuses it where it is: that unfolds it too, and it keeps the keyboard.
        controller.window?.makeFirstResponder(controller.findItem.searchField)
        await check("focusing the folded search field unfolds it and keeps the keyboard") {
            let unfolded = await self.until { controller.findExpanded && controller.findItem.searchField.frame.width > 200 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            let editor = controller.window?.firstResponder as? NSText
            let editing = editor?.delegate === controller.findItem.searchField
            // Its text is laid out for the unfolded field, clear of the magnifier.
            let laidOut = ((editor as? NSView)?.frame.width ?? 0) > 150 && ((editor as? NSView)?.frame.minX ?? 0) > 15
            if !(unfolded && editing && laidOut) { print("    unfolded \(unfolded) editing \(editing) editor \(String(describing: (editor as? NSView)?.frame)) field \(controller.findItem.searchField.frame)") }
            return unfolded && editing && laidOut && controller.findExpanded
        }
        controller.window?.makeFirstResponder(textView)
        await check("it folds back when it is left empty") {
            await self.until { !controller.findExpanded }
        }
        let find = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }?.item(withTitle: "Find…")
        await check("Edit has Find with ⌘F") { find?.keyEquivalent == "f" && find?.keyEquivalentModifierMask == .command }
        if let find, let action = find.action { send(NSStringFromSelector(action)) }
        await check("Find focuses the search field") {
            await self.until { (controller.window?.firstResponder as? NSText)?.delegate === controller.findItem.searchField }
        }
        await check("Find unfolds the search field from its icon") {
            await self.until { controller.findExpanded && controller.findItem.searchField.frame.width > 200 }
        }
        await check("Find from the folded field leaves its text clear of the magnifier") {
            let editor = controller.window?.firstResponder as? NSView
            return (editor?.frame.width ?? 0) > 150 && (editor?.frame.minX ?? 0) > 15
        }
        // Clearing the field (the clear button, deleting the text) keeps the cursor in it; Esc leaves it.
        let field = controller.findItem.searchField
        field.stringValue = "abc"
        (field.delegate as? NSSearchFieldDelegate)?.searchFieldDidEndSearching?(field)
        field.stringValue = ""
        (field.delegate as? NSSearchFieldDelegate)?.searchFieldDidEndSearching?(field)
        await check("clearing the search field keeps it open and focused") {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return controller.findExpanded && (controller.window?.firstResponder as? NSText)?.delegate === field
        }
        controller.findItem.searchField.stringValue = "last paragraph"
        controller.window?.makeFirstResponder(textView)
        await check("a search field with text stays out when it is left") {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return controller.findExpanded && controller.findItem.searchField.frame.width > 200
        }
        controller.findNext(nil)
        await check("Find selects the match in the text") {
            let selected: () -> String = { (self.previewText as NSString).substring(with: textView.selectedRange()) }
            let found = await self.until { selected() == "last paragraph" }
            if !found { print("    selection \(selected()), the text has it: \(self.previewText.contains("last paragraph"))") }
            return found
        }
        await snapshot("\(base)-find.png")
        // Empty and left, the field folds back into its icon.
        controller.findItem.searchField.stringValue = ""
        controller.window?.makeFirstResponder(controller.findItem.searchField)
        controller.window?.makeFirstResponder(textView)
        await check("an empty search field folds back into its icon when it is left") {
            await self.until { !controller.findExpanded && controller.findItem.searchField.frame.width < 60 }
        }
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
