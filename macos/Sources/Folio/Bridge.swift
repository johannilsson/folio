import Foundation
import WebKit

/// The Swift side of macos/BRIDGE.md.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "folio"

    let workspace: Workspace
    /// Every op the page has sent, so the self-test can see what went through here.
    private(set) var ops: [String] = []
    /// The page's source/comments toggles, for the native toolbar.
    var onUIState: ((_ source: Bool, _ comments: Bool, _ pending: Int) -> Void)?
    /// The page's full height, and a rectangle of it (top and bottom, in page coordinates)
    /// that has to come into view.
    var onLayout: ((_ height: Double) -> Void)?
    var onReveal: ((_ top: Double, _ bottom: Double) -> Void)?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    func count(_ op: String) -> Int { ops.filter { $0 == op }.count }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "malformed message")
            return
        }
        ops.append(op)
        do {
            replyHandler(try handle(op, body), nil)
        } catch {
            replyHandler(nil, "\(error)")
        }
    }

    /// The file a message is about: its `file` id, or the first file when it names none.
    private func target(_ body: [String: Any]) throws -> Document {
        let id = body["file"] as? String
        guard let document = workspace.document(id: id) else {
            throw RustError(description: "unknown file \(id ?? "")")
        }
        return document
    }

    private func handle(_ op: String, _ body: [String: Any]) throws -> Any {
        switch op {
        case "info":
            let document = try target(body)
            return [
                "id": document.id,
                "filename": document.file.lastPathComponent,
                "set": workspace.setName ?? NSNull(),
                "plantumlUrl": "https://www.plantuml.com/plantuml",
            ] as [String: Any]
        case "uiState":
            onUIState?(body["source"] as? Bool ?? false, body["comments"] as? Bool ?? false, body["pending"] as? Int ?? 0)
            return NSNull()
        case "layout":
            onLayout?((body["height"] as? NSNumber)?.doubleValue ?? 0)
            return NSNull()
        case "reveal":
            onReveal?((body["top"] as? NSNumber)?.doubleValue ?? 0, (body["bottom"] as? NSNumber)?.doubleValue ?? 0)
            return NSNull()
        case "krokiUrl":
            return "https://kroki.io"

        case "getFile":
            return try target(body).readFile()
        case "putFile":
            guard let content = body["content"] as? String else { throw RustError(description: "putFile: no content") }
            try target(body).writeFile(content)
            return NSNull()

        case "getFolio":
            return try JSONSerialization.jsonObject(with: Data(target(body).readSidecar().utf8))
        case "putFolio":
            guard let text = body["body"] as? String else { throw RustError(description: "putFolio: no body") }
            let document = try target(body)
            try document.writeSidecar(text)
            // Tell the page its own write landed (it recognises the echo).
            document.onEvent?("folio:changed")
            return NSNull()

        case "anchor", "anchorRaw":
            let document = try target(body)
            let items = try JSONSerialization.data(withJSONObject: body["items"] ?? [])
            // The preview anchors against its own rendered text; source mode against the file.
            let doc = op == "anchorRaw" ? try document.readFile() : body["text"] as? String ?? ""
            return try JSONSerialization.jsonObject(with: Data(
                Rust.anchor(doc: doc, itemsJSON: String(decoding: items, as: UTF8.self), raw: op == "anchorRaw").utf8
            ))

        case "accept":
            guard let id = body["id"] as? String else { throw RustError(description: "accept: no id") }
            let document = try target(body)
            let result = try Rust.accept(doc: document.readFile(), sidecarJSON: document.readSidecar(), id: id)
            if let patched = result.doc {
                try document.writeFile(patched)
                document.onEvent?("md:changed")
            }
            try document.writeSidecar(result.sidecar)
            document.onEvent?("folio:changed")
            return NSNull()

        default:
            throw RustError(description: "unsupported op \(op)")
        }
    }
}
