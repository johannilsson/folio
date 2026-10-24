import Foundation

/// The annotations of one document as the window shows them, and what the reader can do to
/// them. Every action is applied by libfolio (`Rust.edit`) to the sidecar as it is on disk, so
/// annotations an agent added a moment ago are not lost; this keeps no copy it writes back.
@MainActor
final class AnnotationStore {
    /// An action that can be undone: the annotation as it was and as it became (nil: it did not
    /// exist before, or does not now), as the sidecar JSON that libfolio wrote, so undoing
    /// puts back exactly that and not what this app's model made of it.
    struct Entry: Equatable {
        let id: String
        let before: [String: Any]?
        let after: [String: Any]?

        static func == (a: Entry, b: Entry) -> Bool {
            a.id == b.id && (a.before as NSDictionary?) == (b.before as NSDictionary?) && (a.after as NSDictionary?) == (b.after as NSDictionary?)
        }
    }

    let document: Document
    private(set) var annotations: [Annotation] = []
    /// The annotations still waiting for the reader.
    var pending: [Annotation] { annotations.filter { !$0.resolved } }

    /// The annotations changed: by an action here, or by someone else writing the sidecar.
    var onChange: (() -> Void)?
    /// An undo or redo failed: nothing else can tell the reader, as no action of theirs is waiting for an answer.
    var onError: ((Error) -> Void)?

    /// Undo and redo of the actions below. The preview is read-only, so these have a history of their
    /// own there. In the source it is the text view's history, so Undo goes back through typing and
    /// these actions in order.
    var undoManagerSource: () -> UndoManager? = { nil }
    private let ownManager = UndoManager()
    var undoManager: UndoManager { undoManagerSource() ?? ownManager }
    private(set) var lastEntry: Entry?

    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init(document: Document) {
        self.document = document
        ownManager.groupsByEvent = false
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
        forgetHistory()
        onChange?()
        return true
    }

    /// Drops the actions of this store from both histories, its own and the text view's, which
    /// keeps the typing. Done when the sidecar changed underneath, and on a switch between the
    /// preview and the source: an action kept in the other history would undo past newer ones.
    func forgetHistory() {
        ownManager.removeAllActions(withTarget: self)
        undoManagerSource()?.removeAllActions(withTarget: self)
        lastEntry = nil
    }

    private static func read(_ document: Document) -> [Annotation] {
        (try? document.readSidecar()).flatMap { try? Sidecar.parse($0) }?.annotations ?? []
    }

    // MARK: actions

    /// Rejects a suggestion or dismisses a comment: it stays in the file, resolved.
    @discardableResult
    func resolve(_ id: String) throws -> Entry {
        let before = rawAnnotation(id)
        try perform(["op": "resolve", "id": id])
        return record(id: id, before: before)
    }

    @discardableResult
    func addComment(contextBefore: String, target: String, comment: String) throws -> Entry {
        let id = try perform([
            "op": "add_comment", "context_before": contextBefore, "target": target,
            "comment": comment, "author": "me", "source": "local",
        ])
        guard let id else { throw RustError(description: "the comment was added, but the library returned no id for it") }
        return record(id: id, before: nil)
    }

    @discardableResult
    func reply(to id: String, body: String) throws -> Entry {
        let before = rawAnnotation(id)
        try perform(["op": "reply", "id": id, "body": body, "author": "me", "source": "local"])
        return record(id: id, before: before)
    }

    @discardableResult
    func editComment(_ id: String, to comment: String) throws -> Entry {
        let before = rawAnnotation(id)
        try perform(["op": "edit_comment", "id": id, "comment": comment])
        return record(id: id, before: before)
    }

    /// Applies the annotation to the markdown, like `folio accept`.
    func accept(_ id: String) throws {
        try document.accept(id: id)
        reload()
    }

    // MARK: undo

    /// Takes back `entry` directly, whatever came after it (a toast's Undo button). The history of
    /// these actions is dropped with it: what it holds would no longer match.
    func revert(_ entry: Entry) {
        do {
            if let before = entry.before {
                try perform(["op": "restore", "annotation": before])
            } else {
                try perform(["op": "remove", "id": entry.id])
            }
        } catch {
            onError?(error)
            return
        }
        forgetHistory()
    }

    /// Undoes the last action. `entry` guards against undoing something newer than the action
    /// the caller means.
    @discardableResult
    func undo(_ entry: Entry? = nil) -> Bool {
        if let entry, entry != lastEntry { return false }
        guard undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard undoManager.canRedo else { return false }
        undoManager.redo()
        return true
    }

    // MARK: private

    /// The sidecar text libfolio wrote last, which `record` takes the new annotation from.
    private var lastSidecar = ""

    /// The annotation `id` as the sidecar on disk has it.
    private func rawAnnotation(_ id: String) -> [String: Any]? {
        Self.rawAnnotation(id, in: (try? document.readSidecar()) ?? "")
    }

    private static func rawAnnotation(_ id: String, in sidecar: String) -> [String: Any]? {
        let object = try? JSONSerialization.jsonObject(with: Data(sidecar.utf8)) as? [String: Any]
        return (object?["annotations"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    @discardableResult
    private func perform(_ edit: [String: Any]) throws -> String? {
        let result = try Rust.edit(sidecarJSON: document.readSidecar(), edit: edit)
        try document.writeSidecar(result.sidecar)
        lastSidecar = result.sidecar
        annotations = try Sidecar.parse(result.sidecar).annotations
        // The page reads the sidecar for its highlights; our own write is not reported back by the poller.
        document.onEvent?("folio:changed")
        onChange?()
        return result.id
    }

    private func record(id: String, before: [String: Any]?) -> Entry {
        let entry = Entry(id: id, before: before, after: Self.rawAnnotation(id, in: lastSidecar))
        // Our own manager does not group by run-loop turn, so each action is its own group there;
        // the text view's does, as typing needs it.
        let manager = undoManager
        let grouped = !manager.groupsByEvent
        if grouped { manager.beginUndoGrouping() }
        register(entry, undoing: true)
        if grouped { manager.endUndoGrouping() }
        lastEntry = entry
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
                try perform(["op": "restore", "annotation": target])
            } else {
                try perform(["op": "remove", "id": entry.id])
            }
        } catch {
            onError?(error)
            return
        }
        register(entry, undoing: !undoing)
        lastEntry = entry
    }
}
