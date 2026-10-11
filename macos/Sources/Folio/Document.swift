import Foundation

/// One markdown file and its `.folio` sidecar: the file IO behind the bridge, and the
/// change detection that replaces watcher.rs.
final class Document {
    /// The id a window with a single file uses, like `folio serve` on one file.
    static let singleID = "main"
    static let emptySidecar = #"{"version":1,"annotations":[]}"#

    /// What the page calls this file (`?file=<id>`); set files carry the set's id.
    let id: String
    let file: URL
    let sidecar: URL

    /// Called with "md:changed" or "folio:changed" for the page's `__folioEmit`.
    var onEvent: ((String) -> Void)?

    private struct Stamp: Equatable {
        var modified: Date?
        var size: Int?
        var inode: Int?
    }

    private var fileStamp: Stamp
    private var sidecarStamp: Stamp
    private var timer: Timer?

    init(file: URL, sidecar: URL, id: String) {
        self.id = id
        self.file = file
        self.sidecar = sidecar
        fileStamp = Self.stamp(file)
        sidecarStamp = Self.stamp(sidecar)
    }

    /// A file on its own: the sidecar goes where the git-root rule puts it.
    convenience init(file: URL) throws {
        self.init(file: file, sidecar: URL(fileURLWithPath: try Rust.sidecarPath(for: file.path)), id: Self.singleID)
    }

    // MARK: reading and writing

    func readFile() throws -> String {
        try String(contentsOf: file, encoding: .utf8)
    }

    /// The sidecar text, or the empty sidecar when none exists yet.
    func readSidecar() throws -> String {
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return Self.emptySidecar }
        return try String(contentsOf: sidecar, encoding: .utf8)
    }

    /// Our own writes are noted as seen, so the poller does not report them back. The
    /// page already has the text it just saved.
    func writeFile(_ content: String) throws {
        try Data(content.utf8).write(to: file)
        fileStamp = Self.stamp(file)
    }

    func writeSidecar(_ body: String) throws {
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: sidecar)
        sidecarStamp = Self.stamp(sidecar)
    }

    /// Unresolved annotations, for the file menu badge.
    func pendingCount() -> Int {
        guard let text = try? readSidecar(),
              let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let annotations = obj["annotations"] as? [[String: Any]] else { return 0 }
        return annotations.filter { ($0["resolved"] as? Bool) != true }.count
    }

    // MARK: watching

    /// Polls rather than using FSEvents or a vnode source: those follow an inode and go
    /// quiet after an atomic save (write temp, rename), which is how agents and most
    /// editors write. Same reasoning and interval as watcher.rs.
    func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stopWatching() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let nowFile = Self.stamp(file)
        if nowFile != fileStamp {
            fileStamp = nowFile
            onEvent?("md:changed")
        }
        let nowSidecar = Self.stamp(sidecar)
        if nowSidecar != sidecarStamp {
            sidecarStamp = nowSidecar
            onEvent?("folio:changed")
        }
    }

    private static func stamp(_ url: URL) -> Stamp {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return Stamp() }
        return Stamp(
            modified: attrs[.modificationDate] as? Date,
            size: (attrs[.size] as? NSNumber)?.intValue,
            inode: (attrs[.systemFileNumber] as? NSNumber)?.intValue
        )
    }
}
