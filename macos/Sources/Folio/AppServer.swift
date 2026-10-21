import AppKit

/// What the running app tells Folio's MCP server (src/mcp.rs): the windows with their selection and
/// focused annotation (`state`), and `reveal`. The server is a separate process that Claude desktop
/// starts (`Folio --mcp`); it connects to the socket in the config folder (src/live.rs), which libfolio
/// serves on a thread of its own and which calls `answer` once per request. A request is one line of
/// JSON, `{"op": ..., ...}`, and the answer `{"ok": ...}` or `{"error": "..."}`. Both are described in
/// `macos/README.md`; change them together with `src/mcp.rs`.
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

    /// Folio ▸ Connect to Claude…: lets Claude desktop start this app's MCP server.
    static func connectClaude() throws -> (config: String, change: String) {
        guard let executable = Bundle.main.executablePath else { throw RustError(description: "cannot find the app's executable") }
        return try Rust.connectClaude(executable: executable)
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

    /// Every window with what it shows. `selection` is the selected words as rendered text, the way an
    /// annotation names them; `focused` the id of the annotation the reader is on.
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
            if let selection = editor.annotations.selection {
                window["selection"] = ["target": selection.target, "context_before": selection.contextBefore]
            }
            if let focused = editor.annotations.focusedID { window["focused"] = focused }
            return window
        }]
    }

    /// Brings the file forward, opening it first if it is not open (in its set's window if a set has it),
    /// and focuses the annotation. The answer does not wait for a file that opens now: the annotation is
    /// focused once the window has placed it.
    private static func reveal(_ url: URL, annotation id: String?) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return reply(error: "no such file: \(url.path)") }
        let wanted = url.resolvingSymlinksInPath().path
        func isWanted(_ document: Document) -> Bool { document.file.resolvingSymlinksInPath().path == wanted }

        NSApp.activate(ignoringOtherApps: true)
        if let editor = editors.first(where: { $0.workspace.documents.contains(where: isWanted) }) {
            if let set = editor as? SetWindowController, let document = editor.workspace.documents.first(where: isWanted) {
                set.openFile(document.id)
            }
            editor.showWindow(nil)
            if let id { focus(id, in: editor) }
            return reply(ok: ["opened": false])
        }
        guard let app = NSApp.delegate as? AppDelegate else { return reply(error: "the app is not ready") }
        app.open(url) { document in
            if let id, let editor = document?.windowControllers.first as? EditorWindowController { focus(id, in: editor) }
        }
        return reply(ok: ["opened": true])
    }

    /// Focuses the annotation once the window has placed it: a file that opens now takes a moment.
    private static func focus(_ id: String, in editor: EditorWindowController) {
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
