import AppKit

/// The window's annotation UI: the cards in the comments pane (or the one card that opens next to
/// the text when the pane is closed), the Comment button over a selection, the form for a new
/// comment, the toast, and the keyboard shortcuts. The text itself is shown by a surface (the
/// preview or the source); it draws the highlights and tells this where each annotation is, what
/// is selected and what was clicked. Everything the reader does with an annotation happens here.
@MainActor
final class AnnotationController {
    private unowned let owner: EditorWindowController
    private let host: EditorScrollView
    private var store: AnnotationStore

    /// The surface that is showing: the preview or the source.
    private(set) var surface: AnnotationSurface
    let source: SourceEditorView
    let preview: PreviewView
    /// The pending annotations may have changed (the toolbar shows how many).
    var onPendingChange: (() -> Void)?

    // What the surface reported.
    private(set) var anchors: [String: AnchorRect] = [:]
    /// False until the surface has anchored the annotations of this file: nothing is "not found" before that.
    private(set) var anchorsKnown = false
    private(set) var selection: SelectionInfo?

    private(set) var focusedID: String?
    private(set) var cards: [String: AnnotationCardView] = [:]
    private let adder = CommentAdderView()
    private let toast = ToastView()
    private(set) var form: NewCommentView?
    private var formSelection: SelectionInfo?

    // The window owns the mode and whether the comments pane is open; this follows it (`refreshMode`).
    var mode: EditorMode { owner.mode }
    var commentsOn: Bool { owner.commentsOn }
    var sourceOn: Bool { mode == .source }

    private var cardWidth: CGFloat { AnnotationStyle.cardWidth }
    var paneShown: Bool { commentsOn }

    init(owner: EditorWindowController, host: EditorScrollView, store: AnnotationStore, source: SourceEditorView, preview: PreviewView) {
        self.owner = owner
        self.host = host
        self.store = store
        self.source = source
        self.preview = preview
        surface = preview
        host.floatingHost.addSubview(adder)
        adder.onClick = { [weak self] in self?.startForm() }
        host.onPaneLayout = { [weak self] in self?.layout() }
        listen(to: source)
        listen(to: preview)
        attach(store)
        refresh()
    }

    /// Takes a surface's reports, while it is the one showing: the preview keeps reporting from
    /// behind the source, and those reports are not about what is on screen.
    private func listen(to candidate: AnnotationSurface) {
        candidate.onAnchors = { [weak self, weak candidate] list in
            if let self, let candidate, candidate === surface { anchorsChanged(list) }
        }
        candidate.onSelection = { [weak self, weak candidate] selection in
            if let self, let candidate, candidate === surface { selectionChanged(selection) }
        }
        candidate.onFocus = { [weak self, weak candidate] id in
            if let self, let candidate, candidate === surface { focus(id) }
        }
        candidate.onPointer = { [weak self, weak candidate] in
            if let self, let candidate, candidate === surface { pointerDown() }
        }
    }

    // MARK: following the window

    /// The window showed the preview or the source, or opened or closed the pane.
    func refreshMode() {
        let showing: AnnotationSurface = sourceOn ? source : preview
        let modeChanged = showing !== surface
        if modeChanged {
            // What the other surface reported is not about what is on screen now.
            cancelForm()
            surface = showing
            anchors = [:]
            anchorsKnown = false
            selection = nil
            focusedID = nil
        }
        host.setPane(open: paneShown)
        if modeChanged {
            attach(store)
            // The preview re-reads the file and anchors on its own; the source anchors what it was given.
        }
        refresh()
    }

    /// Another file is on screen (a set's sidebar): nothing of the last one carries over.
    func fileChanged(store newStore: AnnotationStore) {
        store.onChange = nil
        cancelForm()
        for card in cards.values { card.removeFromSuperview() }
        cards = [:]
        anchors = [:]
        anchorsKnown = false
        selection = nil
        focusedID = nil
        toast.hide()
        attach(newStore)
        refresh()
    }

    private func attach(_ store: AnnotationStore) {
        self.store = store
        store.onChange = { [weak self] in self?.storeChanged() }
        store.onError = { [weak self] error in self?.fail(error) }
        // In the source an action is one step of the text view's history, with the typing.
        store.undoManagerSource = { [weak self] in
            guard let self, mode == .source else { return nil }
            return source.textView.undoManager
        }
        surface.annotationsChanged(store.pending)
    }

    // MARK: from the page

    private func anchorsChanged(_ list: [AnchorRect]) {
        let latest = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard latest != anchors || !anchorsKnown else { return }
        anchors = latest
        anchorsKnown = true
        refresh()
    }

