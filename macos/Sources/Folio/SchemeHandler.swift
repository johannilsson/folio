import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the built frontend (`frontend/dist`) under `folio://app/`, replacing the
/// rust-embed asset routes of the HTTP server.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "folio"
    static let entryURL = URL(string: "folio://app/index.html")!

    private let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(path).standardizedFileURL

        // Never serve anything outside the bundle directory.
        guard file.path.hasPrefix(root.path + "/"),
              let data = try? Data(contentsOf: file) else {
            respond(task, url: url, status: 404, mime: "text/plain", data: Data("not found".utf8))
            return
        }
        respond(task, url: url, status: 200, mime: Self.mimeType(for: file), data: Self.nativeChrome(data, file))
    }

    /// The app, not the page, supplies the title and toolbar: tell the page's CSS so
    /// from the first paint (see "Native app" in index.html).
    private static func nativeChrome(_ data: Data, _ file: URL) -> Data {
        guard file.lastPathComponent == "index.html",
              let html = String(data: data, encoding: .utf8),
              let range = html.range(of: "<html") else { return data }
        return Data(html.replacingCharacters(in: range, with: "<html class=\"native-chrome\"").utf8)
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    private func respond(_ task: any WKURLSchemeTask, url: URL, status: Int, mime: String, data: Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count)]
        )!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    // Module scripts are refused unless served as a JavaScript type, and the system
    // table has been inconsistent about `.js`, so pin the web types.
    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "svg": return "image/svg+xml"
        case "wasm": return "application/wasm"
        default:
            return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
