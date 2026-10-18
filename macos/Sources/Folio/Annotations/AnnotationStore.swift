import Foundation

/// The annotations of one document as the window shows them, and what the reader can do to
/// them. Every action is applied by libfolio (`Rust.edit`) to the sidecar as it is on disk, so
/// annotations an agent added a moment ago are not lost; this keeps no copy it writes back.
@MainActor
final class AnnotationStore {
    /// An action that can be undone: the annotation as it was and as it became (nil: it did not
    /// exist before, or does not now).
    struct Entry: Equatable {
        let id: String
        let before: Annotation?
        let after: Annotation?
    }

    let document: Document
    private(set) var annotations: [Annotation] = []
    /// The annotations still waiting for the reader.
    var pending: [Annotation] { annotations.filter { !$0.resolved } }

    /// The annotations changed: by an action here, or by someone else writing the sidecar.
    var onChange: (() -> Void)?

    /// Undo and redo of the actions below. The editor's own undo is the page's; the web view
    /// offers this one while an action here is the latest thing the reader did.
    let undoManager = UndoManager()
    private(set) var lastEntry: Entry?
    /// When the last action, undo or redo happened, so Undo can tell it from a text edit.
    private(set) var lastActionAt = Date.distantPast

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init(document: Document) {
        self.document = document
        undoManager.groupsByEvent = false
        annotations = Self.read(document)
    }

    func annotation(_ id: String) -> Annotation? {
        annotations.first { $0.id == id }
    }

    // MARK: following the file

    /// Reads the sidecar again. A change that did not come from here (an agent wrote it) makes
    /// the undo history stale, so it is dropped. Returns whether anything changed.
    @discardableResult
    func reload() -> Bool {
        let latest = Self.read(document)
        guard latest != annotations else { return false }
        annotations = latest
        undoManager.removeAllActions()
        lastEntry = nil
        onChange?()
        return true
    }

    private static func read(_ document: Document) -> [Annotation] {
        (try? document.readSidecar()).flatMap { try? Sidecar.parse($0) }?.annotations ?? []
    }

    // MARK: actions

    /// Rejects a suggestion or dismisses a comment: it stays in the file, resolved.
    @discardableResult
    func resolve(_ id: String) throws -> Entry {
        let before = annotation(id)
        try perform(["op": "resolve", "id": id])
        return record(id: id, before: before)
    }

    @discardableResult
    func addComment(contextBefore: String, target: String, comment: String) throws -> Entry {
        let id = try perform([
            "op": "add_comment", "context_before": contextBefore, "target": target,
            "comment": comment, "author": "me", "source": "local",
        ])
        return record(id: id ?? "", before: nil)
    }

    @discardableResult
    func reply(to id: String, body: String) throws -> Entry {
        let before = annotation(id)
        try perform(["op": "reply", "id": id, "body": body, "author": "me", "source": "local"])
        return record(id: id, before: before)
    }

    @discardableResult
    func editComment(_ id: String, to comment: String) throws -> Entry {
        let before = annotation(id)
        try perform(["op": "edit_comment", "id": id, "comment": comment])
        return record(id: id, before: before)
    }

    /// Applies the annotation to the markdown, like `folio accept`. The document tells the page.
    func accept(_ id: String) throws {
        try document.accept(id: id)
        reload()
    }

    // MARK: undo

    /// Undoes the last action. `entry` guards against undoing something newer than the action
    /// the caller means (a toast's Undo button).
    @discardableResult
    func undo(_ entry: Entry? = nil) -> Bool {
        if let entry, entry != lastEntry { return false }
        guard undoManager.canUndo else { return false }
        undoManager.undo()
        lastActionAt = Date()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard undoManager.canRedo else { return false }
        undoManager.redo()
        lastActionAt = Date()
        return true
    }

    // MARK: private

    @discardableResult
    private func perform(_ edit: [String: Any]) throws -> String? {
        let result = try Rust.edit(sidecarJSON: document.readSidecar(), edit: edit)
        try document.writeSidecar(result.sidecar)
        annotations = try Sidecar.parse(result.sidecar).annotations
        // The page reads the sidecar for its highlights; our own write is not reported back by the poller.
        document.onEvent?("folio:changed")
        onChange?()
        return result.id
    }

    private func record(id: String, before: Annotation?) -> Entry {
        let entry = Entry(id: id, before: before, after: annotation(id))
        // One group per action: they are not grouped by run-loop turn, so two quick actions stay two steps.
        undoManager.beginUndoGrouping()
        register(entry, undoing: true)
        undoManager.endUndoGrouping()
        lastEntry = entry
        lastActionAt = Date()
        return entry
    }

    /// Registers the way back from `entry`: undoing puts the annotation as it was, and what
    /// the undo registers in turn is the redo.
    private func register(_ entry: Entry, undoing: Bool) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.step(entry, undoing: undoing) }
        }
    }

    private func step(_ entry: Entry, undoing: Bool) {
        let target = undoing ? entry.before : entry.after
        do {
            if let target {
                try perform(["op": "restore", "annotation": try target.sidecarObject()])
            } else {
                try perform(["op": "remove", "id": entry.id])
            }
        } catch {
            return
        }
        register(entry, undoing: !undoing)
        lastEntry = entry
    }
}
