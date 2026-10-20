import AppKit
import WebKit

/// What the native preview gets from JavaScript: mermaid diagrams and the colours of code. A hidden
/// web view loads the diagram page of the bundle (`frontend/src/diagram.ts`); it draws a diagram
/// and a picture of that is the result, and it answers which parts of a block of code are keywords,
/// strings and so on. Diagrams are drawn one at a time.
@MainActor
final class DiagramPage: NSObject, WKNavigationDelegate {
    static let shared = DiagramPage()

    private var webView: WKWebView?
    private var window: NSWindow?
    private var loading: [CheckedContinuation<Bool, Never>] = []
    private var loaded = false
    private var last: Task<Void, Never>?

    /// The diagram as a picture, in a light or dark look, or nil when it does not draw.
    func render(_ code: String, dark: Bool) async -> NSImage? {
        let before = last
        let job = Task { @MainActor [self] () -> NSImage? in
            await before?.value
            return await draw(code, dark: dark)
        }
        last = Task { _ = await job.value }
        return await job.value
    }

    /// The coloured pieces of `code` in `language`: UTF-16 ranges of the code and their highlight.js
    /// scope. Empty when the language is not known or the page does not answer.
    func highlight(_ code: String, language: String) async -> [(range: NSRange, scope: String)] {
        guard await load(), let webView else { return [] }
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(
                """
                for (let i = 0; i < 100 && !window.__folioHighlight; i++) await new Promise(resolve => setTimeout(resolve, 100))
                return window.__folioHighlight(code, language)
                """, arguments: ["code": code, "language": language], in: nil, contentWorld: .page
            )
        } catch {
            fputs("highlight: \(error)\n", stderr)
            return []
        }
        return (answer as? [[Any]] ?? []).compactMap { span in
            guard span.count == 3, let from = (span[0] as? NSNumber)?.intValue, let to = (span[1] as? NSNumber)?.intValue,
                  let scope = span[2] as? String, to > from else { return nil }
            return (NSRange(location: from, length: to - from), scope)
        }
    }

    private func draw(_ code: String, dark: Bool) async -> NSImage? {
        guard await load(), let webView, let window else { return nil }
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(
                """
                for (let i = 0; i < 100 && !window.__folioMermaid; i++) await new Promise(resolve => setTimeout(resolve, 100))
                return await window.__folioMermaid(code, dark)
                """, arguments: ["code": code, "dark": dark], in: nil, contentWorld: .page
            )
        } catch {
            fputs("mermaid: \(error)\n", stderr)
            return nil
        }
        guard let size = answer as? [Any], size.count == 2,
              let width = (size[0] as? NSNumber)?.doubleValue, let height = (size[1] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else {
            fputs("mermaid: no size for the diagram: \(String(describing: answer))\n", stderr)
            return nil
        }
        window.setContentSize(NSSize(width: width, height: height))
        webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Let the web view lay the new size out before it is photographed.
        try? await Task.sleep(nanoseconds: 150_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
        configuration.snapshotWidth = NSNumber(value: width * 2)
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else {
            fputs("mermaid: the snapshot failed\n", stderr)
            return nil
        }
        // Twice the pixels for the same size on screen.
        image.size = NSSize(width: width, height: height)
        return image
    }

    private func load() async -> Bool {
        if loaded { return true }
        if webView == nil {
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(SchemeHandler(root: AppConfig.dist), forURLScheme: SchemeHandler.scheme)
            let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
            view.navigationDelegate = self
            // In a window nobody sees, so that it is laid out and drawn like any page.
            let host = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            host.contentView = view
            host.isReleasedWhenClosed = false
            host.ignoresMouseEvents = true
            host.orderBack(nil)
            webView = view
            window = host
            view.load(URLRequest(url: URL(string: "folio://app/diagram.html")!))
        }
        return await withCheckedContinuation { loading.append($0) }
    }

    private func finishLoading(_ ok: Bool) {
        loaded = ok
        // A page that did not load is tried again by the next diagram.
        if !ok { webView = nil; window?.close(); window = nil }
        let waiting = loading
        loading = []
        for continuation in waiting { continuation.resume(returning: ok) }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { finishLoading(true) }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finishLoading(false) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        MainActor.assumeIsolated { finishLoading(false) }
    }
}
