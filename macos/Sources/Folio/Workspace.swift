import FolioKit
import Foundation

/// The files one window works on: a single document, or the files of a set. It resolves
/// file ids and relays each file's change events; for a set it
/// also reads the set again twice a second, so `folio set add` in a terminal, files added, renamed
/// or removed under a folder, and a `git checkout` in a worktree all show up in the window.
final class Workspace {
    struct Entry {
        let document: Document
        /// Path relative to the root, as the sidebar shows it.
        let name: String
        /// The repo's name; a set groups its files by it. For a file in one of the set's folders,
        /// that folder's name.
        let group: String
        /// In one of the set's folders, rather than added on its own.
        var inFolder = false
        /// The checkout the file is in (where its sidecar lives), and what that has checked out.
        var root = URL(fileURLWithPath: "/")
        var branch: String?
        var worktree = false

        /// What the sidebar heads the file's group with; nil for a file in a set folder, which is
        /// listed under its folder's name instead.
        var checkout: SidebarTree.Checkout? {
            inFolder ? nil : SidebarTree.Checkout(root: root.path, repo: group, branch: branch, worktree: worktree)
        }
    }

    /// The set's name; nil for a single file.
    let setName: String?
    private(set) var entries: [Entry]

    /// A file's change event: "md:changed" or "folio:changed", and the id of the file.
    var onEvent: ((_ type: String, _ id: String) -> Void)?
    /// The set's list of files changed (added, removed or reordered).
    var onChange: (() -> Void)?

    private var manifest: URL?
    private var timer: Timer?

    init(single document: Document) {
        setName = nil
        entries = [Entry(document: document, name: document.file.lastPathComponent, group: "")]
        entries.forEach(wire)
    }

    init(set info: Rust.SetInfo) {
        setName = info.name
        manifest = info.manifest
        let inFolder = Set(info.folders.flatMap { $0.files.map(\.id) })
        entries = info.allFiles.map { Self.entry($0, inFolder: inFolder.contains($0.id)) }
        entries.forEach(wire)
    }

    var documents: [Document] { entries.map(\.document) }

    /// The file for an id; no id means the first.
    func document(id: String?) -> Document? {
        guard let id else { return entries.first?.document }
        return entries.first { $0.document.id == id }?.document
    }

    func startWatching() {
        entries.forEach { $0.document.startWatching() }
        guard manifest != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.pollManifest() }
    }

    func stopWatching() {
        entries.forEach { $0.document.stopWatching() }
        timer?.invalidate()
        timer = nil
    }

    /// Reads the manifest again. Files that are still in the set keep their Document, so
    /// their watchers and the window's state carry on.
    func reload() {
        guard let setName, let info = try? Rust.setLoad(setName) else { return }
        let inFolder = Set(info.folders.flatMap { $0.files.map(\.id) })
        // The window needs a file to show: when the last one goes (its folder emptied), the list
        // stays as it was until there is a file again.
        guard !info.allFiles.isEmpty else { return }
        let before = entries.map(Self.signature)
        // Read on every tick, so look files up by id.
        let current = Dictionary(entries.map { ($0.document.id, $0) }, uniquingKeysWith: { first, _ in first })
        var next: [Entry] = []
        for file in info.allFiles {
            if let kept = current[file.id], kept.document.file == file.path {
                next.append(Entry(document: kept.document, name: file.name, group: file.group, inFolder: inFolder.contains(file.id),
                                  root: file.root, branch: file.branch, worktree: file.worktree))
            } else {
                let entry = Self.entry(file, inFolder: inFolder.contains(file.id))
                wire(entry)
                entry.document.startWatching()
                next.append(entry)
            }
        }
        for gone in entries where !next.contains(where: { $0.document === gone.document }) {
            gone.document.stopWatching()
        }
        entries = next
        if entries.map(Self.signature) != before { onChange?() }
    }

    // MARK: private

    private func pollManifest() {
        guard manifest != nil else { return }
        // The set is read again each time: a file can come or go anywhere below a folder, and a
        // `git checkout` changes the branch a group is headed with. `reload` says when it changed.
        reload()
    }

    private func wire(_ entry: Entry) {
        let document = entry.document
        document.onEvent = { [weak self, weak document] type in
            guard let document else { return }
            self?.onEvent?(type, document.id)
        }
    }

    private static func entry(_ file: Rust.SetFile, inFolder: Bool = false) -> Entry {
        Entry(document: Document(file: file.path, sidecar: file.sidecar, id: file.id), name: file.name, group: file.group, inFolder: inFolder,
              root: file.root, branch: file.branch, worktree: file.worktree)
    }

    /// What the window shows of an entry: when it changes, the sidebar is rebuilt.
    private static func signature(_ entry: Entry) -> String {
        "\(entry.document.id)|\(entry.name)|\(entry.group)|\(entry.root.path)|\(entry.branch ?? "")|\(entry.worktree)"
    }
}
