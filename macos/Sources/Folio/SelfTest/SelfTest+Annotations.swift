import AppKit
import WebKit

/// The preview's annotation UI, the annotation store and Undo across the two modes.
extension SelfTest {
    /// The preview's own annotation UI: the pane, the card that opens next to the text, the Comment
    /// button and form, shortcuts, and Edit ▸ Undo. The preview is showing, with the pane open.
    func nativeAnnotationChecks() async {
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
        var lostSuggestion = commentJSON("lost-replace", before: "no such text anywhere ", target: "nowhere")
        lostSuggestion["kind"] = "replace"
        lostSuggestion["replacement"] = "somewhere"
        replaceSidecar([commentJSON("lost", before: "no such text anywhere ", target: "nowhere"), lostSuggestion])
        await check("Accept is disabled on a suggestion that is not in the document, Resolve is not on a comment") {
            await self.until(seconds: 8) {
                guard let suggestion = self.pane.cards["lost-replace"], let comment = self.pane.cards["lost"] else { return false }
                return suggestion.isUnanchored && comment.isUnanchored
                    && (self.button("accept", in: suggestion) as? NSControl)?.isEnabled == false
                    && (self.button("accept", in: comment) as? NSControl)?.isEnabled == true
            }
        }
        replaceSidecar([commentJSON("edit", before:"Natural wine is made with ", target: "no additives")])
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

        // A link in a card's text opens in the browser; the rest of the card still focuses it.
        var linked = commentJSON("links", before: "Natural wine is made with ", target: "no additives")
        linked["comment"] = "[the docs](https://example.com/docs) and more"
        replaceSidecar([linked])
        _ = await until(seconds: 8) { self.pane.cards["links"] != nil && self.pane.anchors["links"] != nil }
        var opened: [URL] = []
        AnnotationCardView.openLink = { opened.append($0) }
        defer { AnnotationCardView.openLink = { NSWorkspace.shared.open($0) } }
        func mouseDown(on card: AnnotationCardView, label: NSView) {
            let point = label.convert(NSPoint(x: 3, y: label.bounds.height - 3), to: nil)
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: card.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            card.mouseDown(with: down)
        }
        await check("clicking a link in a card opens it and does not focus the annotation") {
            guard let card = self.pane.cards["links"],
                  let label = card.subviews.compactMap({ $0 as? PassthroughLabel }).first(where: { $0.stringValue.contains("the docs") })
            else { print("    no card or body label"); return false }
            let before = self.pane.focusedID
            mouseDown(on: card, label: label)
            let opensLink = opened == [URL(string: "https://example.com/docs")!] && self.pane.focusedID == before
            self.click(card)
            let ok = opensLink && opened.count == 1 && self.pane.focusedID == "links"
            if !ok { print("    opened \(opened), focused \(self.pane.focusedID ?? "nil") (before \(before ?? "nil")), label \(label.frame) in card \(card.frame)") }
            return ok
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

    /// Annotation actions in the preview and the source are in different histories: Undo after a
    /// switch must not reach back past what was done in the other mode. Starts and ends in the preview.
    func undoAcrossModesChecks() async {
        replaceSidecar([commentJSON("modes", before: "Natural wine is made with ", target: "no additives")])
        let store = controller.currentStore
        _ = await until(seconds: 8) { store.annotation("modes") != nil }
        _ = try? store.reply(to: "modes", body: "Replied in the preview")
        send("toggleSource:")
        _ = await until { self.controller.sourceOn && !self.sourceView.isHidden }
        controller.window?.makeFirstResponder(sourceView.textView)
        func menuItemEnabled(_ title: String) -> Bool {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let edit = NSApp.mainMenu?.items.compactMap({ $0.submenu }).first(where: { $0.title == "Edit" }),
                  let item = edit.item(withTitle: title) else { return true }
            return delegate.validateMenuItem(item)
        }
        await check("Edit ▸ Undo and Redo are greyed out in the source when there is nothing to undo or redo") {
            !menuItemEnabled("Undo") && !menuItemEnabled("Redo")
        }
        _ = try? store.reply(to: "modes", body: "Replied in the source")
        await check("Edit ▸ Undo is available in the source after an annotation action, Redo after the Undo") {
            guard menuItemEnabled("Undo"), !menuItemEnabled("Redo") else { return false }
            self.sourceView.undo()
            return menuItemEnabled("Redo")
        }
        sourceView.redo()
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn }
        await check("⌘Z in the preview after a switch leaves what was done in the source") {
            _ = self.pane.handleKey(self.keyEvent("z", .command, code: 6))
            let bodies = store.annotation("modes")?.replies?.map { $0.body }
            return bodies == ["Replied in the preview", "Replied in the source"]
        }

        await check("an annotation of a kind this app does not know still loads") {
            var item = self.commentJSON("odd", before: "a", target: "b")
            item["kind"] = "mystery"
            guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "annotations": [item]]),
                  let parsed = try? Sidecar.parse(String(decoding: data, as: UTF8.self)) else { return false }
            return parsed.annotations.first?.kind == .unknown("mystery")
        }

        // An Undo that cannot write the sidecar tells the reader.
        _ = try? store.resolve("modes")
        let folder = controller.files.sidecar.deletingLastPathComponent()
        try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        store.undo()
        await check("an Undo that fails is shown") {
            await self.until(seconds: 3) { self.controller.window?.attachedSheet != nil } && store.annotation("modes")?.resolved == true
        }
        if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        replaceSidecar([])
        _ = await until { store.annotations.isEmpty }
    }

    /// The Comment button over a selection, and the form it opens, with the pane open and closed.
    func commentFormChecks(inSource: Bool = false) async {
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
    func storeChecks() async {
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
}
