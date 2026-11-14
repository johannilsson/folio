import AppKit
import FolioKit

/// What the running app tells Folio's MCP server (src/mcp.rs): the windows with the annotation the
/// reader has focused (`state`), and `reveal`. The server is a separate process that Claude desktop
/// starts (`Folio --mcp`); it connects to the socket in the config folder (src/live.rs), which libfolio
/// serves on a thread of its own and which calls `answer` once per request. A request is one line of
/// JSON, `{"op": ..., ...}`, and the answer `{"ok": ...}` or `{"error": "..."}`. Both are described in
/// `docs/mcp.md` ("The app socket"); change them together with `src/mcp.rs`.
@MainActor
enum AppServer {
    /// Whether this app owns the socket, and so has to take it away when it quits.
    private(set) static var serving = false

    /// Starts answering. False when another Folio already does, or the socket cannot be made.
    @discardableResult
    static func start() -> Bool {
        do {
            try Rust.appListen(answerOnMainThread)
            serving = true
        } catch {
            fputs("Folio: Claude cannot reach the app: \(error)\n", stderr)
        }
        return serving
    }

    static func stop() {
        guard serving else { return }
        serving = false
        Rust.appStop()
    }

    /// Folio ▸ Allow MCP Clients: lets MCP clients in, or shuts them out again. The choice is kept in the config
    /// folder, where the server reads it at every tool call; the app answers it only while it is on.
    static func allow(_ on: Bool) throws {
        try Rust.setMCPAllowed(on)
        if on { start() } else { stop() }
    }

    private static func executable() throws -> String {
        guard let path = Bundle.main.executablePath else { throw RustError(description: "cannot find the app's executable") }
        return path
    }

    /// Add for Me in Folio ▸ Connect to MCP Clients…: lets that tool start this app's MCP server.
    static func connect(client: String) throws -> (config: String, change: String) {
        try Rust.connectMCP(client: client, executable: executable())
    }

    /// Folio ▸ Connect to MCP Clients…: what each tool needs.
    static func clientSnippets() throws -> [Rust.Snippet] {
        try Rust.mcpSnippets(executable: executable())
    }

    // MARK: requests

    fileprivate static func answer(_ text: String) -> String {
        guard let request = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let op = request["op"] as? String else { return reply(error: "not a request") }
        switch op {
        case "state":
            return reply(ok: state())
        case "reveal":
            guard let path = request["file"] as? String else { return reply(error: "`file` is required") }
            return reveal(URL(fileURLWithPath: path), annotation: request["id"] as? String)
        default:
            return reply(error: "unknown op \(op)")
        }
    }

    private static func reply(ok value: Any) -> String {
        json(["ok": value])
    }

    private static func reply(error: String) -> String {
        json(["error": error])
    }

    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return #"{"error":"unencodable answer"}"# }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: windows

    /// The document and set windows, the one in front first.
    private static var editors: [EditorWindowController] {
        NSApp.orderedWindows.compactMap { $0.windowController as? EditorWindowController }
    }

    /// The window the reader is in: the key window, or the front one while the app is in the background.
    private static var front: EditorWindowController? {
        (NSApp.keyWindow?.windowController as? EditorWindowController) ?? editors.first
    }

    /// Every window with what it shows. `focused` is the id of the annotation the reader is on: the one
    /// they clicked, or stepped to.
    private static func state() -> [String: Any] {
        let current = front
        return ["windows": editors.map { editor -> [String: Any] in
            let document = editor.currentDocument
            var window: [String: Any] = [
                "front": editor === current,
                "file": document.file.path,
                "sidecar": document.sidecar.path,
                "mode": editor.sourceOn ? "source" : "preview",
                "pending": editor.pendingCount,
            ]
            if let set = editor as? SetWindowController { window["set"] = set.setName }
            if let focused = editor.annotations.focusedID { window["focused"] = focused }
            return window
        }]
    }

