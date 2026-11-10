import AppKit
import FolioKit

/// A set with a folder in it (docs/wiki-mode.md, step 1): its markdown files are listed as a
/// tree and the list follows files added, renamed, changed and removed underneath.
extension SelfTest {
    func wikiScenario() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        let wiki = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-wiki-\(UUID().uuidString)").appendingPathComponent("payments")
            .resolvingSymlinksInPath()
        dirs.append(wiki.deletingLastPathComponent())
        func write(_ path: String, _ text: String) {
            let url = wiki.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        write("index.md", "# Index\n\nWIKI INDEX\n\nSee [[oauth]], [[research/rotation-options|the options]] and [[missing]], "
            + "or [Priya](folio://annotation/c3d4?repo=nowhere&branch=main&path=a.md).\n\nThen [[oauth#Second part]].\n")
        write("research/oauth.md", "# OAuth\n\nNotes.\n\n## Second part\n\nMore notes.\n")
        write(".obsidian/workspace.md", "hidden\n")
        write("notes.txt", "not markdown\n")

        let added = cli(["set", "add", "wiki", "--folder", wiki.path], in: wiki)
        await check("folio set add --folder succeeds") { added.status == 0 }
        guard let win = app.openSet("wiki") else {
            report("a set with only a folder opens", false)
            return
        }
        let sidebar = win.sidebar

        await check("the folder's markdown files are listed under its name, hidden folders and other files left out") {
            sidebar.headerTitles == ["payments"] && sidebar.fileNames == ["index.md", "oauth.md"]
        }
        await check("a subfolder gets a heading") { sidebar.folderTitles == ["research"] }
        sidebar.toggleFolder(named: "research")
        await check("clicking a subfolder folds its files away and keeps its heading") {
            sidebar.fileNames == ["index.md"] && sidebar.folderTitles == ["research"] && sidebar.collapsedTitles == ["research"]
        }
        sidebar.toggleFolder(named: "research")
        await check("and clicking it again unfolds them") { sidebar.fileNames == ["index.md", "oauth.md"] && sidebar.collapsedTitles.isEmpty }
        sidebar.toggleFolder(named: "payments")
        await check("clicking the folder's heading folds the whole folder and keeps the heading") {
            sidebar.fileNames.isEmpty && sidebar.folderTitles.isEmpty && sidebar.headerTitles == ["payments"]
                && sidebar.collapsedTitles == ["payments"] && sidebar.selectedID == nil
        }
        sidebar.toggleFolder(named: "payments")
        await check("and clicking it again unfolds it, the page on screen highlighted") {
            sidebar.fileNames == ["index.md", "oauth.md"] && sidebar.selectedID == win.currentID
        }
        await check("the window opens on the folder's first file") {
            await self.until { win.scrollHost.preview.textView.string.contains("WIKI INDEX") }
        }

        // Links in a wiki page: a page that is there is live, one that is not is grey with the reason.
        let preview = win.scrollHost.preview
        func attributes(_ word: String) -> (link: URL?, color: NSColor?, tip: String?) {
            let storage = preview.textView.textStorage!
            let at = (storage.string as NSString).range(of: word).location
            guard at != NSNotFound else { return (nil, nil, nil) }
            return (storage.attribute(.folioLink, at: at, effectiveRange: nil) as? URL,
                    storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor,
                    storage.attribute(.toolTip, at: at, effectiveRange: nil) as? String)
        }
        await check("the page shows each [[link]] as what it names, without the brackets") {
            let text = preview.textView.string
            return text.contains("See oauth, the options and missing, or Priya") && !text.contains("[[")
        }
        await check("a link to a page the wiki has is in the link colour") {
            attributes("oauth").link != nil && attributes("oauth").color == .linkColor && attributes("oauth").tip == nil
        }
        await check("a link to a page it lacks is grey, saying why") {
            attributes("missing").color == .secondaryLabelColor && attributes("missing").tip == "“missing” isn't in the wiki"
                && attributes("the options").color == .secondaryLabelColor
        }
        await check("a link to an annotation of a repo no window has is grey, saying why") {
            attributes("Priya").color == .secondaryLabelColor && attributes("Priya").tip == "nowhere isn't in an open set"
        }
        let indexID = win.currentID
        let storage = preview.textView.textStorage!
        func click(_ word: String) {
            preview.textView.onClick?((storage.string as NSString).range(of: word).location + 1)
        }
        click("missing")
        click("Priya")
        try? await Task.sleep(nanoseconds: 300_000_000)
        await check("clicking a grey link does nothing") { win.currentID == indexID }
        sidebar.toggleFolder(named: "research")
        click("oauth")
        await check("clicking a live link opens the page in the window") {
            await self.until { win.currentID != indexID && win.window?.subtitle == "research/oauth.md" }
        }
        await check("a page opened in a folded folder unfolds it and is highlighted") {
            sidebar.collapsedTitles.isEmpty && sidebar.selectedID == win.currentID
        }
        sidebar.toggleFolder(named: "research")
        await check("folding the folder of the page on screen keeps the page, with no row highlighted") {
            sidebar.fileNames == ["index.md"] && sidebar.selectedID == nil && win.window?.subtitle == "research/oauth.md"
        }
        sidebar.toggleFolder(named: "research")
        await check("unfolding it highlights the page again") { sidebar.selectedID == win.currentID }
        sidebar.choose(indexID)
        await check("and back") { await self.until { win.currentID == indexID && preview.textView.string.contains("WIKI INDEX") } }
        click("oauth › Second part")
        await check("a link with a heading opens the page with the heading selected") {
            await self.until {
                let page = win.scrollHost.preview.textView
                return win.currentID != indexID && (page.string as NSString).substring(with: page.selectedRange()) == "Second part"
            }
        }
        sidebar.choose(indexID)
        _ = await until { win.currentID == indexID && preview.textView.string.contains("WIKI INDEX") }
        // A page that comes to the wiki brings its links to life without a reload.
        write("missing.md", "# Missing\n\nNot any more.\n")
        await check("a page added to the wiki makes the link to it live") {
            await self.until(seconds: 3) { attributes("missing").color == .linkColor && attributes("missing").tip == nil }
        }
        await check("the others stay as they were") {
            attributes("the options").color == .secondaryLabelColor && attributes("oauth").color == .linkColor
        }
        try? FileManager.default.removeItem(at: wiki.appendingPathComponent("missing.md"))
        await check("and a page that goes makes it grey again") {
            await self.until(seconds: 3) { attributes("missing").color == .secondaryLabelColor }
        }

        // A file added underneath shows up without a reload, marked new, and the sidebar says so.
        write("research/rotation.md", "# Rotation\n\nROTATION NOTES\n")
        await check("a file added underneath shows in the sidebar within a second or two") {
            await self.until(seconds: 3) { sidebar.fileNames == ["index.md", "oauth.md", "rotation.md"] }
        }
        let rotationID = win.workspace.entries.first { $0.name.hasSuffix("rotation.md") }?.document.id ?? ""
        await check("it is marked new") { win.marks[rotationID] == .new }
        await check("the sidebar notice says it was added") { sidebar.noticeText?.contains("rotation.md added") == true }

        // A file changed while another is shown gets its dot; showing it clears the mark.
        let oauthID = win.workspace.entries.first { $0.name.hasSuffix("oauth.md") }?.document.id ?? ""
        write("research/oauth.md", "# OAuth\n\nOAUTH CHANGED\n")
        await check("a file changed underneath while another is shown is marked changed") {
            await self.until(seconds: 3) { win.marks[oauthID] == .changed }
        }
        sidebar.choose(oauthID)
        await check("showing it shows the new text and clears its mark") {
            await self.until { win.scrollHost.preview.textView.string.contains("OAUTH CHANGED") && win.marks[oauthID] == nil }
        }

        // A rename is the old name going and the new one coming.
        try? FileManager.default.moveItem(at: wiki.appendingPathComponent("research/rotation.md"),
                                          to: wiki.appendingPathComponent("research/rotation-options.md"))
        await check("a file renamed underneath shows under its new name") {
            await self.until(seconds: 3) { sidebar.fileNames == ["index.md", "oauth.md", "rotation-options.md"] }
        }
        await check("the old name's mark goes with it") { win.marks[rotationID] == nil }

        // The file on screen removed underneath: the window moves to another file.
        try? FileManager.default.removeItem(at: wiki.appendingPathComponent("research/oauth.md"))
        await check("removing the open file underneath moves the window to another file") {
            await self.until(seconds: 3) { sidebar.fileNames == ["index.md", "rotation-options.md"] && win.currentID != oauthID }
        }
        await check("files of a folder cannot be removed from the set one by one") {
            let before = sidebar.fileIDs
            await withCheckedContinuation { continuation in win.remove(before[0]) { continuation.resume() } }
            return sidebar.fileIDs == before
        }

        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            write("research/vendor-sdk.md", "# Vendor SDK\n")
            _ = await until(seconds: 3) { sidebar.fileNames.count == 3 }
            await snapshot("\(base)-wiki.png", of: win)
        }

