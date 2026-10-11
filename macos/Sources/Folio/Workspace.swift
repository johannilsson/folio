import Foundation

/// The files one window works on: a single document, or the files of a set. It resolves
/// the page's `file` ids for the bridge and relays each file's change events; for a set it
/// also watches the manifest, so `folio set add` in a terminal shows up in the window.
final class Workspace {
    struct Entry {
        let document: Document
        /// Path relative to the root, as the sidebar shows it.
        let name: String
        /// Name of the root folder; a set groups its files by it.
        let group: String
    }

    /// The set's name; nil for a single file.
    let setName: String?
    private(set) var entries: [Entry]

    /// A file's change event: "md:changed" or "folio:changed", and the id of the file.
    var onEvent: ((_ type: String, _ id: String) -> Void)?
    /// The set's list of files changed (added, removed or reordered).
    var onChange: (() -> Void)?

    private var manifest: URL?
    private var manifestStamp: Date?
    private var timer: Timer?

    init(single document: Document) {
        setName = nil
        entries = [Entry(document: document, name: document.file.lastPathComponent, group: "")]
        entries.forEach(wire)
    }

    init(set info: Rust.SetInfo) {
        setName = info.name
        manifest = info.manifest
        manifestStamp = Self.modified(info.manifest)
        entries = info.files.map { Self.entry($0) }
        entries.forEach(wire)
    }

    var documents: [Document] { entries.map(\.document) }

    /// The file for a page's `file` id; no id means the first, as with `folio serve`.
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
    /// their watchers and the page's state carry on.
    func reload() {
        guard let setName, let info = try? Rust.setLoad(setName) else { return }
        manifestStamp = Self.modified(info.manifest)
        let before = entries.map { "\($0.document.id)|\($0.name)|\($0.group)" }
        var next: [Entry] = []
        for file in info.files {
            if let kept = entries.first(where: { $0.document.id == file.id && $0.document.file == file.path }) {
                next.append(Entry(document: kept.document, name: file.name, group: file.group))
            } else {
                let entry = Self.entry(file)
                wire(entry)
                entry.document.startWatching()
                next.append(entry)
            }
        }
        for gone in entries where !next.contains(where: { $0.document === gone.document }) {
            gone.document.stopWatching()
        }
        entries = next
        if entries.map({ "\($0.document.id)|\($0.name)|\($0.group)" }) != before { onChange?() }
    }

    // MARK: private

    private func pollManifest() {
        guard let manifest, Self.modified(manifest) != manifestStamp else { return }
        reload()
    }

    private func wire(_ entry: Entry) {
        let document = entry.document
        document.onEvent = { [weak self, weak document] type in
            guard let document else { return }
            self?.onEvent?(type, document.id)
        }
    }

    private static func entry(_ file: Rust.SetFile) -> Entry {
        Entry(document: Document(file: file.path, sidecar: file.sidecar, id: file.id), name: file.name, group: file.group)
    }

    private static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