    /// Brings the file forward, opening it first if it is not open (in its set's window if a set has it),
    /// and focuses the annotation. The answer does not wait for a file that opens now: the annotation is
    /// focused once the window has placed it.
    @discardableResult
    static func reveal(_ url: URL, annotation id: String?, passage: (text: String, before: String)? = nil) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return reply(error: "no such file: \(url.path)") }
        let wanted = url.resolvingSymlinksInPath().path
        func isWanted(_ document: Document) -> Bool { document.file.resolvingSymlinksInPath().path == wanted }

        NSApp.activate(ignoringOtherApps: true)
        if let editor = editors.first(where: { $0.workspace.documents.contains(where: isWanted) }) {
            if let set = editor as? SetWindowController, let document = editor.workspace.documents.first(where: isWanted) {
                set.openFile(document.id)
            }
            editor.showWindow(nil)
            if let id { focus(id, in: editor) } else if let passage { focus(passage, in: editor) }
            return reply(ok: ["opened": false])
        }
        guard let app = NSApp.delegate as? AppDelegate else { return reply(error: "the app is not ready") }
        app.open(url) { document in
            guard let editor = document?.windowControllers.first as? EditorWindowController else { return }
            if let id { focus(id, in: editor) } else if let passage { focus(passage, in: editor) }
        }
        return reply(ok: ["opened": true])
    }

    /// What is said when a link cannot be followed; the self-test swaps it. The front window's toast,
    /// or an alert when there is no window.
    static var tell: (String) -> Void = { message in
        if let editor = front {
            editor.annotations.notify(message)
        } else {
            let alert = NSAlert()
            alert.messageText = message
            alert.runModal()
        }
    }

    /// Follows a `folio://document`, `folio://annotation` or `folio://passage` link: the file it names in the open windows,
    /// by repo, branch and path (never by folder: a worktree's folder comes and goes), else the file
    /// where the link says it was. When the repo is open but the branch or file is not, it says so.
    static func open(_ link: FolioLink) {
        let places = openFiles()
        let resolution = link.resolve(among: places.map(\.candidate))
        var annotation: String?
        var passage: (text: String, before: String)?
        switch link.target {
        case .document: break
        case .annotation(let id): annotation = id
        case .passage(let text, let before): passage = (text, before)
        }
        if case .found(let index) = resolution {
            reveal(places[index].document.file, annotation: annotation, passage: passage)
        } else if let message = FolioLink.message(for: resolution, repo: link.repo), resolution != .unknown {
            tell(message)
        } else if let file = link.file, FileManager.default.fileExists(atPath: file) {
            reveal(URL(fileURLWithPath: file), annotation: annotation, passage: passage)
        } else {
            tell(FolioLink.message(for: resolution, repo: link.repo) ?? "That file isn't here")
        }
    }

    /// The files the windows have open that are in a checkout, for a link to find by repo, branch and path.
    private static func openFiles() -> [(document: Document, candidate: FolioLink.Candidate)] {
        var places: [(document: Document, candidate: FolioLink.Candidate)] = []
        for editor in editors {
            for entry in editor.workspace.entries {
                guard let checkout = entry.checkout else { continue }
                places.append((entry.document, FolioLink.Candidate(repo: checkout.repo, branch: checkout.branch, path: entry.name)))
            }
        }
        return places
    }

    /// Why a link cannot be followed, nil when it can: the repo is open but not on its branch any more, or
    /// without the file, or the file it names is nowhere, or the file is there without what it points at (an
    /// annotation resolved or deleted, or text edited away). Read from disk, which is the truth.
    static func deadReason(of link: FolioLink) -> String? {
        let places = openFiles()
        let resolution = link.resolve(among: places.map(\.candidate))
        let document: Document
        switch resolution {
        case .found(let index):
            document = places[index].document
        case .unknown:
            guard let file = link.file, FileManager.default.fileExists(atPath: file),
                  let found = try? Document(file: URL(fileURLWithPath: file)) else {
                return FolioLink.message(for: resolution, repo: link.repo) ?? "That file isn't here"
            }
            document = found
        default:
            return FolioLink.message(for: resolution, repo: link.repo)
        }
        guard let markdown = try? document.readFile() else { return "That file isn't here" }
        let sidecar = (try? document.readSidecar()) ?? Document.emptySidecar
        return link.targetFound(markdown: markdown, sidecar: sidecar) ? nil : FolioLink.notFoundMessage(file: document.file.path)
    }

    /// A file or its annotations changed: every window's links are checked again (one window's page can link
    /// to a file another window has).
    static func refreshLinks() {
        for editor in editors { editor.scrollHost.preview.refreshLinks() }
    }

    /// Selects the passage once the window has placed it: a file that opens now takes a moment.
    static func focus(_ passage: (text: String, before: String), in editor: EditorWindowController) {
        Task { @MainActor in
            for _ in 0..<50 {
                if editor.annotations.reveal(passage: passage.text, before: passage.before) { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            tell("That text isn't in the file any more")
        }
    }

    /// Focuses the annotation once the window has placed it: a file that opens now takes a moment.
    static func focus(_ id: String, in editor: EditorWindowController) {
        Task { @MainActor in
            for _ in 0..<50 {
                if editor.annotations.reveal(annotation: id) { return }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
}

/// The callback libfolio calls, on a thread of its own, for each request of the MCP server. The windows
/// are the main thread's, so it waits for the answer there; nothing on the main thread waits for this.
private func answerOnMainThread(_ request: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let request else { return nil }
    let text = String(cString: request)
    var answer = ""
    DispatchQueue.main.sync { MainActor.assumeIsolated { answer = AppServer.answer(text) } }
    return strdup(answer)
}
