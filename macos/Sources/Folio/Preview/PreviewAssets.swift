import AppKit
import Compression

extension NSAttributedString.Key {
    /// On the character that stands for an image or a diagram; the value is its `PreviewAsset`.
    static let folioAsset = NSAttributedString.Key("folioAsset")
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
            guard let url = URL(string: "\(AppConfig.plantumlURL)/png/\(PlantUML.encode(code))") else { return nil }
            return await Self.fetch(url)
        case .mermaid(let code):
            return await MermaidRenderer.shared.render(code, dark: dark)
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
