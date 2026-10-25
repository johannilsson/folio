import AppKit
import FolioKit
import Testing

@Suite struct MarkdownHighlighterTests {
    let source = "# Title\n\nSome `code` and **bold**\n\n```\nlet x\n```\n"

    func highlighted() -> NSTextStorage {
        let storage = NSTextStorage(string: source)
        MarkdownHighlighter.apply(to: storage)
        return storage
    }

    func at(_ text: String, _ storage: NSTextStorage) -> Int {
        (storage.string as NSString).range(of: text).location
    }

    @Test func leavesTheCharactersAlone() {
        #expect(highlighted().string == source)
    }

    @Test func aHeadingIsHeavierThanTheText() {
        let storage = highlighted()
        let heading = storage.attribute(.font, at: at("Title", storage), effectiveRange: nil) as? NSFont
        let text = storage.attribute(.font, at: at("Some", storage), effectiveRange: nil) as? NSFont
        #expect(text == MarkdownHighlighter.regular)
        #expect(heading != nil && heading != MarkdownHighlighter.regular)
    }

    @Test func inlineCodeAndBoldAreMarked() {
        let storage = highlighted()
        #expect(storage.attribute(.backgroundColor, at: at("`code`", storage), effectiveRange: nil) != nil)
        #expect(storage.attribute(.backgroundColor, at: at("Some", storage), effectiveRange: nil) == nil)
        let bold = storage.attribute(.font, at: at("**bold**", storage), effectiveRange: nil) as? NSFont
        #expect(bold != MarkdownHighlighter.regular)
    }

    @Test func codeInAFenceIsColouredAndNotReadAsMarkdown() {
        let storage = highlighted()
        let code = storage.attribute(.foregroundColor, at: at("let x", storage), effectiveRange: nil) as? NSColor
        #expect(code != nil && code != NSColor.labelColor)
    }

    @Test func everyLineHasTheEditorsLineHeight() {
        let storage = highlighted()
        let style = storage.attribute(.paragraphStyle, at: at("Some", storage), effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.minimumLineHeight == MarkdownHighlighter.paragraph.minimumLineHeight)
    }
}
