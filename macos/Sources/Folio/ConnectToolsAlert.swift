import AppKit
import FolioKit

/// Folio ▸ Connect to MCP Clients…: the MCP server is the app's own binary, so a tool needs to be told its
/// path. A pop-up picks the tool and shows what to run or paste for it (`Rust.mcpSnippets`); Copy puts the
/// shown text on the pasteboard. For a tool whose config Folio can write (Claude Desktop, Codex), Add for Me
/// writes the same entry into that file, which the line beside it names, and says what it did. Above them, the
/// same switch as Folio ▸ Allow MCP Clients: a tool can only use Folio while it is on, so Add for Me waits for it.
@MainActor
final class ConnectToolsAlert: NSObject {
    private static let width: CGFloat = 480
    private let snippets: [Rust.Snippet]
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 238, width: 240, height: 26), pullsDown: false)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: ConnectToolsAlert.width, height: 150))
    private let addButton = NSButton(title: "Add for Me", target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let allowBox = NSButton(checkboxWithTitle: "Allow MCP clients to read and annotate documents", target: nil, action: nil)
    private let box = NSView(frame: NSRect(x: 0, y: 0, width: ConnectToolsAlert.width, height: 300))

    init(snippets: [Rust.Snippet]) {
        self.snippets = snippets
        super.init()

        allowBox.frame = NSRect(x: 0, y: 274, width: Self.width, height: 22)
        allowBox.target = self
        allowBox.action = #selector(toggleAllowed(_:))
        allowBox.state = Rust.mcpAllowed ? .on : .off

        popup.addItems(withTitles: snippets.map(\.name))
        popup.target = self
        popup.action = #selector(pick(_:))

        hint.frame = NSRect(x: 0, y: 206, width: Self.width, height: 28)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 52, width: Self.width, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView

        addButton.target = self
        addButton.action = #selector(add(_:))
        addButton.sizeToFit()
        addButton.frame.origin = NSPoint(x: 0, y: 12)
        let statusX = addButton.frame.maxX + 8
        status.frame = NSRect(x: statusX, y: 0, width: Self.width - statusX, height: 44)
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        box.addSubview(allowBox)
        box.addSubview(popup)
        box.addSubview(hint)
        box.addSubview(scroll)
        box.addSubview(addButton)
        box.addSubview(status)
        show(0)
    }

    /// What is shown for the selected tool.
    var shownText: String { textView.string }
    /// The line beside Add for Me: which file it writes, then what it did.
    var statusText: String { status.stringValue }
    /// Whether the selected tool has Add for Me.
    var canAdd: Bool { !addButton.isHidden }
    /// Whether Add for Me can be pressed: only while MCP clients are allowed.
    var addEnabled: Bool { addButton.isEnabled }
    /// The Allow box, as it is shown.
    var allowShown: Bool { allowBox.state == .on }

    /// Ticks or unticks the Allow box, as a click does.
    func setAllowed(_ on: Bool) {
        allowBox.state = on ? .on : .off
        toggleAllowed(nil)
    }

    @objc private func toggleAllowed(_ sender: Any?) {
        do {
            try AppServer.allow(allowBox.state == .on)
        } catch {
            status.stringValue = (error as? RustError)?.description ?? error.localizedDescription
            status.textColor = .systemRed
        }
        allowBox.state = Rust.mcpAllowed ? .on : .off
        addButton.isEnabled = Rust.mcpAllowed
    }

    func select(_ index: Int) {
        popup.selectItem(at: index)
        show(index)
    }

    @objc private func pick(_ sender: Any?) {
        show(popup.indexOfSelectedItem)
    }

    private func show(_ index: Int) {
        guard snippets.indices.contains(index) else { return }
        let snippet = snippets[index]
        hint.stringValue = snippet.hint
        textView.string = snippet.text
        addButton.isHidden = snippet.client == nil
        addButton.isEnabled = Rust.mcpAllowed
        status.isHidden = snippet.client == nil
        status.textColor = .secondaryLabelColor
        status.stringValue = "Writes this into \(snippet.config ?? "its config"), keeping everything else in the file."
    }

    /// Add for Me: writes the selected tool's entry into its config.
    @objc func add(_ sender: Any?) {
        guard snippets.indices.contains(popup.indexOfSelectedItem) else { return }
        let snippet = snippets[popup.indexOfSelectedItem]
        guard let client = snippet.client else { return }
        do {
            let result = try AppServer.connect(client: client)
            switch result.change {
            case "unchanged": status.stringValue = "Already in \(result.config); nothing changed."
            case "added": status.stringValue = "Added to \(result.config). Restart \(snippet.name) to use it."
            default: status.stringValue = "Updated in \(result.config). Restart \(snippet.name) to use it."
            }
            status.textColor = .labelColor
        } catch {
            status.stringValue = (error as? RustError)?.description ?? error.localizedDescription
            status.textColor = .systemRed
        }
    }

    func run() {
        let alert = NSAlert()
        alert.messageText = "Connect MCP clients to Folio"
        alert.informativeText = "Folio is an MCP server: the tool starts the app's own program with --mcp. A tool can read and annotate your documents only while MCP clients are allowed, and you can turn that off again at any time (Folio ▸ Allow MCP Clients). Pick your tool to see what it needs, and copy it. For some tools Folio can also add it for you."
        alert.accessoryView = box
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shownText, forType: .string)
        }
    }
}
