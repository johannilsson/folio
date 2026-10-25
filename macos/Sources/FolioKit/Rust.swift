import CFolio
import Foundation

public struct RustError: LocalizedError, CustomStringConvertible {
    public let description: String
    public var errorDescription: String? { description }

    public init(description: String) {
        self.description = description
    }
}

/// Swift face of libfolio (src/ffi.rs): the same anchoring and accept code the CLI uses.
public enum Rust {
    public static func sidecarPath(for file: String) throws -> String {
        try take(folio_sidecar_path(file))
    }

    /// `items` is the JSON request body of `/api/anchor`; the result is its JSON response.
    public static func anchor(doc: String, itemsJSON: String, raw: Bool) throws -> String {
        try take(folio_anchor(doc, itemsJSON, raw))
    }

    /// The selection `range` (UTF-16, as the text view has it) of the markdown `doc` as rendered text,
    /// which is what agents and the preview anchor by: the selected words and up to 30 characters
    /// before them, without markdown syntax. Nil when none of it is rendered text.
    public static func renderedSelection(doc: String, range: NSRange) throws -> (target: String, contextBefore: String)? {
        let out = try object(folio_rendered_selection(doc, range.location, range.upperBound))
        guard let target = out["target"] as? String, let context = out["context_before"] as? String else { return nil }
        return (target, context)
    }

    /// The patched markdown (nil when accepting changes nothing in it) and the new
    /// sidecar text.
    public static func accept(doc: String, sidecarJSON: String, id: String) throws -> (doc: String?, sidecar: String) {
        let out = try take(folio_accept(doc, sidecarJSON, id))
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let sidecar = obj["sidecar"] as? String else {
            throw RustError(description: "unexpected accept result")
        }
        return (obj["doc"] as? String, sidecar)
    }

    /// Applies one editor action (see src/edit.rs) to the sidecar text. Returns the new
    /// sidecar text and the id of the annotation or reply the action created.
    public static func edit(sidecarJSON: String, edit: [String: Any]) throws -> (sidecar: String, id: String?) {
        let body = String(decoding: try JSONSerialization.data(withJSONObject: edit), as: UTF8.self)
        let out = try object(folio_edit(sidecarJSON, body))
        guard let sidecar = out["sidecar"] as? String else { throw RustError(description: "unexpected edit result") }
        return (sidecar, out["id"] as? String)
    }

    // MARK: Claude

    /// Runs the MCP server on stdin and stdout until Claude closes them (`Folio --mcp`). The exit code.
    public static func mcpServe() -> Int32 {
        folio_mcp_serve()
    }

    /// Starts answering the MCP server's questions about this app (src/live.rs). `handler` gets each
    /// request as JSON and returns the response as a `malloc`ed JSON string; it runs on another thread.
    public static func appListen(_ handler: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?) throws {
        _ = try object(folio_app_listen(handler))
    }

    public static func appStop() {
        folio_app_stop()
    }

    /// What to run or paste to register `executable --mcp` in a tool.
    public struct Snippet {
        public let name: String
        /// Where it goes.
        public let hint: String
        public let text: String
        /// Set when Folio can write it itself: the id for `connectMCP`, and the file it writes.
        public let client: String?
        public let config: String?
    }

    public static func mcpSnippets(executable: String) throws -> [Snippet] {
        guard let list = try object(folio_mcp_snippets(executable))["snippets"] as? [[String: Any]] else {
            throw RustError(description: "unexpected result from libfolio")
        }
        return list.compactMap { item in
            guard let name = item["name"] as? String, let hint = item["hint"] as? String, let text = item["text"] as? String else { return nil }
            return Snippet(name: name, hint: hint, text: text, client: item["client"] as? String, config: item["config"] as? String)
        }
    }

    /// Registers `executable --mcp` as the MCP server of `client` ("claude" for Claude desktop, or "codex").
    /// `change` is "added", "updated" or "unchanged"; the tool has to be restarted to see it.
    public static func connectMCP(client: String, executable: String) throws -> (config: String, change: String) {
        let out = try object(folio_mcp_connect(client, executable))
        guard let config = out["config"] as? String, let change = out["change"] as? String else {
            throw RustError(description: "unexpected result from libfolio")
        }
        return (config, change)
    }

    // MARK: sets

    public struct SetFile {
        public let id: String
        /// Path relative to the root, as the sidebar shows it.
        public let name: String
        /// Name of the root folder; files are grouped by it.
        public let group: String
        public let path: URL
        public let sidecar: URL
    }

    public struct SetInfo {
        public let name: String
        /// The set's JSON file, watched so that `folio set add` from a terminal shows up.
        public let manifest: URL
        public let files: [SetFile]
    }

    public static func setNames() throws -> [String] {
        try object(folio_set_names())["names"] as? [String] ?? []
    }

    public static func setLoad(_ name: String) throws -> SetInfo {
        let obj = try object(folio_set_load(name))
        guard let manifest = obj["manifest"] as? String, let files = obj["files"] as? [[String: Any]] else {
            throw RustError(description: "unexpected set result")
        }
        return SetInfo(
            name: name,
            manifest: URL(fileURLWithPath: manifest),
            files: files.compactMap { file in
                guard let id = file["id"] as? String, let name = file["name"] as? String,
                      let group = file["group"] as? String, let path = file["path"] as? String,
                      let sidecar = file["folio_path"] as? String else { return nil }
                return SetFile(id: id, name: name, group: group, path: URL(fileURLWithPath: path), sidecar: URL(fileURLWithPath: sidecar))
            }
        )
    }

    /// Adds files to the set, creating it if needed. Files already in it are skipped.
    public static func setAdd(_ name: String, files: [URL]) throws {
        _ = try object(folio_set_add(name, paths(files), nil))
    }

    public static func setRemove(_ name: String, files: [URL]) throws {
        _ = try object(folio_set_remove(name, paths(files)))
    }

    /// Deletes the set's manifest. The files and their sidecars stay.
    public static func setDelete(_ name: String) throws {
        _ = try object(folio_set_delete(name))
    }

    private static func paths(_ files: [URL]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: files.map(\.path))) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func object(_ ptr: UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        let text = try take(ptr)
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw RustError(description: "unexpected result from libfolio")
        }
        return obj
    }

    /// Copies the result out, frees it, and turns `{"error": ...}` into a thrown error.
    private static func take(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let ptr else { throw RustError(description: "libfolio returned null") }
        defer { folio_free(ptr) }
        let text = String(cString: ptr)
        if text.hasPrefix("{\"error\""),
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let message = obj["error"] as? String {
            throw RustError(description: message)
        }
        return text
    }
}
