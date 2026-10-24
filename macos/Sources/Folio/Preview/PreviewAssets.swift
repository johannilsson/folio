import AppKit
import Compression

extension NSAttributedString.Key {
    /// On the character that stands for an image or a diagram; the value is its `PreviewAsset`.
    static let folioAsset = NSAttributedString.Key("folioAsset")
}

extension NSAttributedString.Key {
    /// On text the view draws something behind: "box" (frontmatter), "code" (a code block) or "rule".
    static let folioBlock = NSAttributedString.Key("folioBlock")
    /// On quoted text: how deep it is quoted, which is how many bars are drawn beside it.
    static let folioQuote = NSAttributedString.Key("folioQuote")
}

extension NSAttributedString.Key {
    /// On the code of a block that has a language; the value is its `PreviewCode`.
    static let folioCode = NSAttributedString.Key("folioCode")
}

/// The code of a block with a language, which the view colours once the page has said what is what in it.
final class PreviewCode: NSObject {
    let language: String
    let code: String

    init(language: String, code: String) {
        self.language = language
        self.code = code
    }

    var key: String { "\(language)\n\(code)" }
}

/// The colours of the parts of code, for the light and the dark look.
enum SyntaxColors {
    private static func pair(_ light: UInt32, _ dark: UInt32) -> NSColor {
        func color(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light)
        }
    }

    private static let keyword = pair(0xCF222E, 0xFF7B72)
    private static let string = pair(0x0A3069, 0xA5D6FF)
    private static let number = pair(0x0550AE, 0x79C0FF)
    private static let comment = pair(0x6E7781, 0x8B949E)
    private static let title = pair(0x8250DF, 0xD2A8FF)
    private static let name = pair(0x116329, 0x7EE787)

    /// The colour of a highlight.js scope, or nil for one that keeps the text colour.
    static func color(for scope: String) -> NSColor? {
        switch scope {
        case "keyword", "selector-tag", "doctag", "deletion": return keyword
        case "string", "regexp", "addition", "template-variable", "selector-attr": return string
        case "number", "literal", "symbol", "meta", "attr", "attribute", "variable", "property", "selector-id", "selector-class", "bullet": return number
        case "comment", "quote": return comment
        case "title", "built_in", "type", "class", "function", "section": return title
        case "tag", "name": return name
        default: return nil
        }
    }
}

/// Something in the document that is a picture: an image, or a diagram drawn from the code of a block.
final class PreviewAsset: NSObject {
    enum Kind {
        case image(URL)
        case plantuml(String)
        case mermaid(String)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// Same picture, same key: the view loads each only once.
    var key: String {
        switch kind {
        case .image(let url): return "image:\(url.absoluteString)"
        case .plantuml(let code): return "plantuml:\(code)"
        case .mermaid(let code): return "mermaid:\(code)"
        }
    }

    /// The picture, or nil when it cannot be had (a missing file, no network).
    @MainActor
    func load(dark: Bool) async -> NSImage? {
        switch kind {
        case .image(let url):
            return await Self.fetch(url)
        case .plantuml(let code):
            if let command = AppConfig.plantumlCommand { return await Self.run(command, input: code) }
            guard let server = AppConfig.plantumlURL, let url = URL(string: "\(server)/png/\(PlantUML.encode(code))") else { return nil }
            return await Self.fetch(url)
        case .mermaid(let code):
            return await DiagramPage.shared.render(code, dark: dark)
        }
    }

    /// What stands in for a diagram that cannot be drawn (no network, a mistake in it): its code.
    func placeholder() -> NSImage? {
        let code: String
        switch kind {
        case .image: return nil
        case .plantuml(let text), .mermaid(let text): code = text
        }
        let text = NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let size = NSSize(width: ceil(text.size().width) + 24, height: ceil(text.size().height) + 24)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(at: NSPoint(x: 12, y: 12))
            return true
        }
    }

    /// Runs `command -pipe -tpng` with the diagram on stdin and reads the PNG it writes. An app started
    /// from the Finder has a short PATH, so Homebrew's folders are added for the command (and the
    /// Graphviz it calls). A command that hangs is stopped after 30 seconds.
    private static func run(_ command: [String], input: String) async -> NSImage? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command + ["-pipe", "-tpng"]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"].joined(separator: ":")
            process.environment = environment
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { if process.isRunning { process.terminate() } }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? NSImage(data: data) : nil
        }.value
    }

    @MainActor
    private static func fetch(_ url: URL) async -> NSImage? {
        if url.isFileURL { return NSImage(contentsOf: url) }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return NSImage(data: data)
    }
}

/// The encoding of a diagram into a PlantUML server's URL: raw deflate, then its own base64.
enum PlantUML {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    static func encode(_ text: String) -> String {
        let input = Array(text.utf8)
        let capacity = input.count + 1024
        var output = [UInt8](repeating: 0, count: capacity)
        let size = compression_encode_buffer(&output, capacity, input, input.count, nil, COMPRESSION_ZLIB)
        let bytes = Array(output.prefix(size))
        var result = ""
        var index = 0
        while index < bytes.count {
            let b1 = bytes[index]
            let b2: UInt8 = index + 1 < bytes.count ? bytes[index + 1] : 0
            let b3: UInt8 = index + 2 < bytes.count ? bytes[index + 2] : 0
            for six in [b1 >> 2, ((b1 & 0x3) << 4) | (b2 >> 4), ((b2 & 0xF) << 2) | (b3 >> 6), b3 & 0x3F] {
                result.append(alphabet[Int(six)])
            }
            index += 3
        }
        return result
    }
}