    private func selectionChanged(_ latest: SelectionInfo?) {
        selection = latest
        updateAdder()
    }

    /// The annotation clicked in the text, or nil for a click on plain text.
    private func focus(_ id: String?) {
        guard id != focusedID else { return }
        focusedID = id
        refresh()
    }

    /// A click in the page, before the page acts on it: what is open over the text closes.
    private func pointerDown() {
        cancelForm()
        if !paneShown, focusedID != nil {
            focusedID = nil
            refresh()
        }
    }

    // MARK: layout

    /// The annotations themselves changed (an action here, or someone writing the sidecar): the
    /// surface learns of it (the source anchors them), and the cards follow.
    private func storeChanged() {
        surface.annotationsChanged(store.pending)
        refresh()
        onPendingChange?()
    }

    /// Something about the layout or the anchors changed: update the cards, then place everything.
    func refresh() {
        let pending = store.pending
        let ids = Set(pending.map(\.id))
        for (id, card) in cards where !ids.contains(id) {
            card.removeFromSuperview()
            cards[id] = nil
        }
        if let focusedID, !ids.contains(focusedID) { self.focusedID = nil }
        for annotation in pending {
            let card = cards[annotation.id] ?? makeCard(annotation)
            card.update(annotation)
            card.isFocused = annotation.id == focusedID
            card.isUnanchored = anchorsKnown && anchors[annotation.id] == nil
        }
        layout()
    }

    private func makeCard(_ annotation: Annotation) -> AnnotationCardView {
        let card = AnnotationCardView(annotation: annotation)
        card.handlers = AnnotationCardHandlers(
            focus: { [weak self] id in self?.focus(id) },
            accept: { [weak self] id in self?.accept(id) },
            resolve: { [weak self] id in self?.resolve(id) },
            saveEdit: { [weak self] id, text in self?.saveEdit(id, text) ?? false },
            reply: { [weak self] id, text in self?.reply(id, text) ?? false },
            relayout: { [weak self] in self?.layout() }
        )
        cards[annotation.id] = card
        return card
    }

    /// Places the pane or the open card, the form and the Comment button.
    func layout() {
        let pending = store.pending
        if paneShown || host.paneWidth > 0 {
            var items: [AnnotationGutterView.Item] = []
            for annotation in pending {
                guard let card = cards[annotation.id] else { continue }
                card.isFloating = false
                card.layoutContent(width: cardWidth)
                let anchor = anchors[annotation.id]
                // Not found in the document: parked after the text.
                items.append(.init(view: card, anchorTop: anchor?.top ?? host.contentHeight, order: anchor?.from ?? Int.max))
            }
            if let form, let formSelection, paneShown {
                form.isFloating = false
                form.layoutContent(width: cardWidth)
                items.append(.init(view: form, anchorTop: formSelection.top, order: formSelection.from))
            }
            let extent = host.gutter.stack(items)
            host.setGutterExtent(extent > 0 ? extent + 48 : 0)
        } else {
            host.setGutterExtent(0)
            _ = host.gutter.stack([])
            for card in cards.values where card.annotation.id != focusedID { card.removeFromSuperview() }
            placeOpenCard()
            placeFloatingForm()
        }
        updateAdder()
    }

    /// The card of the annotation clicked in the text, next to it; flips above near the bottom.
    private func placeOpenCard() {
        guard let id = focusedID, let card = cards[id], let anchor = anchors[id] else { return }
        card.isFloating = true
        let height = card.layoutContent(width: cardWidth)
        if card.superview !== host.floatingHost { host.floatingHost.addSubview(card) }
        card.frame.origin = floatingOrigin(width: cardWidth, height: height, left: anchor.left, top: anchor.top, bottom: anchor.bottom)
    }

    private func placeFloatingForm() {
        guard let form, let formSelection else { return }
        form.isFloating = true
        let height = form.layoutContent(width: cardWidth)
        if form.superview !== host.floatingHost { host.floatingHost.addSubview(form) }
        form.frame.origin = floatingOrigin(width: cardWidth, height: height, left: formSelection.left,
                                           top: formSelection.top, bottom: formSelection.endBottom)
    }

