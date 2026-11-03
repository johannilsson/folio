import AppKit
import FolioKit

/// Claude's way into the app: the MCP server that the app's binary becomes with `--mcp`, started and
/// spoken to over its pipes as Claude desktop does, against the app that is running this test. The tools
/// that work on files are covered by `cargo test`; here it is that they reach this app: its windows, the
/// annotation the reader has focused, its annotations, and Folio ▸ Connect to MCP Clients…, which connects tools to it.
extension SelfTest {
    func mcpChecks() async {
        // A socket path has to be short (104 bytes), so not the temporary folder.
        let config = URL(fileURLWithPath: "/tmp/folio-mcp-\(UUID().uuidString.prefix(8))")
        do { try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true) } catch {
            report("the MCP config folder is created", false)
            return
        }
        dirs.append(config)
        let claudeConfig = config.appendingPathComponent("claude_desktop_config.json")
        setenv("FOLIO_CONFIG_DIR", config.path, 1)
        setenv("FOLIO_CLAUDE_CONFIG", claudeConfig.path, 1)
        setenv("CODEX_HOME", config.path, 1)
        defer {
            AppServer.stop()
            unsetenv("FOLIO_CONFIG_DIR")
            unsetenv("FOLIO_CLAUDE_CONFIG")
            unsetenv("CODEX_HOME")
        }

        // Folio ▸ Connect to MCP Clients…: one item for every tool, a window that shows what each needs, and
        // Add for Me only for the tools whose config Folio writes.
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        await check("Folio ▸ Connect to MCP Clients… is the app menu's one item for MCP tools") {
            let item = appMenu?.item(withTitle: "Connect to MCP Clients…")
            return item?.action == #selector(AppDelegate.connectTools(_:)) && item?.target === self.app
                && appMenu?.items.contains { $0.title == "MCP" || $0.title.hasPrefix("Connect to Claude") } == false
        }
        guard let snippets = try? AppServer.clientSnippets(), let exe = Bundle.main.executablePath else {
            report("the connect window gets what each tool needs", false)
            return
        }
        let alert = ConnectToolsAlert(snippets: snippets)
        let names = snippets.map(\.name)

