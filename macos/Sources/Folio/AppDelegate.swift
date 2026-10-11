import AppKit
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate {
    let document: Document
    let dist: URL
    let selfTest: Bool

    var file: URL { document.file }

    private(set) var window: NSWindow!
    private(set) var webView: WKWebView!
    let bridge: Bridge

    init(document: Document, dist: URL, selfTest: Bool) {
        self.document = document
        self.dist = dist
        self.selfTest = selfTest
        self.bridge = Bridge(document: document)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard FileManager.default.fileExists(atPath: dist.appendingPathComponent("index.html").path) else {
            fputs("no index.html in \(dist.path); run `pnpm build` in frontend/\n", stderr)
            exit(66)
        }

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(SchemeHandler(root: dist), forURLScheme: SchemeHandler.scheme)
        config.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: Bridge.name)
        // Collect script errors so the self-test can fail on any.
        config.userContentController.addUserScript(WKUserScript(
            source: """
            window.__errors = [];
            window.addEventListener('error', e => window.__errors.push(String(e.message)));
            window.addEventListener('unhandledrejection', e => window.__errors.push('rejection: ' + String(e.reason)));
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        ))

        webView = WKWebView(frame: .zero, configuration: config)
        webView.isInspectable = true
        webView.navigationDelegate = self

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = file.lastPathComponent
        window.contentView = webView
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)

        NSApp.mainMenu = MainMenu.build()
        NSApp.activate(ignoringOtherApps: true)

        // Stand-in for the WebSocket: file changes reach the page as events.
        document.onEvent = { [weak self] type in
            self?.webView.evaluateJavaScript("window.__folioEmit?.('\(type)', '\(Document.id)')")
        }
        document.startWatching()

        webView.load(URLRequest(url: SchemeHandler.entryURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard selfTest else { return }
        Task { @MainActor in
            let ok = await SelfTest(app: self).run()
            exit(ok ? 0 : 1)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
        if selfTest { exit(1) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        fputs("navigation failed: \(error)\n", stderr)
        if selfTest { exit(1) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Folio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // WKWebView only gets cut/copy/paste/undo from the responder chain; these items
        // have no target, so they reach it as first responder.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        return main
    }
}
