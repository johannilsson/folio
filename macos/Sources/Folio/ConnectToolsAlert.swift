import AppKit

/// Folio ▸ MCP ▸ Other Tools…: the MCP server is the app's own binary, so a tool Folio does not connect
/// itself needs to be told its path. A pop-up picks the tool and shows what to run or paste for it
/// (`Rust.mcpSnippets`); Copy puts the shown text on the pasteboard.
@MainActor
final class ConnectToolsAlert: NSObject {
    private static let width: CGFloat = 480
    private let snippets: [Rust.Snippet]
    private let popup = NSPopUpButton(frame: NSRect(x: 0, y: 188, width: 240, height: 26), pullsDown: false)
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: ConnectToolsAlert.width, height: 150))
    private let box = NSView(frame: NSRect(x: 0, y: 0, width: ConnectToolsAlert.width, height: 220))

    init(snippets: [Rust.Snippet]) {
        self.snippets = snippets
        super.init()

        popup.addItems(withTitles: snippets.map(\.name))
        popup.target = self
        popup.action = #selector(pick(_:))

        hint.frame = NSRect(x: 0, y: 156, width: Self.width, height: 28)
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: Self.width, height: 150))
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

        box.addSubview(popup)
        box.addSubview(hint)
        box.addSubview(scroll)
        show(0)
    }

    /// What is shown for the tool at `index`.
    var shownText: String { textView.string }

    @objc private func pick(_ sender: Any?) {
        show(popup.indexOfSelectedItem)
    }

    private func show(_ index: Int) {
        guard snippets.indices.contains(index) else { return }
        hint.stringValue = snippets[index].hint
        textView.string = snippets[index].text
    }

    func run() {
        let alert = NSAlert()
        alert.messageText = "Connect other tools to Folio"
        alert.informativeText = "Folio is an MCP server: the tool starts the app's own program with --mcp. Pick your tool and copy what it needs."
        alert.accessoryView = box
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(shownText, forType: .string)
        }
    }
}
