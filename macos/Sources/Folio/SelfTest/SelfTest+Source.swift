import AppKit

/// The source editor: its annotation UI, saving, outside changes and formatting.
extension SelfTest {
    /// Opening the source from the menu, typing, Undo, copy and paste, the CLI's annotations in the
    /// source, accepting there, and the preview picking up what was done. Starts in the preview and ends in it.
    func sourceEditingChecks() async {
        replaceSidecar([])
        replaceFile(fixture)
        _ = await until { self.previewText.contains("The last paragraph.") && self.controller.currentStore.annotations.isEmpty }
        if controller.commentsOn {
            send("toggleComments:")
            _ = await until { !self.controller.commentsOn && self.controller.scrollHost.paneWidth == 0 }
        }

        // The View menu switches to the source editor.
        send("toggleSource:")
        await check("the source editor opens from the menu and the toolbar follows") {
            let shown = await self.until { self.controller.sourceOn && !self.sourceView.isHidden && self.sourceView.window != nil && self.previewView.isHidden }
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
            // Samples until the pane has settled (or 2 s), so a slow runner delays the samples instead of missing the animation.
            @MainActor func sampleWidths(until settled: @escaping (Double) -> Bool) async -> [Double] {
                var widths: [Double] = []
                let deadline = Date().addingTimeInterval(2)
                while Date() < deadline {
                    widths.append(Double(self.controller.scrollHost.paneWidth))
                    if settled(widths.last!) { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return widths
            }
            self.send("toggleComments:")
            let closing = await sampleWidths { $0 < 5 }
            self.send("toggleComments:")
            let opening = await sampleWidths { $0 > 300 }
            let between = { (w: [Double]) in w.contains { $0 > 15 && $0 < 290 } }
            let ok = between(closing) && between(opening) && (closing.last ?? 999) < 5 && (opening.last ?? 0) > 300
            if !ok { print("pane widths closing \(closing), opening \(opening)") }
            return ok
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

        // Back in the preview, which picks up what was typed and accepted in the source.
        send("toggleSource:")
        await check("the toolbar follows the source toggle") { await self.until { !self.controller.sourceOn } }
        await check("the preview picked up what was typed and accepted in the source") {
            await self.until { self.previewText.contains("made with no additives in both") }
        }

        // Accept in the preview is the app's own card (Rust anchors and patches).
        let secondCLI = cli([
            "annotate", name, "--kind", "replace",
            "--context-before", "in both the vineyard and the ", "--target", "cellar",
            "--replacement", "cave", "--author", "agent", "--source", "agent",
        ])
        await check("second annotation added from the CLI") { secondCLI.status == 0 }
        await check("it appears in the comments pane of the preview, on screen") {
            await self.until(seconds: 8) { self.visibleCards().count == 1 && self.pane.anchors.count == 1 }
        }
        press("accept", inCardOf: pane.cards.keys.first)
        await check("accepting patches the file") {
            await self.until { self.disk().contains("vineyard and the cave.") }
        }
        await check("accepting shows a toast") { self.pane.toastMessage == "Accepted replace" }
        await check("the preview reloads the patched text") {
            await self.until { self.previewText.contains("vineyard and the cave.") }
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
        replaceFile(disk() + "\nAdded by another program.\n")
        await check("an atomic replace from outside reloads the preview") {
            await self.until(seconds: 8) { self.previewText.contains("Added by another program.") }
        }
        replaceSidecar([])
    }

    /// The annotation UI in the source: the marks on the text, ranges that follow the text as it is
    /// edited, clicks, ⌃J/⌃K, the Comment button and form, Undo in order, and the file changing underneath.
    func sourceAnnotationChecks() async {
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
            guard let annotation = self.controller.currentStore.pending.first(where: { $0.kind == AnnotationKind(name: kind) }) else { return nil }
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
        await check("the suggested text of a replacement and an insertion is shown at its place") {
            guard let replace = range(of: "replace"), let insert = range(of: "insert") else { return false }
            let shown = textView.suggestions.map { "\($0.at):\($0.text)" }
            return shown.contains("\(replace.upperBound):vineyard") && shown.contains("\(insert.location): (end)")
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-source-suggestions.png") }
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
        let commentID = controller.currentStore.pending.first { $0.kind == .comment }?.id ?? ""
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
        let toDismiss = controller.currentStore.pending.first { $0.kind == .comment && $0.author == "agent" }?.id ?? ""
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
        // A change to the file while typing waits to be saved: the reader is asked which to keep.
        textView.insertText("LOCAL", replacementRange: NSRange(location: 0, length: 0))
        replaceFile("# Replaced while typing\n")
        await check("a change to the file while typing waits to be saved asks which to keep, and overwrites neither") {
            await self.until(seconds: 3) { self.controller.window?.attachedSheet != nil }
                && self.disk() == "# Replaced while typing\n" && self.sourceText.hasPrefix("LOCAL")
        }
        await check("Keep Mine writes the typing over the change") {
            self.pressSheetButton("Keep Mine")
            return await self.until { self.disk().hasPrefix("LOCAL") && self.sourceText.hasPrefix("LOCAL") }
        }
        textView.insertText("MINE", replacementRange: NSRange(location: 0, length: 0))
        replaceFile("# Replaced again\n")
        _ = await until(seconds: 3) { self.controller.window?.attachedSheet != nil }
        await check("Use the File drops the typing and shows the file") {
            self.pressSheetButton("Use the File")
            return await self.until { self.sourceText == "# Replaced again\n" && self.disk() == "# Replaced again\n" }
                && !self.sourceView.hasUnsavedEdits
        }
        replaceFile(sourceText)

        await check("the line numbers count the lines of the file") {
            let newlines = self.sourceText.filter { $0 == "\n" }.count
            return self.sourceView.lineStartsForTest.count == newlines + 1
        }

        // A comment made on marked-up text is anchored by the rendered words, as agents and the preview do.
        _ = await until(seconds: 5) { !self.sourceView.hasUnsavedEdits }
        let plain = disk()
        replaceFile("# Heading\n\nThe 🎉 **target** sentence here.\n")
        _ = await until(seconds: 8) { self.sourceText.contains("**target**") }
        let marked = (sourceText as NSString).range(of: "**target**")
        textView.setSelectedRange(marked)
        await check("a selection of marked-up text is reported as rendered words, without the syntax") {
            await self.until(seconds: 5) { self.pane.selection?.target == "target" }
                && self.pane.selection?.contextBefore == "HeadingThe 🎉 "
        }
        await check("an annotation written with those words is found in the source, on the same text") {
            guard let selection = self.pane.selection else { return false }
            self.replaceSidecar([self.commentJSON("md1", before: selection.contextBefore, target: selection.target)])
            return await self.until(seconds: 8) {
                guard let range = self.sourceView.ranges["md1"] else { return false }
                return (self.sourceText as NSString).substring(with: range) == "target"
            }
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        replaceSidecar([])
        replaceFile(plain)
        _ = await until(seconds: 8) { self.sourceText == plain }

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
        await check("the next save asks about the change, and Keep Mine writes the typing") {
            guard !self.sourceView.flushSave(), self.controller.window?.attachedSheet != nil else { return false }
            self.pressSheetButton("Keep Mine")
            return await self.until { self.disk().hasPrefix("UNWRITTEN") }
        }
        replaceFile(saved)

        replaceSidecar([])
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn }
    }

    /// ⌘B and ⌘I in the source: wrap the selection in the marks, unwrap it when it is wrapped, and with
    /// nothing selected put a pair down with the caret between. Leaves the text as it found it.
    func sourceFormattingChecks() async {
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
}
