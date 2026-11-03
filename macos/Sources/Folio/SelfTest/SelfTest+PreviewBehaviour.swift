import AppKit
import FolioKit

/// What the preview does besides showing the text: Find, the card that opens next to the
/// text, the scroll position across the source and across a set's files.
extension SelfTest {
    func previewBehaviourChecks() async {
        let textView = previewView.textView
        let host = controller.scrollHost
        replaceSidecar([])
        replaceFile((try? String(contentsOf: source, encoding: .utf8)) ?? "")
        _ = await until { self.previewText.contains("The last paragraph.") && self.controller.currentStore.pending.isEmpty }

        await darkDiagramChecks()

        // Find: the Edit menu focuses the toolbar's search field, Return selects the next match.
        let find = NSApp.mainMenu?.items.compactMap(\.submenu).first { $0.title == "Edit" }?.item(withTitle: "Find…")
        if let find, let action = find.action { send(NSStringFromSelector(action)) }
        controller.findItem.searchField.stringValue = "last paragraph"
        controller.findNext(nil)
        await check("Find selects the match in the preview") {
            await self.until { (self.previewText as NSString).substring(with: textView.selectedRange()) == "last paragraph" }
        }
        controller.findItem.searchField.stringValue = "zzz-not-there"
        controller.findNext(nil)
        await check("Find leaves the selection alone when there is no match") {
            (self.previewText as NSString).substring(with: textView.selectedRange()) == "last paragraph"
        }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        // The preview of a suggestion is not in the file, so Find does not stop on it.
        _ = cli(["annotate", name, "--kind", "replace", "--context-before", "vineyard and the ", "--target", "cellar",
                 "--replacement", "zzghost", "--author", "agent", "--source", "agent"])
        _ = await until { self.previewText.contains("cellarzzghost") }
        await check("Find skips the text of a suggestion's preview") {
            !self.previewView.find("zzghost", backwards: false) && self.previewView.find("cellar", backwards: false)
        }
        replaceSidecar([])
        _ = await until { !self.previewText.contains("zzghost") }
        // A suggestion of several paragraphs stays in the text column: every paragraph of it is indented like the one it goes into.
        _ = cli(["annotate", name, "--kind", "replace", "--context-before", "vineyard and the ", "--target", "cellar",
                 "--replacement", "zzfirst\n\nzzsecond\n\nzzthird", "--author", "agent", "--source", "agent"])
        _ = await until { self.previewText.contains("zzthird") }
        await check("the paragraphs of a long suggestion are in the text column") {
            guard let storage = textView.textStorage else { return false }
            let text = storage.string as NSString
            func indent(_ word: String) -> CGFloat? {
                let found = text.range(of: word)
                guard found.location != NSNotFound else { return nil }
                return (storage.attribute(.paragraphStyle, at: found.location, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
            }
            guard let own = indent("Natural wine"), let second = indent("zzsecond"), let third = indent("zzthird") else { return false }
            return own > 0 && second == own && third == own
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-long-suggestion.png") }
        replaceSidecar([])
        _ = await until { !self.previewText.contains("zzthird") }
        textView.setSelectedRange(NSRange(location: 0, length: 0))

        // With the pane closed, clicking annotated text opens its card beside it; Esc closes it.
        _ = cli(["annotate", name, "--kind", "comment", "--context-before", "The last ", "--target", "paragraph",
                 "--comment", "Open card", "--author", "agent", "--source", "agent"])
        _ = await until { self.previewView.ranges.count == 1 }
        if pane.commentsOn {
            send("toggleComments:")
            _ = await until { !self.pane.commentsOn && host.paneWidth == 0 }
        }
        let range = (previewText as NSString).range(of: "paragraph")
        textView.onClick?(range.location + 2)
        await check("with the pane closed, a click on annotated text opens its card next to it") {
            guard let id = self.pane.focusedID, let card = self.pane.cards[id] else { return false }
            return card.isFloating && card.superview === host.floatingHost
        }
        await check("the open card is inside the visible part of the window") {
            guard let id = self.pane.focusedID, let card = self.pane.cards[id] else { return false }
            return host.visibleDocumentRect.contains(card.frame)
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] { await snapshot("\(base)-overlay.png") }
        _ = pane.handleKey(keyEvent("\u{1b}", [], code: 53))
        await check("Escape closes it") { self.pane.focusedID == nil }
        replaceSidecar([])
        _ = await until { self.controller.currentStore.pending.isEmpty }

        // The scroll position is kept across the source and back.
        let tail = (1...150).map { "Paragraph \($0) of the long file.\n\n" }.joined()
        replaceFile("# Long\n\n" + tail)
        var before = 0.0 as CGFloat
        await check("the long document scrolls in the window's scroll view") {
            let scrolled = await self.until(seconds: 10) {
                guard host.contentHeight > 1600 else { return false }
                host.contentView.scroll(to: NSPoint(x: 0, y: 1500))
                host.reflectScrolledClipView(host.contentView)
                before = host.scrollFraction
                return before > 0.3 && host.scrollOffset > 1000
            }
            if !scrolled { print("    height \(host.contentHeight), offset \(host.scrollOffset), fraction \(host.scrollFraction), text \(self.previewText.prefix(40))") }
            return scrolled
        }
        send("toggleSource:")
        _ = await until { self.controller.sourceOn }
        send("toggleSource:")
        _ = await until { !self.controller.sourceOn && !self.previewView.isHidden }
        await check("the scroll position survives a visit to the source") {
            await self.until(seconds: 4) { abs(host.scrollFraction - before) < 0.1 }
        }
        host.contentView.scroll(to: .zero)
        host.reflectScrolledClipView(host.contentView)
        replaceFile((try? String(contentsOf: source, encoding: .utf8)) ?? "")
        await setChecksPreview()
    }

    /// Diagrams are drawn for the look the window has, and again when it changes.
    private func darkDiagramChecks() async {
        func background(_ image: NSImage?) -> CGFloat? {
            guard let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB)?.brightnessComponent
        }
        controller.window?.appearance = NSAppearance(named: .aqua)
        _ = await until(seconds: 20) { background(self.previewView.picture("mermaid:")).map { $0 > 0.8 } ?? false }
        await check("a diagram is drawn light in a light window") { background(self.previewView.picture("mermaid:")).map { $0 > 0.8 } ?? false }
        controller.window?.appearance = NSAppearance(named: .darkAqua)
        await check("and drawn again, dark, when the window turns dark") {
            await self.until(seconds: 20) { background(self.previewView.picture("mermaid:")).map { $0 < 0.3 } ?? false }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            controller.scrollHost.contentView.scroll(to: .zero)
            controller.scrollHost.reflectScrolledClipView(controller.scrollHost.contentView)
            await snapshot("\(base)-dark.png")
        }
        controller.window?.appearance = nil
    }

    /// A set's window on the preview: the sidebar switches the file shown, in place, and each file keeps its place.
    private func setChecksPreview() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }
        guard let alpha = try? tempCopy(named: "alpha.md"), let beta = try? tempCopy(named: "beta.md") else {
            report("set files are created", false)
            return
        }
        let tail = (1...150).map { "Paragraph \($0) of the long file.\n\n" }.joined()
        try? ("BETA MARKER\n\n" + tail).write(to: beta, atomically: false, encoding: .utf8)
        do { try Rust.setAdd("preview", files: [alpha, beta]) } catch {
            report("the set is created: \(error)", false)
            return
        }
        guard let win = app.openSet("preview") else {
            report("the set opens on the preview", false)
            return
        }
        let preview = win.scrollHost.preview
        let alphaID = win.sidebar.fileIDs[0], betaID = win.sidebar.fileIDs[1]
        await check("the set opens on its first file, in the preview") {
            await self.until { preview.window != nil && preview.textView.string.contains("The last paragraph.") }
        }
        win.sidebar.choose(betaID)
        await check("choosing a file in the sidebar shows it in place") {
            await self.until { preview.textView.string.hasPrefix("BETA MARKER") && win.currentID == betaID }
        }
        let host = win.scrollHost
        var scrolled = 0.0
        await check("the long file scrolls") {
            await self.until(seconds: 10) {
                guard host.contentHeight > 1600 else { return false }
                host.contentView.scroll(to: NSPoint(x: 0, y: 1500))
                host.reflectScrolledClipView(host.contentView)
                scrolled = host.scrollOffset
                return scrolled > 1000
            }
        }
        win.sidebar.choose(alphaID)
        await check("another file starts at the top, with its own text") {
            await self.until { preview.textView.string.contains("The last paragraph.") && host.scrollOffset == 0 }
        }
        win.sidebar.choose(betaID)
        await check("coming back restores the scroll position") {
            await self.until { preview.textView.string.hasPrefix("BETA MARKER") && abs(host.scrollOffset - scrolled) < 80 }
        }
        // An annotation made on the file on screen goes to its own sidecar.
        _ = cli(["annotate", beta.lastPathComponent, "--kind", "comment", "--context-before", "BETA MARKER", "--target", "Paragraph 1",
                 "--comment", "In beta", "--author", "agent", "--source", "agent"], in: beta.deletingLastPathComponent())
        await check("an annotation of the file on screen is anchored there") {
            await self.until(seconds: 8) { win.annotations.anchors.count == 1 && preview.ranges.count == 1 }
        }
        win.window?.close()
    }
}