        win.performDeleteSet()
        await check("deleting the set leaves the folder's files") {
            FileManager.default.fileExists(atPath: wiki.appendingPathComponent("index.md").path)
        }
    }
}

/// The same file in a checkout and in its worktree (docs/wiki-mode.md, "Files under review, by repo
/// and branch"): one group per checkout, headed by repo and branch, each with its own annotations.
extension SelfTest {
    func worktreeScenario() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-worktrees-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(base)
        let main = base.appendingPathComponent("payments-svc"), linked = base.appendingPathComponent("payments-svc-logout")
        func write(_ url: URL, _ text: String) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        let gitDir = main.appendingPathComponent(".git/worktrees/logout")
        write(main.appendingPathComponent(".git/HEAD"), "ref: refs/heads/main\n")
        write(main.appendingPathComponent(".git/config"), "[remote \"origin\"]\n\turl = git@host:team/payments-svc.git\n")
        write(gitDir.appendingPathComponent("HEAD"), "ref: refs/heads/fix/logout\n")
        write(gitDir.appendingPathComponent("commondir"), "../..\n")
        write(linked.appendingPathComponent(".git"), "gitdir: \(gitDir.path)\n")
        let text = "# Token refresh\n\nWe rotate on every use of the token.\n"
        let mainFile = main.appendingPathComponent("docs/token-refresh.md"), linkedFile = linked.appendingPathComponent("docs/token-refresh.md")
        write(mainFile, text)
        write(linkedFile, text)

