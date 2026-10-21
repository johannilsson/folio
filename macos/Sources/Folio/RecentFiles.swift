import AppKit

/// The recent files, newest first, kept in `<config>/recents.json` beside the sets (`~/.config/folio`, or
/// `FOLIO_CONFIG_DIR`). AppKit keeps a list of its own, but it belongs to the system, which does not keep it
/// for an app whose signature changes with every build; this one is the app's.
@MainActor
enum RecentFiles {
    private static let limit = 20
    private struct Stored: Codable { var files: [String] }

    /// What was read from `path`, so that a different config folder (the self-test's) is read afresh.
    private static var loaded: (path: String?, files: [URL])?

    /// Nil in the self-test unless it has a config folder of its own, so that it does not write the user's list.
    private static var location: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["FOLIO_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir).appendingPathComponent("recents.json")
        }
        if AppConfig.selfTest { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/folio/recents.json")
    }

    /// The files that are still there, newest first.
    static func list() -> [URL] {
        stored().filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// `url` was opened: it goes first.
    static func note(_ url: URL) {
        let same = url.resolvingSymlinksInPath()
        save([url] + stored().filter { $0.resolvingSymlinksInPath() != same })
    }

    static func remove(_ url: URL) {
        let same = url.resolvingSymlinksInPath()
        save(stored().filter { $0.resolvingSymlinksInPath() != same })
    }

    static func clear() {
        save([])
    }

    private static func stored() -> [URL] {
        let path = location?.path
        if let loaded, loaded.path == path { return loaded.files }
        var files: [URL]
        if let location, let data = try? Data(contentsOf: location) {
            files = ((try? JSONDecoder().decode(Stored.self, from: data))?.files ?? []).map { URL(fileURLWithPath: $0) }
        } else {
            // No list yet: start with what AppKit has, once.
            files = NSDocumentController.shared.recentDocumentURLs
        }
        loaded = (path, files)
        if let location, !FileManager.default.fileExists(atPath: location.path) { save(files) }
        return files
    }

    private static func save(_ files: [URL]) {
        let files = Array(files.prefix(limit))
        loaded = (location?.path, files)
        guard let location, let data = try? JSONEncoder().encode(Stored(files: files.map(\.path))) else { return }
        try? FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: location, options: .atomic)
    }
}