    /// Below `bottom`, or above `top` when it will not fit below but will fit above, and kept inside the text column.
    private func floatingOrigin(width: CGFloat, height: CGFloat, left: Double, top: Double, bottom: Double) -> NSPoint {
        let visible = host.visibleDocumentRect
        let fitsBelow = visible.maxY - CGFloat(bottom) >= height + 12
        let fitsAbove = CGFloat(top) - visible.minY > height + 12
        var y = !fitsBelow && fitsAbove ? CGFloat(top) - height - 6 : CGFloat(bottom) + 6
        // Fits neither way (the text is at the bottom of the window): kept inside what is visible.
        y = min(y, visible.maxY - height - 8)
        y = max(y, visible.minY + 8)
        let maxX = max(8, host.textWidth - width - 8)
        return NSPoint(x: min(max(8, CGFloat(left)), maxX), y: y)
    }

    // MARK: the Comment button and the form

    private func updateAdder() {
        guard let selection, form == nil, surface.hasKeyboardFocus || adder.isHidden == false else {
            adder.isHidden = true
            return
        }
        // Above the first line, centred; below it when there is no room above, near the top of the window.
        let visible = host.visibleDocumentRect
        let width = adder.frame.width, height = adder.frame.height
        let centre = CGFloat(selection.left + selection.right) / 2
        let above = CGFloat(selection.top) - 8 - height
        let y = above < visible.minY + 8 ? CGFloat(selection.bottom) + 8 : above
        let x = min(max(8, centre - width / 2), max(8, host.textWidth - width - 8))
        adder.frame.origin = NSPoint(x: x, y: y)
        if adder.superview !== host.floatingHost { host.floatingHost.addSubview(adder) }
        adder.isHidden = false
    }

    /// The Comment button was pressed: open the form for the selected text.
    func startForm() {
        guard let selection, form == nil else { return }
        let view = NewCommentView()
        view.onSend = { [weak self] text in self?.submitForm(text) }
        view.onCancel = { [weak self] in self?.cancelForm(refocusPage: true) }
        view.onResize = { [weak self] in self?.layout() }
        form = view
        formSelection = selection
        adder.isHidden = true
        // Keep the text being commented on highlighted while the form is open.
        surface.setPending((selection.from, selection.to))
        layout()
        owner.window?.makeFirstResponder(view.field.textView)
    }

    private func submitForm(_ text: String) {
        guard let selection = formSelection else { return }
        do {
            try store.addComment(contextBefore: selection.contextBefore, target: selection.target, comment: text)
        } catch {
            fail(error)
            return
        }
        cancelForm(refocusPage: true)
    }

    func cancelForm(refocusPage: Bool = false) {
        guard let form else { return }
        form.removeFromSuperview()
        self.form = nil
        formSelection = nil
        surface.setPending(nil)
        if refocusPage { surface.focusText() }
        layout()
    }

    // MARK: what the buttons do

    private func accept(_ id: String) {
        guard let annotation = store.annotation(id) else { return }
        if annotation.kind == .replace || annotation.kind == .insert, let text = annotation.replacement {
            // The text changes only once the reloaded document arrives; the surface waits for it to flash.
            surface.flashAfterReload(text)
        }
        showToast("Accepted \(annotation.kind.name)")
        Task { @MainActor in
            // Pending edits are saved first, so accepting patches the text as it is on screen.
            await surface.flush()
            do { try store.accept(id) } catch { fail(error) }
        }
    }

    private func resolve(_ id: String) {
        guard let annotation = store.annotation(id) else { return }
        do {
            let entry = try store.resolve(id)
            showToast(annotation.isComment ? "Comment dismissed" : "Rejected \(annotation.kind.name)") { [weak self] in
                self?.store.revert(entry)
            }
        } catch {
            fail(error)
        }
    }

    private func saveEdit(_ id: String, _ text: String) -> Bool {
        do { try store.editComment(id, to: text); return true } catch { fail(error); return false }
    }

    private func reply(_ id: String, _ text: String) -> Bool {
        do { try store.reply(to: id, body: text); return true } catch { fail(error); return false }
    }

    private func showToast(_ message: String, undo: (() -> Void)? = nil) {
        toast.show(message, undo: undo, in: host, centerX: host.textWidth / 2, bottom: 24)
    }

    var toastMessage: String? { toast.isHidden ? nil : toast.message }

    // What the self-test looks at and presses.
    var adderIsHidden: Bool { adder.isHidden }
    var adderFrame: NSRect? { adder.isHidden ? nil : adder.frame }
    func pressCommentButton() { adder.onClick?() }

    private func fail(_ error: Error) {
        guard let window = owner.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }

    // MARK: keyboard