        let added = cli(["set", "add", "wt", mainFile.path, linkedFile.path], in: base)
        await check("a set takes the same file from a checkout and from its worktree") { added.status == 0 }
        guard let win = app.openSet("wt") else {
            report("a set of a checkout and its worktree opens", false)
            return
        }
        let sidebar = win.sidebar
        await check("each checkout is a group headed by repo and branch, the worktree saying so") {
            sidebar.headerTitles == ["payments-svc · main", "payments-svc · fix/logout · worktree"]
        }
        await check("both list the file by its path in the checkout") {
            sidebar.fileNames == ["docs/token-refresh.md", "docs/token-refresh.md"]
        }
        await check("the subtitle says the open file is also on the other branch") {
            win.window?.subtitle == "docs/token-refresh.md · also on fix/logout"
        }
        let ids = sidebar.fileIDs
        sidebar.choose(ids[1])
        await check("and the worktree's copy says it is also on main") {
            await self.until { win.window?.subtitle == "docs/token-refresh.md · also on main" }
        }

        // Each checkout has its own .folio, so an annotation belongs to one copy.
        let annotate = cli([
            "annotate", "token-refresh.md", "--kind", "comment", "--context-before", "We ", "--target", "rotate",
            "--comment", "check", "--author", "agent", "--source", "agent",
        ], in: linked.appendingPathComponent("docs"))
        await check("folio annotate in the worktree succeeds") { annotate.status == 0 }
        await check("only the worktree's copy has the badge") {
            await self.until { sidebar.badge(for: ids[1]) == 1 } && sidebar.badge(for: ids[0]) == 0
        }

        // Links name repo, branch and path, so each finds its own copy, whichever file is open.
        let annotated = cli(["review", "token-refresh.md", "--json"], in: linked.appendingPathComponent("docs"))
        let annotationID = (try? JSONSerialization.jsonObject(with: Data(annotated.output.utf8)) as? [[String: Any]])?.first?["id"] as? String ?? ""
        func link(_ arguments: [String], in folder: URL) -> FolioLink? {
            URL(string: cli(["link", "token-refresh.md"] + arguments, in: folder).output.trimmingCharacters(in: .whitespacesAndNewlines))
                .flatMap(FolioLink.init)
        }
        let toAnnotation = link([annotationID], in: linked.appendingPathComponent("docs"))
        await check("folio link names the repo, branch and path of the worktree's copy") {
            toAnnotation?.repo == "payments-svc" && toAnnotation?.branch == "fix/logout" && toAnnotation?.path == "docs/token-refresh.md"
        }
        sidebar.choose(ids[0])
        _ = await until { win.currentID == ids[0] }
        if let toAnnotation { AppServer.open(toAnnotation) }
        await check("following it shows the worktree's copy and focuses the annotation") {
            await self.until { win.currentID == ids[1] && win.annotations.focusedID == annotationID }
        }
        if let toPassage = link(["--passage", "rotate on every use"], in: main.appendingPathComponent("docs")) {
            AppServer.open(toPassage)
        }
        await check("a link to a passage on main shows main's copy with the text selected") {
            await self.until {
                let preview = win.scrollHost.preview.textView
                return win.currentID == ids[0]
                    && (preview.string as NSString).substring(with: preview.selectedRange()) == "rotate on every use"
            }
        }
        var told: [String] = []
        let tellBefore = AppServer.tell
        AppServer.tell = { told.append($0) }
        if let gone = URL(string: "folio://annotation/x?repo=payments-svc&branch=fix/gone&path=docs/token-refresh.md").flatMap(FolioLink.init) {
            AppServer.open(gone)
        }
        if let missing = URL(string: "folio://annotation/x?repo=payments-svc&branch=main&path=docs/nope.md").flatMap(FolioLink.init) {
            AppServer.open(missing)
        }
        AppServer.tell = tellBefore
        await check("a link to a branch no checkout is on says so, and so does one to a file it lacks") {
            told == ["fix/gone isn't checked out any more", "docs/nope.md isn't in this checkout"] && win.currentID == ids[0]
        }

