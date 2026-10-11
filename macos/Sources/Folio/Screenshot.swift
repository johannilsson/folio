import AppKit
import WebKit

/// A picture of a window as the user sees it: title bar and toolbar included, transparent
/// round corners, no shadow.
enum WindowPicture {
    static func write(_ window: NSWindow, to path: String) {
        guard let image = CGWindowListCreateImage(
                .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming]),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// `Folio --set <name> --screenshot <png>`: opens the set, arranges the window the way the
/// README shows it (a file with annotations, the comments pane open), saves a picture and
/// quits. Needs a logged-in desktop session, like the self-test.
@MainActor
enum Screenshot {
    static func run(_ win: SetWindowController, to path: String) async {
        func page(_ source: String) async -> Any? {
            try? await win.webView.callAsyncJavaScript("return \(source)", contentWorld: .page)
        }
        func wait(_ condition: String, seconds: Double = 10) async {
            let deadline = Date().addingTimeInterval(seconds)
            while Date() < deadline {
                if await page(condition) as? Bool == true { return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }

        win.window?.setFrame(NSRect(x: 0, y: 0, width: 1240, height: 720), display: true)
        win.window?.center()
        win.showWindow(nil)
        win.showSidebar()
        await wait("!!document.querySelector('#editor-tiptap .ProseMirror') && !document.getElementById('editor-wrapper').hidden")

        // The file of the set with the most going on: a replacement, a highlight and a comment.
        if let target = win.workspace.entries.first(where: { $0.name.hasSuffix("producers.md") }) {
            win.sidebar.choose(target.document.id)
            await wait("document.getElementById('filename-display').textContent === 'producers.md'")
        }
        _ = await page("document.getElementById('toggle-gutter-btn').click()")
        await wait("document.querySelectorAll('#annotation-gutter .ann-card').length >= 3")

        // Let the pane finish sliding and the cards settle, and the window come to the front.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        // Active, so the sidebar highlights in the system accent rather than inactive grey.
        NSApp.activate(ignoringOtherApps: true)
        win.window?.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        if let window = win.window { WindowPicture.write(window, to: path) }
    }
}
