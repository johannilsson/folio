import Foundation
import WebKit

/// The Swift side of macos/BRIDGE.md.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "folio"

    let document: Document
    /// Every op the page has sent, so the self-test can see what went through here.
    private(set) var ops: [String] = []

    init(document: Document) {
        self.document = document
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

    private func handle(_ op: String, _ body: [String: Any]) throws -> Any {
        switch op {
        case "info":
            return [
                "id": Document.id,
                "filename": document.file.lastPathComponent,
                "set": NSNull(),
                "plantumlUrl": "https://www.plantuml.com/plantuml",
            ] as [String: Any]
        case "files":
            return [[
                "id": Document.id,
                "name": document.file.lastPathComponent,
                "group": "",
                "pending": document.pendingCount(),
            ] as [String: Any]]
        case "krokiUrl":
            return "https://kroki.io"

        case "getFile":
            return try document.readFile()
        case "putFile":
            guard let content = body["content"] as? String else { throw RustError(description: "putFile: no content") }
            try document.writeFile(content)
            return NSNull()

        case "getFolio":
            return try JSONSerialization.jsonObject(with: Data(document.readSidecar().utf8))
        case "putFolio":
            guard let text = body["body"] as? String else { throw RustError(description: "putFolio: no body") }
            try document.writeSidecar(text)
            // Like the server: tell the page its own write landed (it recognises the echo).
            document.onEvent?("folio:changed")
            return NSNull()

        case "anchor", "anchorRaw":
            let items = try JSONSerialization.data(withJSONObject: body["items"] ?? [])
            return try JSONSerialization.jsonObject(with: Data(
                Rust.anchor(doc: document.readFile(), itemsJSON: String(decoding: items, as: UTF8.self), raw: op == "anchorRaw").utf8
            ))

        case "accept":
            guard let id = body["id"] as? String else { throw RustError(description: "accept: no id") }
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
