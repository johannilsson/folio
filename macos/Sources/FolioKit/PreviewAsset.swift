import AppKit

public extension NSAttributedString.Key {
    /// On the character that stands for an image or a diagram; the value is its `PreviewAsset`.
    static let folioAsset = NSAttributedString.Key("folioAsset")
}

public extension NSAttributedString.Key {
    /// On text the view draws something behind: "box" (frontmatter), "code" (a code block) or "rule".
    static let folioBlock = NSAttributedString.Key("folioBlock")
    /// On quoted text: how deep it is quoted, which is how many bars are drawn beside it.
    static let folioQuote = NSAttributedString.Key("folioQuote")
}

public extension NSAttributedString.Key {
    /// On the code of a block that has a language; the value is its `PreviewCode`.
    static let folioCode = NSAttributedString.Key("folioCode")
}

/// The code of a block with a language, which the view colours once the page has said what is what in it.
public final class PreviewCode: NSObject {
    public let language: String
    public let code: String

    public init(language: String, code: String) {
        self.language = language
        self.code = code
    }

    public var key: String { "\(language)\n\(code)" }
}

/// Something in the document that is a picture: an image, or a diagram drawn from the code of a block.
public final class PreviewAsset: NSObject {
    public enum Kind {
        case image(URL)
        case plantuml(String)
        case mermaid(String)
    }

    public let kind: Kind
    /// How wide to draw it, when the file says (an HTML `width`); otherwise its own size, as wide as the text at most.
    public let width: CGFloat?

    public init(_ kind: Kind, width: CGFloat? = nil) {
        self.kind = kind
        self.width = width
    }

    /// Same picture, same key: the view loads each only once.
    public var key: String {
        switch kind {
        case .image(let url): return "image:\(url.absoluteString)"
        case .plantuml(let code): return "plantuml:\(code)"
        case .mermaid(let code): return "mermaid:\(code)"
        }
    }
}
