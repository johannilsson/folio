import AppKit
import WebKit

/// The source editor: its annotation UI, saving, outside changes and formatting.
extension SelfTest {
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