        // `git checkout` in the worktree: the heading and the subtitle follow without a reload.
        write(gitDir.appendingPathComponent("HEAD"), "ref: refs/heads/fix/login\n")
        await check("switching the worktree's branch changes its heading") {
            await self.until(seconds: 3) { sidebar.headerTitles == ["payments-svc · main", "payments-svc · fix/login · worktree"] }
        }
        await check("and the other copy's subtitle") {
            sidebar.choose(ids[0])
            return await self.until { win.window?.subtitle == "docs/token-refresh.md · also on fix/login" }
        }

        win.performDeleteSet()
        await check("deleting the set leaves both copies") {
            FileManager.default.fileExists(atPath: mainFile.path) && FileManager.default.fileExists(atPath: linkedFile.path)
        }
    }
}

/// Wiki pages that link to an annotation are listed on its card (docs/wiki-mode.md, "Backlinks").
extension SelfTest {
    func backlinkScenario() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        guard let spec = try? tempCopy(named: "spec.md") else {
            report("a file under review is created", false)
            return
        }
        let repo = spec.deletingLastPathComponent()
        let annotate = cli([
            "annotate", "spec.md", "--kind", "comment", "--context-before", "Natural wine is made with ",
            "--target", "minimal intervention", "--comment", "check", "--author", "agent", "--source", "agent",
        ], in: repo)
        let review = cli(["review", "spec.md", "--json"], in: repo)
        let id = (try? JSONSerialization.jsonObject(with: Data(review.output.utf8)) as? [[String: Any]])?.first?["id"] as? String ?? ""
        let toAnnotation = cli(["link", "spec.md", id, "--markdown"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let toPassage = cli(["link", "spec.md", "--passage", "minimal intervention", "--markdown"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        await check("folio annotate and folio link make the links a wiki page holds") {
            annotate.status == 0 && !id.isEmpty && toAnnotation.hasPrefix("[") && toPassage.contains("folio://passage?")
        }

        let wiki = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-backlinks-\(UUID().uuidString)").appendingPathComponent("notes").resolvingSymlinksInPath()
        dirs.append(wiki.deletingLastPathComponent())
        func write(_ text: String) {
            try? FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
            try? text.write(to: wiki.appendingPathComponent("review.md"), atomically: true, encoding: .utf8)
        }
        let page = "# Review notes\n\n## T3 · Token replay\n\nAsked about \(toAnnotation) twice.\n\n## T4 · Brute force\n\nSee also \(toPassage).\n"
        write(page)
        let added = cli(["set", "add", "backlinks", spec.path, "--folder", wiki.path], in: repo)
        await check("a set takes the file under review and the wiki folder") { added.status == 0 }
        guard let win = app.openSet("backlinks") else {
            report("the set opens", false)
            return
        }
        let reviewID = win.currentID
        func card() -> AnnotationCardView? { win.annotations.cards[id] }

        await check("the card says how many wiki pages link to it") {
            await self.until { card()?.referenceTexts == ["2 references"] }
        }
        await check("in focus it lists them, each by page and where in it") {
            _ = await self.until { win.annotations.reveal(annotation: id) }
            return await self.until {
                card()?.referenceTexts == ["REFERENCED IN", "review.md", "T3 · Token replay", "review.md", "T4 · Brute force"]
            }
        }
        await check("the rows are inside the card, below the thread, and the reply field below them") {
            guard let card = card(), let rows = Optional(card.referenceFrames), rows.count == 5 else { return false }
            let reply = card.replyBox.frame
            return rows.allSatisfy { $0.minX >= 0 && $0.maxX <= card.bounds.width && $0.maxY <= card.bounds.height && $0.maxY <= reply.minY + 0.5 }
                && rows.first.map { $0.minY > 40 } == true
        }
        card()?.openReference(at: 0)
        await check("clicking one opens the page with the words of the link selected") {
            await self.until {
                let preview = win.scrollHost.preview.textView
                return win.currentID != reviewID && (preview.string as NSString).substring(with: preview.selectedRange()) == "\(toAnnotation.dropFirst().prefix { $0 != "]" })"
            }
        }

        // Back on the file under review: a link taken out of the page is taken off the card.
        win.sidebar.choose(reviewID)
        _ = await until { win.currentID == reviewID && card() != nil }
        write("# Review notes\n\n## T4 · Brute force\n\nSee also \(toPassage).\n")
        await check("a link taken out of a page leaves the card within a moment") {
            await self.until(seconds: 4) { card()?.referenceTexts == ["1 reference"] }
        }
        write("# Review notes\n\nNothing here any more.\n")
        await check("a page with no links to it leaves the card with none") {
            await self.until(seconds: 4) { card()?.referenceTexts == [] }
        }
        write(page)
        await check("and a link put back is listed again") {
            await self.until(seconds: 4) { card()?.referenceTexts == ["2 references"] }
        }

        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            win.toggleComments(nil)
            _ = await until { win.commentsOn }
            _ = win.annotations.reveal(annotation: id)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-backlinks.png", of: win)
            win.toggleComments(nil)
        }

        // A link whose annotation is resolved, or whose passage is edited away, is grey and says why.
        let pageID = win.workspace.entries.first { $0.name == "review.md" }?.document.id ?? ""
        win.openFile(pageID)
        let preview = win.scrollHost.preview
        func link(_ markdown: String) -> (color: NSColor?, tip: String?) {
            let label = String(markdown.dropFirst().prefix { $0 != "]" })
            let storage = preview.textView.textStorage!
            let at = (storage.string as NSString).range(of: label).location
            guard at != NSNotFound else { return (nil, "no such text") }
            return (storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor,
                    storage.attribute(.toolTip, at: at, effectiveRange: nil) as? String)
        }
        await check("while their targets are there, the links to an annotation and a passage are live") {
            await self.until { win.currentID == pageID && link(toAnnotation).tip == nil && link(toPassage).tip == nil && link(toAnnotation).color != nil }
        }
        let rejected = cli(["reject", "spec.md", id], in: repo)
        await check("an annotation resolved underneath greys its link, saying it is not found") {
            await self.until(seconds: 4) {
                rejected.status == 0 && link(toAnnotation).tip == "Not found in spec.md" && link(toAnnotation).color == .secondaryLabelColor
                    && link(toPassage).tip == nil
            }
        }
        let specText = (try? String(contentsOf: spec, encoding: .utf8)) ?? ""
        try? specText.replacingOccurrences(of: "minimal intervention", with: "little intervention").write(to: spec, atomically: true, encoding: .utf8)
        await check("a passage edited away greys its link") {
            await self.until(seconds: 4) { link(toPassage).tip == "Not found in spec.md" && link(toPassage).color == .secondaryLabelColor }
        }
        try? specText.write(to: spec, atomically: true, encoding: .utf8)
        await check("and the text put back makes it live again") {
            await self.until(seconds: 4) { link(toPassage).tip == nil }
        }

        win.performDeleteSet()
        await check("deleting the set leaves the page and the file") {
            FileManager.default.fileExists(atPath: wiki.appendingPathComponent("review.md").path) && FileManager.default.fileExists(atPath: spec.path)
        }
    }
}

/// The Open list: the open items of every file of a set (docs/wiki-mode.md, "Open items").
extension SelfTest {
    func openItemsScenario() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        let wiki = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-open-\(UUID().uuidString)").appendingPathComponent("tracker").resolvingSymlinksInPath()
        dirs.append(wiki.deletingLastPathComponent())
        func write(_ name: String, _ text: String) {
            try? FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
            try? text.write(to: wiki.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func disk(_ name: String) -> String { (try? String(contentsOf: wiki.appendingPathComponent(name), encoding: .utf8)) ?? "" }
        let mr = "https://github.com/team/svc/pull/42#issuecomment-981"
        let tasks = "# Tasks\n\n- [ ] Key rotation: asked in review #waiting \(mr)\n- [ ] Rate limit for unauthenticated refresh #waiting https://github.com/team/svc/pull/318\n"
            + "- [ ] Token refresh on logout from a second device #investigate\n- [ ] Rotation answered #replied https://github.com/team/svc/pull/42#issuecomment-990\n"
            + "  - Sam: the family is revoked by the gateway since v3\n- [ ] A plain task without a tag\n- [x] Done already #waiting\n"
        write("tasks.md", tasks)
        write("other.md", "- [ ] Compare options #investigate\n")
        let added = cli(["set", "add", "tracker", "--folder", wiki.path], in: wiki)
        await check("a set takes the folder with the tasks") { added.status == 0 }
        guard let win = app.openSet("tracker") else {
            report("the set opens", false)
            return
        }
        let sidebar = win.sidebar, list = win.openList

        await check("items tagged #waiting, #investigate and #replied are open; plain and ticked ones are not") {
            sidebar.openRowCount == 5 && win.openEntries.count == 5
        }
        await check("the window opens on a file, not on the list") { !win.openListShown && !win.scrollHost.isHidden }

        sidebar.chooseOpenList()
        await check("choosing the Open row shows the list in place of the editor") {
            win.openListShown && win.scrollHost.isHidden && !list.isHidden && sidebar.openRowSelected && win.window?.subtitle == "Open items"
        }
        await check("it is grouped by tag: replied first, then waiting, then investigate") {
            list.groupTitles == ["Replied", "Waiting", "Investigate"]
        }
        await check("each row has the item's words, and the nested line as its answer") {
            list.rowTexts == [
                "Rotation answered\nSam: the family is revoked by the gateway since v3",
                "Key rotation: asked in review", "Rate limit for unauthenticated refresh",
                "Compare options", "Token refresh on logout from a second device",
            ]
        }
        await check("and where it is, and the address it waits on") {
            list.rowPlaces == ["tasks.md:6", "tasks.md:3", "tasks.md:4", "other.md:1", "tasks.md:5"]
                && list.rowAddresses[1] == "github.com · pull/42" && list.rowAddresses[2] == "github.com · pull/318"
                && list.rowAddresses[3] == nil
        }
        list.grouping = .file
        await check("by file it is the files, in the order of the sidebar") {
            list.groupTitles == ["other.md", "tasks.md"]
        }
        list.grouping = .tag

        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 600_000_000)
            await snapshot("\(base)-open.png", of: win)
        }

