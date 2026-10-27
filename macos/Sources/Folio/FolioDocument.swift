import AppKit

/// What the app was started with, shared by every window.
enum AppConfig {
    /// The built frontend (the diagram page). Inside the .app it is bundled; from `swift run` it is the
    /// checkout this was compiled from.
    static var dist: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("dist"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("diagram.html").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("frontend/dist")
    }()
    static var selfTest = false
    /// How PlantUML diagrams are drawn is the reader's choice; nothing is bundled. The `PlantUMLCommand`
    /// default (`defaults write dev.folio.Folio PlantUMLCommand plantuml`, or `-PlantUMLCommand …`) is a
    /// command that reads the diagram on stdin and writes a PNG, run as `<command> -pipe -tpng`; it wins
    /// over `PlantUMLServer`, a server that is sent the diagram's text. Neither set, a `plantuml` block
    /// shows as a fenced code block.
    static var plantumlCommand: [String]? {
        let words = UserDefaults.standard.string(forKey: "PlantUMLCommand")?
            .split(whereSeparator: \.isWhitespace).map(String.init) ?? []
        return words.isEmpty ? nil : words
    }
    static var plantumlURL: String? {
        guard let url = UserDefaults.standard.string(forKey: "PlantUMLServer")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return nil }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }
    static var renderPlantUML: Bool { plantumlCommand != nil || plantumlURL != nil }
    /// With the comments pane closed, every card sits in the text under its row (View ▸ Comments Inline)
    /// rather than only the focused one floating beside it. One choice for every window, kept across launches.
    static var commentsInline: Bool {
        get { UserDefaults.standard.bool(forKey: "CommentsInline") }
        set { UserDefaults.standard.set(newValue, forKey: "CommentsInline") }
    }
    /// `--set <name>`, `--screenshot <png>` and `--appearance light|dark`: see Screenshot.swift.
    static var openSet: String?
    static var screenshot: String?
    static var appearance: String?
}

/// One open markdown file. The source editor saves its own edits, so this
/// never has unsaved changes of its own and has no Save: AppKit supplies the window,
/// the title and proxy icon, Open Recent, and opening from Finder.
final class FolioDocument: NSDocument {
    private(set) var files: Document!

    override class var autosavesInPlace: Bool { false }

    // Undo belongs to the editors: the source's text view and the annotation actions. With a document
    // undo manager the window would answer Edit > Undo itself and they would never get it.
    override init() {
        super.init()
        hasUndoManager = false
    }

    override func read(from url: URL, ofType typeName: String) throws {
        files = try Document(file: url.standardizedFileURL)
    }

    override func makeWindowControllers() {
        if let url = fileURL { RecentFiles.note(url) }
        addWindowController(FolioWindowController(document: self))
    }

    /// The file name as it is on disk, extension included.
    override var displayName: String! {
        get { fileURL?.lastPathComponent ?? super.displayName }
        set { super.displayName = newValue }
    }

    override func close() {
        files?.stopWatching()
        super.close()
    }
}
