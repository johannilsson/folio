import Foundation
import WebKit

/// Phase 2 stub of the bridge in macos/BRIDGE.md: read-only, and it records what the
/// page asked for so the self-test can check the editor really talks to Swift.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "folio"

    let file: URL
    private(set) var ops: [String] = []
    private(set) var lastPutFile: String?

    init(file: URL) {
        self.file = file
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

        switch op {
        case "info":
            replyHandler([
                "id": "main",
                "filename": file.lastPathComponent,
                "set": NSNull(),
                "plantumlUrl": "https://www.plantuml.com/plantuml",
            ], nil)
        case "files":
            replyHandler([["id": "main", "name": file.lastPathComponent, "group": "", "pending": 0]], nil)
        case "getFile":
            do {
                replyHandler(try String(contentsOf: file, encoding: .utf8), nil)
            } catch {
                replyHandler(nil, "cannot read \(file.path): \(error.localizedDescription)")
            }
        case "getFolio":
            replyHandler(["version": 1, "annotations": []], nil)
        case "putFile":
            lastPutFile = body["content"] as? String
            replyHandler(NSNull(), nil)
        case "putFolio":
            replyHandler(NSNull(), nil)
        case "krokiUrl":
            replyHandler("https://kroki.io", nil)
        case "anchor", "anchorRaw":
            replyHandler([], nil)
        default:
            replyHandler(nil, "unsupported op \(op)")
        }
    }
}