        // Ticking writes the file.
        list.tick(row: 1)
        await check("ticking an item writes [x] in its file and nowhere else") {
            await self.until {
                let text = disk("tasks.md")
                return text.contains("- [x] Key rotation: asked in review #waiting") && text.contains("- [ ] Rate limit for unauthenticated refresh #waiting")
                    && text.contains("- [x] Done already #waiting")
            }
        }
        await check("the list and the count lose it") {
            await self.until { sidebar.openRowCount == 4 && list.rowPlaces == ["tasks.md:6", "tasks.md:4", "other.md:1", "tasks.md:5"] }
        }

        // An item that is not on its line any more is not ticked: the file changed under the list.
        let staleEntry = win.openEntries.first { $0.item.text == "Rate limit for unauthenticated refresh" }
        write("tasks.md", "- [ ] Something new on the first line #investigate\n" + disk("tasks.md"))
        if let staleEntry { win.openList.onTick(staleEntry) }
        await check("an item that moved is not ticked in the place it was") {
            let text = disk("tasks.md")
            return text.contains("- [ ] Something new on the first line #investigate") && text.contains("- [ ] Rate limit for unauthenticated refresh #waiting")
                && !text.contains("- [x] Something new")
        }
        await check("and the list reads the file again") {
            await self.until(seconds: 4) { sidebar.openRowCount == 5 && list.rowTexts.contains("Something new on the first line") }
        }