        // MCP clients get in only once the person allows it: off at first, in the menu and in the window.
        let allowItem = appMenu?.item(withTitle: "Allow MCP Clients")
        func allowTicked() -> Bool {
            guard let allowItem else { return false }
            _ = self.app.validateMenuItem(allowItem)
            return allowItem.state == .on
        }
        await check("Allow MCP Clients is in the app menu, and off until the person turns it on") {
            allowItem?.action == #selector(AppDelegate.toggleMCP(_:)) && allowItem?.target === self.app
                && !allowTicked() && !Rust.mcpAllowed && !AppServer.serving && !alert.allowShown
        }
        let hello: [String: Any] = [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](), "clientInfo": ["name": "selftest", "version": "1"],
        ]
        guard let early = MCPClient(command: exe, arguments: ["--mcp"]) else {
            report("the server starts while access is off", false)
            return
        }
        _ = await early.call("initialize", hello)
        early.notify("notifications/initialized")
        let tooEarly = await early.tool("annotate", [
            "file": file.path,
            "annotations": [["kind": "comment", "context_before": "", "target": "The last paragraph.", "comment": "Too early"]],
        ])
        await check("while it is off, a client set up before still starts the server, but every tool says access is off and nothing is written") {
            let sidecar = (try? String(contentsOf: self.controller.files.sidecar, encoding: .utf8)) ?? ""
            return tooEarly?.isError == true && tooEarly?.text.contains("Allow MCP Clients") == true && !sidecar.contains("Too early")
        }
        alert.select(names.firstIndex(of: "Codex") ?? 0)
        await check("Add for Me waits for the Allow box") { !alert.addEnabled }
        alert.setAllowed(true)
        await check("ticking Allow lets clients in at once: the menu item is ticked, the app answers, the running server works") {
            let render = await early.tool("render", ["file": self.file.path])
            return Rust.mcpAllowed && allowTicked() && AppServer.serving && alert.addEnabled
                && render?.isError == false && render?.text.contains("The last paragraph.") == true
        }
        early.close()
        alert.select(0)
        await check("the window lists the tools, none first by favour, each with this app's path") {
            names == ["Claude Code", "Claude Desktop", "Codex", "Other tools (JSON)", "Any MCP client"]
                && snippets.allSatisfy { $0.text.contains(exe) } && alert.shownText.contains("claude mcp add folio")
        }
        await check("Add for Me is there for Claude Desktop and Codex only, naming the file it writes") {
            snippets.indices.allSatisfy { i in
                alert.select(i)
                let direct = ["Claude Desktop", "Codex"].contains(names[i])
                return alert.canAdd == direct && (!direct || alert.statusText.contains(snippets[i].config ?? "?"))
            }
        }
        alert.select(names.firstIndex(of: "Codex") ?? 0)
        alert.add(nil)
        let codexAdded = alert.statusText
        alert.add(nil)
        await check("Add for Me writes [mcp_servers.folio] for Codex, says so, and the second time changes nothing") {
            guard let text = try? String(contentsOf: config.appendingPathComponent("config.toml"), encoding: .utf8) else { return false }
            return codexAdded.hasPrefix("Added to") && alert.statusText.hasPrefix("Already in")
                && text.contains("[mcp_servers.folio]") && text.contains(exe) && text.contains("\"--mcp\"")
        }
        alert.select(names.firstIndex(of: "Claude Desktop") ?? 0)
        alert.add(nil)
        let claudeAdded = alert.statusText
        alert.add(nil)
        await check("Add for Me writes Claude Desktop's config, says so, and the second time changes nothing") {
            claudeAdded == "Added to \(claudeConfig.path). Restart Claude Desktop to use it." && alert.statusText.hasPrefix("Already in")
        }
        guard let data = try? Data(contentsOf: claudeConfig),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = (root["mcpServers"] as? [String: Any])?["folio"] as? [String: Any],
              let command = entry["command"] as? String, let arguments = entry["args"] as? [String] else {
            report("Claude's config has a folio entry", false)
            return
        }
        await check("the entry runs this app's binary with --mcp") {
            command == Bundle.main.executablePath && arguments == ["--mcp"]
        }

        // Start the server the way the config says, and the app's end of the link.
        await check("the app answers the server on a socket in the config folder, since clients are allowed") { AppServer.serving }
        guard let client = MCPClient(command: command, arguments: arguments) else {
            report("the server starts", false)
            return
        }
        let answer = await client.call("initialize", hello)
        await check("the server says hello over its pipes") {
            let server = (answer?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
            return server?["name"] as? String == "folio"
        }
        client.notify("notifications/initialized")
        await check("it offers the tools") {
            let listed = (await client.call("tools/list")?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            let names = Set(listed?.compactMap { $0["name"] as? String } ?? [])
            return ["render", "annotate", "reply", "verify", "focused_annotation", "reveal", "current_document"].allSatisfy(names.contains)
        }

        // What the person has open.
        controller.window?.makeKeyAndOrderFront(nil)
        let path = file.path
        await check("render gives the text annotations are anchored against") {
            await client.tool("render", ["file": path])?.text.contains("The last paragraph.") == true
        }
        await check("current_document lists this window, in front, with its sidecar") {
            guard let windows = client.json(await client.tool("current_document", [:])?.text)?["windows"] as? [[String: Any]] else { return false }
            let mine = windows.first { $0["file"] as? String == path }
            return mine?["front"] as? Bool == true && mine?["mode"] as? String == "preview"
                && mine?["sidecar"] as? String == self.controller.files.sidecar.path
        }

        // An annotation written by the server shows up in the window, with a card.
        let before = controller.currentStore.pending.count
        let added = await client.tool("annotate", [
            "file": path,
            "annotations": [["kind": "comment", "context_before": "", "target": "The last paragraph.", "comment": "From Claude over MCP"]],
        ])
        let addedID = ((client.json(added?.text)?["added"] as? [[String: Any]])?.first?["id"] as? String) ?? ""
        await check("annotate writes an annotation that appears in the window, anchored in the text") {
            let shown = await self.until {
                self.controller.currentStore.pending.count == before + 1 && self.pane.anchors[addedID] != nil
            }
            return shown && added?.isError == false && !addedID.isEmpty
        }
        await check("list_annotations and verify see it, and the markdown is not touched") {
            let listed = client.json(await client.tool("list_annotations", ["file": path])?.text)?["annotations"] as? [[String: Any]]
            let verified = client.json(await client.tool("verify", ["file": path])?.text)
            let mine = listed?.first { $0["id"] as? String == addedID }
            return mine?["anchored"] as? Bool == true && verified?["valid"] as? Bool == true && !self.disk().contains("From Claude")
        }
        let refused = await client.tool("annotate", [
            "file": path,
            "annotations": [["kind": "delete", "context_before": "nothing like this ", "target": "anywhere in the text"]],
        ])
        await check("an annotation that does not anchor is refused and nothing is written") {
            refused?.isError == true && refused?.text.contains("nothing was written") == true
                && self.controller.currentStore.pending.count == before + 1
        }

        // The annotation the reader steps to (⌃J) is the one the server reports as focused.
        pane.navigate(1)
        await check("focused_annotation follows the annotation the reader stepped to, with its thread") {
            guard let stepped = self.pane.focusedID else { return false }
            let focused = client.json(await client.tool("focused_annotation", [:])?.text)?["annotation"] as? [String: Any]
            return focused?["id"] as? String == stepped
        }

        // Showing an annotation, answering it.
        let revealed = await client.tool("reveal", ["file": path, "id": addedID])
        await check("reveal focuses the annotation in the window") {
            let focused = await self.until { self.pane.focusedID == addedID }
            return focused && revealed?.isError == false
        }
        await check("focused_annotation gives the focused annotation with its comment") {
            let focused = client.json(await client.tool("focused_annotation", [:])?.text)?["annotation"] as? [String: Any]
            return focused?["id"] as? String == addedID && focused?["comment"] as? String == "From Claude over MCP"
        }
        let replied = await client.tool("reply", ["file": path, "id": addedID, "body": "Answered over MCP"])
        await check("a reply joins the thread in the window") {
            let shown = await self.until {
                self.controller.currentStore.annotation(addedID)?.replies?.contains { $0.body == "Answered over MCP" && $0.source == "agent" } == true
            }
            return shown && replied?.isError == false
        }

        // A file that is not open is opened.
        if let other = try? tempCopy(named: "revealed.md") {
            let opened = await client.tool("reveal", ["file": other.path])
            func document() -> NSDocument? {
                NSDocumentController.shared.documents.first { $0.fileURL?.resolvingSymlinksInPath() == other.resolvingSymlinksInPath() }
            }
            await check("reveal opens a file that is not open") {
                let shown = await self.until { document() != nil }
                return shown && opened?.isError == false
            }
            document()?.close()
            controller.window?.makeKeyAndOrderFront(nil)
        } else {
            report("a second file is created", false)
        }

        // Without the app the file tools still work and the live ones say why not.
        AppServer.stop()
        await check("when the app stops answering, the live tools say Folio is not running") {
            let result = await client.tool("focused_annotation", [:])
            return result?.isError == true && result?.text.contains("not running") == true
        }
        await check("and the file tools still work") {
            await client.tool("render", ["file": path])?.text.contains("The last paragraph.") == true
        }

        client.close()
        await check("closing its input ends the server cleanly, and it said nothing but the protocol") {
            await self.until { !client.isRunning } && client.exitStatus == 0 && client.strayLines == 0
        }

        // Turning it off again from the menu shuts clients out.
        AppServer.start()
        app.toggleMCP(nil)
        guard let late = MCPClient(command: exe, arguments: ["--mcp"]) else {
            report("the server starts after access is turned off", false)
            return
        }
        _ = await late.call("initialize", hello)
        let shut = await late.tool("render", ["file": path])
        await check("unticking Allow MCP Clients shuts clients out again, and the app stops answering") {
            !Rust.mcpAllowed && !allowTicked() && !AppServer.serving
                && shut?.isError == true && shut?.text.contains("Allow MCP Clients") == true
        }
        late.close()
    }
}