    /// ⌃J and ⌃K move between annotations, ⌃↩ accepts the one in focus, ⌃⌫ rejects it, Esc closes
    /// what is open over the text, and in the preview ⌘Z goes to the annotation actions while one
    /// of them is the latest thing the reader did.
    func handleKey(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }
        let flags = event.modifierFlags.intersection([.control, .command, .option, .shift])
        if flags == [.control] {
            // In a reply or comment field ⌃↩ posts the text; it is not the accept shortcut.
            if event.keyCode == 36, owner.window?.firstResponder is GrowingTextView { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "j": return navigate(1)
            case "k": return navigate(-1)
            case "\r": return act(on: focusedID) { accept($0) }
            case "\u{7f}": return act(on: focusedID) { resolve($0) }
            default: return false
            }
        }
        // ⌘Z and ⇧⌘Z are ours in the preview and the source text; a reply field keeps its own.
        if event.charactersIgnoringModifiers?.lowercased() == "z" {
            let responder = owner.window?.firstResponder
            if flags == [.command] { return undo(from: responder) }
            if flags == [.command, .shift] { return redo(from: responder) }
        }
        if flags.isEmpty, event.keyCode == 53 {
            if form != nil { cancelForm(refocusPage: true); return true }
            if !paneShown, focusedID != nil { focusedID = nil; refresh(); return true }
        }
        return false
    }

    private func act(on id: String?, _ action: (String) -> Void) -> Bool {
        guard let id, store.annotation(id)?.resolved == false else { return false }
        action(id)
        return true
    }

    /// Focuses the next (or previous) annotation in document order, wrapping round.
    @discardableResult
    func navigate(_ direction: Int) -> Bool {
        let ordered = store.pending.compactMap { annotation in anchors[annotation.id].map { (annotation, $0) } }
            .sorted { $0.1.from < $1.1.from }
        guard !ordered.isEmpty else { return false }
        let current = ordered.firstIndex { $0.0.id == focusedID }
        let next = current.map { (($0 + direction) % ordered.count + ordered.count) % ordered.count }
            ?? (direction > 0 ? 0 : ordered.count - 1)
        return reveal(annotation: ordered[next].0.id)
    }

    /// Focuses an annotation and brings it into view. False when it is not pending or not placed in the text yet.
    @discardableResult
    func reveal(annotation id: String) -> Bool {
        guard store.pending.contains(where: { $0.id == id }), let anchor = anchors[id] else { return false }
        focusedID = id
        refresh()
        surface.select(annotation: id)
        host.reveal(top: CGFloat(anchor.top), bottom: CGFloat(anchor.bottom))
        // The open card sits below its text: bring it into view too.
        if let card = cards[id], card.isFloating { host.reveal(top: card.frame.minY, bottom: card.frame.maxY) }
        return true
    }

    // MARK: Undo

    // The preview is read-only, so its Undo is the annotation actions' own history; in the source it is
    // one history: the text view's, with the annotation actions in it in order.

    // The one place that decides Undo and Redo, for ⌘Z (`handleKey`) and Edit ▸ Undo (`AppDelegate`),
    // from where the keyboard is: in the source text, the text view's history; in the preview, the
    // annotation actions. Anywhere else (a reply field, the sidebar) it is not ours.
    private enum UndoScope { case source, preview }

    private func undoScope(of responder: NSResponder?) -> UndoScope? {
        guard let view = responder as? NSView else { return nil }
        if sourceOn { return view === source.textView ? .source : nil }
        return view.isDescendant(of: preview) ? .preview : nil
    }

    /// Undoes in the source or the last annotation action. Returns false when Undo belongs to the responder.
    func undo(from responder: NSResponder?) -> Bool {
        switch undoScope(of: responder) {
        case .source:
            guard source.canUndo else { return false }
            source.undo()
            return true
        case .preview: return store.canUndo && store.undo()
        case nil: return false
        }
    }

    func redo(from responder: NSResponder?) -> Bool {
        switch undoScope(of: responder) {
        case .source:
            guard source.canRedo else { return false }
            source.redo()
            return true
        case .preview: return store.canRedo && store.redo()
        case nil: return false
        }
    }

    /// Whether Edit ▸ Undo is available, or nil when the responder decides.
    func canUndo(from responder: NSResponder?) -> Bool? {
        switch undoScope(of: responder) {
        case .source: return source.canUndo
        case .preview: return store.canUndo
        case nil: return nil
        }
    }

    func canRedo(from responder: NSResponder?) -> Bool? {
        switch undoScope(of: responder) {
        case .source: return source.canRedo
        case .preview: return store.canRedo
        case nil: return nil
        }
    }
}