        // Clicking where an item is opens the file.
        list.open(row: list.rowPlaces.firstIndex(of: "other.md:1") ?? 0)
        await check("clicking where an item is opens its file and leaves the list") {
            await self.until { !win.openListShown && !win.scrollHost.isHidden && win.window?.subtitle == "other.md" }
        }
        await check("the Open row stays, with its count") { sidebar.openRowCount == 5 && !sidebar.openRowSelected }
        sidebar.chooseOpenList()
        _ = await until { win.openListShown }
        let otherID = win.workspace.entries.first { $0.name == "other.md" }?.document.id ?? ""
        sidebar.choose(otherID)
        await check("picking a file in the sidebar goes back to the editor") {
            await self.until { !win.openListShown && !win.scrollHost.isHidden }
        }

        // Files change underneath: the count and the list follow without a reload.
        write("other.md", "- [ ] Compare options #investigate\n- [ ] Ask Anna about key rotation #waiting\n")
        await check("an item added to a file shows in the count within a moment") {
            await self.until(seconds: 4) { sidebar.openRowCount == 6 }
        }
        sidebar.chooseOpenList()
        _ = await until { win.openListShown }
        write("tasks.md", "# Tasks\n\nNothing tagged now.\n")
        write("other.md", "# Other\n")
        await check("with no open items left the Open row goes and the list gives way to the editor") {
            await self.until(seconds: 4) { sidebar.openRowCount == nil && !win.openListShown && !win.scrollHost.isHidden }
        }

        win.performDeleteSet()
        await check("deleting the set leaves the files") { FileManager.default.fileExists(atPath: wiki.appendingPathComponent("tasks.md").path) }
    }
}

