import Foundation

/// The annotations of one document as the window shows them, and what the reader can do to
/// them. Every action is applied by libfolio (`Rust.edit`) to the sidecar as it is on disk, so
/// annotations an agent added a moment ago are not lost; this keeps no copy it writes back.
@MainActor
final class AnnotationStore {
    /// An action that can be undone: the annotation as it was and as it became (nil: it did not
    /// exist before, or does not now).
    struct Entry {
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

    private(set) var undoStack: [Entry] = []
    private(set) var redoStack: [Entry] = []
    /// When the last action, undo or redo happened, so Undo can tell it from a text edit.
    private(set) var lastActionAt = Date.distantPast

    init(document: Document) {
        self.document = document
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
        undoStack = []
        redoStack = []
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

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Undoes `entry`, or the last action.
    @discardableResult
    func undo(_ entry: Entry? = nil) -> Bool {
        guard let entry = entry ?? undoStack.last else { return false }
        undoStack.removeAll { $0.id == entry.id && $0.after == entry.after }
        do {
            if let before = entry.before {
                try perform(["op": "restore", "annotation": try before.sidecarObject()])
            } else {
                try perform(["op": "remove", "id": entry.id])
            }
        } catch {
            return false
        }
        redoStack.append(entry)
        lastActionAt = Date()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let entry = redoStack.popLast(), let after = entry.after else { return false }
        do {
            try perform(["op": "restore", "annotation": try after.sidecarObject()])
        } catch {
            return false
        }
        undoStack.append(entry)
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
        undoStack.append(entry)
        redoStack = []
        lastActionAt = Date()
        return entry
    }
}
