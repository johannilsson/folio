import AppKit

/// Drives the real app against throwaway copies of a document: opening through the document
/// controller, edits, undo, copy and paste through the Edit menu, the `folio` CLI adding annotations
/// from outside, accepting them in both editor modes, files changing underneath the app, the native
/// toolbar, and a second window.
@MainActor
final class SelfTest {
    let app: AppDelegate
    let source: URL
    var failures = 0
    var dirs: [URL] = []

    // Set once the first document is open.
    var controller: FolioWindowController!

    init(app: AppDelegate, source: URL) {
        self.app = app
        self.source = source
    }

    var file: URL { controller.files.file }
    var dir: URL { file.deletingLastPathComponent() }
    var name: String { file.lastPathComponent }

    func disk() -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }

    /// The document the checks start from.
    var fixture: String { (try? String(contentsOf: source, encoding: .utf8)) ?? "" }

    /// A copy inside its own "repo", so the sidecar lands next to it and the CLI can be run from there.
    func tempCopy(named name: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-\(UUID().uuidString)").resolvingSymlinksInPath()
        let copy = folder.appendingPathComponent(name ?? source.lastPathComponent)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: copy)
        dirs.append(folder)
        return copy
    }

    func run() async -> Bool {
        // Line by line, so a crash does not take the results so far with it.
        setvbuf(stdout, nil, _IOLBF, 0)
        // Typing, focus and the wheel only reach a window of the app in front. Another app taking the
        // focus while this runs makes those checks fail for that reason, not because of the app.
        NSApp.activate(ignoringOtherApps: true)
        guard let copy = try? tempCopy(), let first = await app.openForSelfTest(copy) else {
            print("FAIL  open the document")
            return false
        }
        controller = first

        await check("the window title is the file name, with its proxy icon") {
            self.controller.window?.title == self.name && self.controller.window?.representedURL == self.file
        }
        await check("the file is in Open Recent") {
            RecentFiles.list().contains { $0.resolvingSymlinksInPath() == self.file.resolvingSymlinksInPath() }
        }
        await check("the native toolbar has the two toggles") {
            let ids = self.controller.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            return ids.filter { $0 == "source" || $0 == "comments" }.count == 2
        }

        await previewChecks()
        await sourceEditingChecks()
        await wideTableChecks()
        await anchoringChecks()
        await storeChecks()
        await nativeAnnotationChecks()
        await sourceAnnotationChecks()
        await undoAcrossModesChecks()

        // For a human to look at: FOLIO_SNAPSHOT=/path/to/base saves base-*.png pictures.
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await tour(base) }

        // A second window shows its own file.
        guard let secondCopy = try? tempCopy(), let second = await app.openForSelfTest(secondCopy) else {
            report("a second document opens", false)
            return finish()
        }
        await check("a second window opens with its own document") {
            let windows = NSApp.windows.compactMap { $0.windowController as? FolioWindowController }
            return windows.count == 2 && second.files.file == secondCopy
        }
        await check("the second window shows its own file") {
            await self.until { second.scrollHost.preview.textView.string.contains("The last paragraph.") }
                && second.window?.title == secondCopy.lastPathComponent
        }
        await check("the first window kept its document") { self.controller.files.file == copy }

        await setScenario()

        // Last, since it closes every window.
        await welcomeChecks()
        return finish()
    }

    // MARK: helpers for the checks

    /// Replaces the document the way an agent does: write a temp file, rename it over.
    func replaceFile(_ text: String) {
        let tmp = dir.appendingPathComponent("incoming.tmp")
        try? text.write(to: tmp, atomically: false, encoding: .utf8)
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: tmp)
    }

    func replaceSidecar(_ annotations: [[String: Any]]) {
        let sidecar = controller.files.sidecar
        let tmp = sidecar.deletingLastPathComponent().appendingPathComponent("incoming-sidecar.tmp")
        let object: [String: Any] = ["version": 1, "annotations": annotations]
        try? JSONSerialization.data(withJSONObject: object).write(to: tmp)
        _ = try? FileManager.default.replaceItemAt(sidecar, withItemAt: tmp)
    }

    func commentJSON(_ id: String, before: String, target: String) -> [String: Any] {
        [
            "id": id, "kind": "comment", "source": "agent", "author": "agent", "comment": "Check",
            "context_before": before, "target": target, "created": "2026-01-01T00:00:00Z", "resolved": false,
        ]
    }

    /// Whether the preview marks `text` as the target of an annotation.
    func previewHighlights(_ text: String) async -> Bool {
        await until(seconds: 8) {
            let shown = self.previewText as NSString
            return self.previewView.ranges.values.contains { $0.upperBound <= shown.length && shown.substring(with: $0) == text }
        }
    }

    /// A key press, as the window would deliver it.
    func keyEvent(_ characters: String, _ modifiers: NSEvent.ModifierFlags, code: UInt16, in win: EditorWindowController? = nil) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: (win ?? controller!).window?.windowNumber ?? 0, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    /// Presses the button titled `title` on the sheet over the window.
    func pressSheetButton(_ title: String) {
        func find(_ view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap(find).first
        }
        guard let sheet = controller.window?.attachedSheet, let content = sheet.contentView else { return }
        find(content)?.performClick(nil)
    }

    /// A click on a native view, delivered to it.
    func click(_ view: NSView) {
        let point = view.convert(NSPoint(x: 20, y: 20), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        view.mouseDown(with: down)
    }

    /// Selects `length` characters of the preview from `start` characters into the first `needle`, as the reader would.
    func selectInPreview(_ needle: String, from start: Int = 0, length: Int) async {
        let at = (previewText as NSString).range(of: needle)
        guard at.location != NSNotFound else { return }
        controller.window?.makeFirstResponder(previewView.textView)
        previewView.textView.setSelectedRange(NSRange(location: at.location + start, length: length))
    }

    func finish() -> Bool {
        for folder in dirs { try? FileManager.default.removeItem(at: folder) }
        print(failures == 0 ? "ALL CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        return failures == 0
    }

    // MARK: the native annotation UI

    var pane: AnnotationController { controller.annotations }

    /// The native source editor of the first window, and what is in it.
    var sourceView: SourceEditorView { controller.scrollHost.source }
    var sourceText: String { sourceView.textView.string }

    /// The cards that are in the window: in the comments pane, with a size, inside it from side to side.
    /// Where they are down the page is where their text is, and may be below the fold.
    func visibleCards(in win: EditorWindowController? = nil) -> [AnnotationCardView] {
        let target = win ?? controller!
        let host = target.scrollHost
        return target.annotations.cards.values.filter { card in
            guard card.window != nil, !card.isHidden, card.frame.width > 200, card.frame.height > 20 else { return false }
            let rect = host.convert(card.bounds, from: card)
            return rect.minX >= 0 && rect.maxX <= host.bounds.width + 1
        }
    }

    /// The button with this accessibility identifier, somewhere below `view`.
    func button(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews { if let found = button(id, in: sub) { return found } }
        return nil
    }

    /// Clicks a button of an annotation's card the way a reader does.
    func press(_ id: String, inCardOf annotationID: String?, in win: EditorWindowController? = nil) {
        let target = win ?? controller!
        guard let annotationID, let card = target.annotations.cards[annotationID], let found = button(id, in: card) else {
            print("    no \(id) button in the card of \(annotationID ?? "nil")")
            return
        }
        (found as? NSControl)?.performClick(nil)
    }

    // MARK: the folio CLI

    /// `folio` built from this checkout (or FOLIO_CLI), run from the document's folder
    /// the way an agent would.
    func cli(_ arguments: [String], in folder: URL? = nil) -> (status: Int32, output: String) {
        let binary = ProcessInfo.processInfo.environment["FOLIO_CLI"]
            ?? AppConfig.dist.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("target/debug/folio").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = folder ?? dir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func pendingFromCLI() -> Int {
        let result = cli(["review", name, "--json"])
        guard result.status == 0,
              let list = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [Any] else { return -1 }
        return list.count
    }

    // MARK: helpers

    /// A menu action, sent down the window's responder chain from what has the keyboard (the text,
    /// a card's field), then to the app. Not through the key window: that is nil while another
    /// app has the focus, and the action would be lost.
    func send(_ action: String) {
        let selector = Selector((action))
        if controller.window?.firstResponder?.tryToPerform(selector, with: nil) == true { return }
        if controller.window?.tryToPerform(selector, with: nil) == true { return }
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    func check(_ name: String, _ body: () async -> Bool) async {
        report(name, await body())
    }

    func report(_ name: String, _ ok: Bool) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name)")
    }

    func until(seconds: Double = 10, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await condition()
    }
}