/// A client of the app's MCP server over its pipes, as Claude desktop is one.
final class MCPClient: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffered = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var lastID = 0
    private var strays = 0

    init?(command: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receive(handle.availableData)
        }
        do { try process.run() } catch { return nil }
    }

    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32 { process.terminationStatus }

    /// Lines on stdout that were not JSON responses: that channel has to carry nothing else.
    var strayLines: Int {
        lock.lock()
        defer { lock.unlock() }
        return strays
    }

    func close() {
        try? input.fileHandleForWriting.close()
    }

    func notify(_ method: String) {
        write(["jsonrpc": "2.0", "method": method])
    }

    /// A request and its response, or nil when none comes. Waits without holding up the main thread,
    /// which the app answers the server's questions on.
    func call(_ method: String, _ params: [String: Any] = [:], seconds: Double = 20) async -> [String: Any]? {
        let id = nextID()
        write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let reply = takeReply(id) { return reply }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return takeReply(id)
    }

    /// A `tools/call`: whether it failed, and the text it returned.
    func tool(_ name: String, _ arguments: [String: Any]) async -> (isError: Bool, text: String)? {
        guard let reply = await call("tools/call", ["name": name, "arguments": arguments]),
              let result = reply["result"] as? [String: Any],
              let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String else { return nil }
        return (result["isError"] as? Bool ?? false, text)
    }

    func json(_ text: String?) -> [String: Any]? {
        text.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
    }

    private func nextID() -> Int {
        lock.lock()
        defer { lock.unlock() }
        lastID += 1
        return lastID
    }

    private func takeReply(_ id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return replies.removeValue(forKey: id)
    }

    private func write(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    private func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if data.isEmpty {
            output.fileHandleForReading.readabilityHandler = nil
            return
        }
        buffered.append(data)
        while let newline = buffered.firstIndex(of: 0x0A) {
            let line = Data(buffered[buffered.startIndex..<newline])
            buffered.removeSubrange(buffered.startIndex...newline)
            if let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], let id = message["id"] as? Int {
                replies[id] = message
            } else {
                strays += 1
            }
        }
    }
}