/// An open item that links to an annotation is on that annotation's card, with a box to tick.
extension SelfTest {
    func cardItemsScenario() async {
        let config = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-config-\(UUID().uuidString)").resolvingSymlinksInPath()
        dirs.append(config)
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        defer { unsetenv("FOLIO_CONFIG_DIR") }

        guard let spec = try? tempCopy(named: "spec.md") else {
            report("a file under review is created", false)
            return
        }
        let repo = spec.deletingLastPathComponent()
        _ = cli([
            "annotate", "spec.md", "--kind", "comment", "--context-before", "Natural wine is made with ",
            "--target", "minimal intervention", "--comment", "check", "--author", "agent", "--source", "agent",
        ], in: repo)
        let review = cli(["review", "spec.md", "--json"], in: repo)
        let id = (try? JSONSerialization.jsonObject(with: Data(review.output.utf8)) as? [[String: Any]])?.first?["id"] as? String ?? ""
        let link = cli(["link", "spec.md", id, "--markdown"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)

        let wiki = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-selftest-carditems-\(UUID().uuidString)").appendingPathComponent("notes").resolvingSymlinksInPath()
        dirs.append(wiki.deletingLastPathComponent())
        func write(_ text: String) {
            try? FileManager.default.createDirectory(at: wiki, withIntermediateDirectories: true)
            try? text.write(to: wiki.appendingPathComponent("tracker.md"), atomically: true, encoding: .utf8)
        }
        func disk() -> String { (try? String(contentsOf: wiki.appendingPathComponent("tracker.md"), encoding: .utf8)) ?? "" }
        let item = "- [ ] Key rotation, asked in PR 42 #waiting https://github.com/t/s/pull/42 \(link)\n  - Sam: revoked by the gateway\n"
        // A link to the whole document, at the end so the items keep their lines.
        let toDocument = cli(["link", "spec.md", "--markdown"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let documentURL = cli(["link", "spec.md"], in: repo).output.trimmingCharacters(in: .whitespacesAndNewlines)
        write("# Tracker\n\n" + item + "- [ ] Not about this file #waiting\n\nSee \(toDocument).\n")
        _ = cli(["set", "add", "carditems", spec.path, "--folder", wiki.path], in: repo)
        guard let win = app.openSet("carditems") else {
            report("the set opens", false)
            return
        }
        func card() -> AnnotationCardView? { win.annotations.cards[id] }

        await check("the card counts the pages that link to it and the open items about it") {
            await self.until { card()?.referenceTexts == ["1 reference  ·  1 open"] }
        }
        await check("an item with no link to the annotation is not on its card") {
            _ = await self.until { win.annotations.reveal(annotation: id) }
            return await self.until { card()?.itemTexts == ["WAITING  Key rotation, asked in PR 42\nSam: revoked by the gateway"] }
        }
        await check("in focus the card lists the page and the item under their headings, the item with a box") {
            card()?.referenceTexts.first == "REFERENCED IN" && card()?.referenceTexts.count == 3 && card()?.itemTexts.count == 1
        }
        await check("the rows are inside the card and the reply field is below them") {
            guard let card = card() else { return false }
            let reply = card.replyBox.frame
            return card.referenceFrames.allSatisfy { $0.maxY <= reply.minY + 0.5 && $0.maxY <= card.bounds.height }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-card-items.png", of: win)
        }

        // The Open pane: the window's inspector, at the right beside the editor and its comments pane.
        let pane = win.openPane
        /// Where a view is across the window, so the editor and the pane (in different panes of the split) compare.
        func inWindow(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        let windowWidth = { win.window?.contentView?.bounds.width ?? 0 }
        await check("the Open pane starts closed, its button counting the set's items") {
            !win.openPaneOn && abs(inWindow(win.scrollHost).maxX - windowWidth()) < 0.5
                && win.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "openPane" })?.toolTip == "Open items (2)"
        }
        await check("its button is at the trailing edge, past a tracking separator on the pane's divider; the editor's stay before it") {
            let ids = win.window?.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
            let separator = win.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "openPaneSeparator" } as? NSTrackingSeparatorToolbarItem
            guard let at = ids.firstIndex(of: "openPaneSeparator"), let button = ids.firstIndex(of: "openPane"),
                  let find = ids.firstIndex(of: "find"), let comments = ids.firstIndex(of: "comments") else { return false }
            return separator?.dividerIndex == 1 && comments < at && find < at && at < button && button == ids.count - 1
        }
        let menuItem = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .first(where: { $0.action == #selector(SetWindowController.toggleOpenPane(_:)) })
        await check("View has Toggle Open Items with ⇧⌘O") {
            menuItem?.keyEquivalent == "o" && menuItem?.keyEquivalentModifierMask == [.command, .shift]
        }
        win.window?.makeKeyAndOrderFront(nil)
        NSApp.sendAction(#selector(SetWindowController.toggleOpenPane(_:)), to: nil, from: nil)
        await check("the menu's action opens the pane in the key set window") {
            await self.until { win.openPaneOn && !pane.isHidden && abs(pane.frame.width - OpenPaneView.width) < 0.5 }
        }
        if !win.commentsOn { win.toggleComments(nil) }
        await check("the editor narrows to make room, and the comments pane is open beside it") {
            await self.until {
                win.commentsOn && win.scrollHost.paneWidth > 300 && inWindow(win.scrollHost).maxX <= inWindow(pane).minX + 0.5
                    && inWindow(pane).minX - inWindow(win.scrollHost).maxX < 3 && abs(inWindow(pane).maxX - windowWidth()) < 0.5
            }
        }
        await check("it lists the whole set by default, by tag, the item about this file's annotation with a dot") {
            win.openScope == .set && pane.groupTitles == ["● WAITING"]
                && pane.rowTexts == ["Key rotation, asked in PR 42", "Not about this file"] && pane.rowMarked == [true, false]
        }
        await check("a row says where the item is and the address it waits on") {
            pane.rowPlaces.first == "tracker.md:3 · github.com · pull/42" && pane.rowPlaces.last == "tracker.md:5"
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-open-pane.png", of: win)
        }
        pane.choose(.file)
        await check("This file lists only the items whose link is to the file on screen") {
            win.openScope == .file && pane.rowTexts == ["Key rotation, asked in PR 42"]
        }
        let specID = win.currentID
        let trackerID = win.workspace.entries.first { $0.name == "tracker.md" }?.document.id ?? ""
        win.openFile(trackerID)
        await check("on another file it follows that file, and the scope stays") {
            await self.until { win.currentID == trackerID && pane.emptyText == "Nothing open about this file" && win.openScope == .file }
        }
        win.openFile(specID)
        _ = await until { win.currentID == specID && pane.rowTexts.count == 1 }
        pane.choose(.set)
        await check("Whole set lists every item again") { await self.until { pane.rowTexts.count == 2 } }

        // The References tab: the wiki pages that link to the file on screen, whatever the link points at.
        await check("the tabs say how many open items the set has and how many links point at this file") {
            await self.until { pane.tabTitles == ["Open 2", "References 2"] }
        }
        pane.choose(tab: .references)
        await check("References lists the page that links to this file, a row for the annotation and one for the document") {
            await self.until {
                win.paneTab == .references && !pane.scopeShown && pane.referenceTexts == [
                    "Tracker\nline 3 · an annotation", "Tracker\nline 7 · the document",
                ]
            }
        }
        if let base = ProcessInfo.processInfo.environment["FOLIO_SNAPSHOT"] {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await snapshot("\(base)-references-pane.png", of: win)
        }
        pane.open(reference: 1)
        await check("clicking a row opens the page") {
            await self.until { win.currentID == trackerID && win.paneTab == .references }
        }
        await check("and the tab follows the file on screen: nothing links to the page") {
            await self.until { pane.emptyText == "No page links to this file" && pane.referenceTexts.isEmpty }
        }
        if let url = URL(string: documentURL), let link = FolioLink(url) { AppServer.open(link) }
        await check("following the document link opens the file, and the tab lists its links again") {
            await self.until { win.currentID == specID && pane.referenceTexts.count == 2 }
        }
        pane.choose(tab: .open)
        await check("back on Open, the scope choice and the items are there") {
            await self.until { win.paneTab == .open && pane.scopeShown && pane.rowTexts.count == 2 }
        }
        // Back on the file, the annotation is focused again for the card's checks below.
        _ = await until { win.annotations.reveal(annotation: id) }

        // Comments Inline: the card in the text lists them too, and counts them when collapsed.
        let wasInline = AppConfig.commentsInline
        AppConfig.commentsInline = true
        if win.commentsOn { win.toggleComments(nil) } else { win.annotations.refreshMode() }
        _ = await until { win.annotations.reveal(annotation: id) }
        await check("an inline card in focus lists the page that links to it and the open item about it") {
            await self.until {
                card()?.isInline == true && card()?.referenceTexts.first == "REFERENCED IN"
                    && card()?.itemTexts.first?.hasPrefix("WAITING  Key rotation") == true
            }
        }
        win.annotations.collapseFocused()
        await check("collapsed, it counts them beside its header") {
            await self.until { card()?.isCollapsed == true && card()?.collapsedCountText == "·  1 reference  ·  1 open" }
        }
        win.annotations.setAllCollapsed(false)
        AppConfig.commentsInline = wasInline
        win.toggleComments(nil)
        _ = await until { win.commentsOn && win.annotations.reveal(annotation: id) }

        // The tag changes underneath (an agent found the answer): the card follows.
        write("# Tracker\n\n" + item.replacingOccurrences(of: "#waiting", with: "#replied") + "- [ ] Not about this file #waiting\n")
        await check("an answer written in the page shows on the card") {
            await self.until(seconds: 4) { card()?.itemTexts.first?.hasPrefix("REPLIED  Key rotation") == true }
        }

        card()?.tickItem(at: 0)
        await check("ticking the box on the card writes [x] in the page") {
            await self.until { disk().contains("- [x] Key rotation, asked in PR 42 #replied") && disk().contains("- [ ] Not about this file #waiting") }
        }
        await check("and the item leaves the card") {
            await self.until(seconds: 4) { card()?.itemTexts == [] }
        }
        await check("and the pane") { await self.until(seconds: 4) { pane.rowTexts == ["Not about this file"] } }

        pane.tick(row: 0)
        await check("ticking a row of the pane writes [x] in its page") {
            await self.until { disk().contains("- [x] Not about this file #waiting") }
        }
        await check("and the pane and its button follow") {
            await self.until(seconds: 4) {
                pane.emptyText == "No open items" && win.window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "openPane" })?.toolTip == "Open items"
            }
        }
        win.toggleOpenPane(nil)
        await check("closing the pane gives the editor its width back") {
            await self.until { !win.openPaneOn && abs(inWindow(win.scrollHost).maxX - windowWidth()) < 0.5 }
        }

        win.performDeleteSet()
        await check("deleting the set leaves the page") { FileManager.default.fileExists(atPath: wiki.appendingPathComponent("tracker.md").path) }
    }
}

