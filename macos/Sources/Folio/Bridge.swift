import Foundation
import WebKit

/// The Swift side of macos/BRIDGE.md.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "folio"

    let workspace: Workspace
    /// Every op the page has sent, so the self-test can see what went through here.
    private(set) var ops: [String] = []
    /// The page's full height, and a rectangle of it (top and bottom, in page coordinates)
    /// that has to come into view.
    var onLayout: ((_ height: Double) -> Void)?
    var onReveal: ((_ top: Double, _ bottom: Double) -> Void)?
    /// What the preview reports for the native annotation UI.
    var onAnchors: (([AnchorRect]) -> Void)?
    var onSelection: ((SelectionInfo?) -> Void)?
    /// The annotation clicked in the text (nil: none); a click anywhere before it.
    var onFocus: ((String?) -> Void)?
    var onPointer: (() -> Void)?
    /// The reader typed in the page.
    var onTyping: (() -> Void)?

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
                "plantumlUrl": AppConfig.plantumlURL ?? "",
            ] as [String: Any]
        case "layout":
            onLayout?((body["height"] as? NSNumber)?.doubleValue ?? 0)
            return NSNull()
        case "reveal":
            onReveal?((body["top"] as? NSNumber)?.doubleValue ?? 0, (body["bottom"] as? NSNumber)?.doubleValue ?? 0)
            return NSNull()
        case "anchors":
            let list = body["anchors"] as? [[String: Any]] ?? []
            onAnchors?(list.compactMap { item in
                guard let id = item["id"] as? String, let from = (item["from"] as? NSNumber)?.intValue,
                      let top = (item["top"] as? NSNumber)?.doubleValue, let bottom = (item["bottom"] as? NSNumber)?.doubleValue,
                      let left = (item["left"] as? NSNumber)?.doubleValue else { return nil }
                return AnchorRect(id: id, from: from, top: top, bottom: bottom, left: left)
            })
            return NSNull()
        case "selection":
            func number(_ item: [String: Any], _ key: String) -> Double? { (item[key] as? NSNumber)?.doubleValue }
            if let item = body["selection"] as? [String: Any],
               let from = number(item, "from"), let to = number(item, "to"), let top = number(item, "top"),
               let bottom = number(item, "bottom"), let endBottom = number(item, "endBottom"),
               let left = number(item, "left"), let right = number(item, "right"),
               let target = item["target"] as? String, let before = item["contextBefore"] as? String {
                onSelection?(SelectionInfo(from: Int(from), to: Int(to), top: top, bottom: bottom, endBottom: endBottom,
                                           left: left, right: right, target: target, contextBefore: before))
            } else {
                onSelection?(nil)
            }
            return NSNull()
        case "focus":
            onFocus?(body["id"] as? String)
            return NSNull()
        case "pointer":
            onPointer?()
            return NSNull()
        case "typing":
            onTyping?()
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
        case "anchor":
            // The preview anchors against its own rendered text.
            let items = try JSONSerialization.data(withJSONObject: body["items"] ?? [])
            return try JSONSerialization.jsonObject(with: Data(
                Rust.anchor(doc: body["text"] as? String ?? "", itemsJSON: String(decoding: items, as: UTF8.self), raw: false).utf8
            ))

        default:
            throw RustError(description: "unsupported op \(op)")
        }
    }
}
