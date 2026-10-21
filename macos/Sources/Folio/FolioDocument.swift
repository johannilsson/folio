import AppKit

/// What the app was started with, shared by every window.
enum AppConfig {
    /// The built frontend. Inside the .app it is bundled; from `swift run` it is the
    /// checkout this was compiled from.
    static var dist: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("dist"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("frontend/dist")
    }()
    static var selfTest = false
    /// Where PlantUML diagrams are drawn (the web page and the preview both ask it).
    static let plantumlURL = "https://www.plantuml.com/plantuml"
    /// Off for now: a `plantuml` block shows as a fenced code block. The rendering stays; flip this (and
    /// `renderPlantUML` in `frontend/src/diagrams.ts`) to bring it back.
    static let renderPlantUML = false
    /// Whether the preview is the web page (Tiptap, `-WebPreview YES` or the `WebPreview` default) instead
    /// of `PreviewView`, which is what shows by default. The flag and everything that checks it goes with
    /// the web page.
    static var webPreview: Bool { UserDefaults.standard.bool(forKey: "WebPreview") }
    /// `--set <name>`, `--screenshot <png>` and `--appearance light|dark`: see Screenshot.swift.
    static var openSet: String?
    static var screenshot: String?
    static var appearance: String?
}

/// One open markdown file. The page saves its own edits through the bridge, so this
/// never has unsaved changes of its own and has no Save: AppKit supplies the window,
/// the title and proxy icon, Open Recent, and opening from Finder.
final class FolioDocument: NSDocument {
    private(set) var files: Document!

    override class var autosavesInPlace: Bool { false }

    // Undo belongs to the editors in the page. With a document undo manager the window
    // answers Edit > Undo itself and WebKit's native undo never reaches CodeMirror.
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
