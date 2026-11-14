import AppKit
import FolioKit
import Testing

@Suite struct PreviewBuilderTests {
    /// The self-test's document, `macos/selftest.md`.
    let fixture = try! String(contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("selftest.md"), encoding: .utf8)

    func attribute(_ key: NSAttributedString.Key, at text: String, in built: PreviewText) -> Any? {
        let at = (built.text.string as NSString).range(of: text).location
        return at == NSNotFound ? nil : built.text.attribute(key, at: at, effectiveRange: nil)
    }

    func assets(in built: PreviewText) -> [String] {
        var keys: [String] = []
        built.text.enumerateAttribute(.folioAsset, in: NSRange(location: 0, length: built.text.length)) { value, _, _ in
            if let asset = value as? PreviewAsset { keys.append(asset.key) }
        }
        return keys
    }

    // MARK: the self-test's document

    @Test func markdownSyntaxIsNotShown() {
        let shown = PreviewBuilder.build(fixture, plantUML: false).text.string
        #expect(shown.contains("Self-test document") && shown.contains("The last paragraph."))
        #expect(!shown.contains("#") && !shown.contains("```"))
    }

    @Test func aDisplayedRangeMapsToTheSameWordsInTheFileAndBack() {
        let built = PreviewBuilder.build(fixture, plantUML: false)
        let shown = (built.text.string as NSString).range(of: "minimal intervention")
        let inFile = (fixture as NSString).range(of: "minimal intervention")
        #expect(built.sourceRange(forDisplay: shown) == inFile)
        #expect(built.displayRange(forSource: inFile) == shown)
    }

    @Test func theHeadingIsLargerThanTheText() {
        let built = PreviewBuilder.build(fixture, plantUML: false)
        let heading = (attribute(.font, at: "Self-test", in: built) as? NSFont)?.pointSize ?? 0
        let text = (attribute(.font, at: "Natural wine", in: built) as? NSFont)?.pointSize ?? 0
        #expect(text == PreviewBuilder.bodySize)
        #expect(heading > text)
    }

    @Test func aMermaidBlockIsAPicture() {
        let built = PreviewBuilder.build(fixture, plantUML: false)
        #expect(assets(in: built).contains { $0.hasPrefix("mermaid:") })
        #expect(!built.text.string.contains("flowchart"))
    }

    @Test func aPlantUMLBlockIsCodeUnlessItCanBeDrawn() {
        let plain = PreviewBuilder.build(fixture, plantUML: false)
        #expect(attribute(.folioBlock, at: "Alice", in: plain) as? String == "code")
        #expect(!assets(in: plain).contains { $0.hasPrefix("plantuml:") })

        let drawn = PreviewBuilder.build(fixture, plantUML: true)
        #expect(assets(in: drawn).contains { $0.hasPrefix("plantuml:") })
        #expect(!drawn.text.string.contains("Alice"))
    }

    // MARK: the map

    @Test func emphasisMarksAndListBulletsAreSkippedByTheMap() {
        let md = "A **bold** word\n\n- one\n- two\n"
        let built = PreviewBuilder.build(md, plantUML: false)
        let shown = built.text.string as NSString
        #expect(built.sourceRange(forDisplay: shown.range(of: "bold word")) == (md as NSString).range(of: "bold** word"))
        #expect(built.sourceRange(forDisplay: NSRange(location: shown.range(of: "one").location - 2, length: 1)) == nil)
        #expect(built.sourceRange(forDisplay: shown.range(of: "one")) == (md as NSString).range(of: "one"))
    }

    @Test func fencedCodeInAListKeepsItsLineByLineMap() {
        // The file indents the code; the map still finds each line.
        let md = "- item\n\n  ```js\n  const y = 1\n  let z = 2\n  ```\n"
        let built = PreviewBuilder.build(md, plantUML: false)
        let shown = built.text.string as NSString
        #expect(built.sourceRange(forDisplay: shown.range(of: "y = 1")) == (md as NSString).range(of: "y = 1"))
        #expect(built.sourceRange(forDisplay: shown.range(of: "z = 2")) == (md as NSString).range(of: "z = 2"))
    }

    // MARK: blocks

    let blocks = """
    ---
    title: Hello there
    tags: [wine, notes]
    ---

    # Blocks

    | Name | Count |
    |:-----|------:|
    | one  | 1 |
    | two  | 2 |

    > quoted text
    >
    > > deeper

    ---

    ```js
    const x = 'a' // note
    ```

    After.
    """

    @Test func theFrontmatterIsABoxOfRows() {
        let built = PreviewBuilder.build(blocks, plantUML: false)
        #expect(built.text.string.hasPrefix("title\tHello there\ntags\twine, notes\n"))
        #expect(built.text.attribute(.folioBlock, at: 0, effectiveRange: nil) as? String == "box")
        let small = (built.text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? 99
        #expect(small < PreviewBuilder.bodySize)
    }

    @Test func aValueInTheBoxAndTheHeadingAfterItMapToTheFile() {
        let built = PreviewBuilder.build(blocks, plantUML: false)
        let shown = built.text.string as NSString
        #expect(built.sourceRange(forDisplay: shown.range(of: "Hello there")) == (blocks as NSString).range(of: "Hello there"))
        #expect(built.sourceRange(forDisplay: shown.range(of: "Blocks")) == (blocks as NSString).range(of: "Blocks"))
    }

    @Test func quotesRulesAndCodeAreMarkedForPainting() {
        let built = PreviewBuilder.build(blocks, plantUML: false)
        #expect(attribute(.folioQuote, at: "quoted", in: built) as? Int == 1)
        #expect(attribute(.folioQuote, at: "deeper", in: built) as? Int == 2)
        #expect(attribute(.folioBlock, at: "const", in: built) as? String == "code")
        var rules = 0
        built.text.enumerateAttribute(.folioBlock, in: NSRange(location: 0, length: built.text.length)) { value, _, _ in
            if value as? String == "rule" { rules += 1 }
        }
        #expect(rules == 1)
        #expect(!built.text.string.contains("─"))
    }

    @Test func aTableIsCellsWithoutItsPipesAndRuleRow() {
        let built = PreviewBuilder.build(blocks, plantUML: false)
        #expect(built.text.string.contains("Count"))
        #expect(!built.text.string.contains("|") && !built.text.string.contains(":-----"))
        let style = attribute(.paragraphStyle, at: "two", in: built) as? NSParagraphStyle
        #expect(style?.textBlocks.isEmpty == false)
        #expect(built.tables.count == 1)
    }

    // MARK: HTML

    let folder = URL(fileURLWithPath: "/docs/")

    func asset(in built: PreviewText) -> PreviewAsset? {
        var found: PreviewAsset?
        built.text.enumerateAttribute(.folioAsset, in: NSRange(location: 0, length: built.text.length)) { value, _, _ in
            found = found ?? value as? PreviewAsset
        }
        return found
    }

    @Test func aCentredHeadingAndImageFromHTMLAreDrawnNotShownAsTags() {
        let html = """
        <p align="center">
          <img src="icon.png" width="128" alt="App icon">
        </p>

        <h1 align="center">Folio</h1>

        After.
        """
        let built = PreviewBuilder.build(html, base: folder, plantUML: false)
        #expect(!built.text.string.contains("<"))
        let size = (attribute(.font, at: "Folio", in: built) as? NSFont)?.pointSize ?? 0
        #expect(size > PreviewBuilder.bodySize)
        let heading = attribute(.paragraphStyle, at: "Folio", in: built) as? NSParagraphStyle
        #expect(heading?.alignment == .center)
        let picture = asset(in: built)
        #expect(picture?.key == "image:file:///docs/icon.png")
        #expect(picture?.width == 128)
        #expect(attribute(.folioCentered, at: "\u{FFFC}", in: built) != nil)
    }

    @Test func aPictureElementShowsItsImage() {
        let html = """
        <picture>
          <source media="(prefers-color-scheme: dark)" srcset="dark.png">
          <img src="light.png" alt="A screenshot">
        </picture>
        """
        let built = PreviewBuilder.build(html, base: folder, plantUML: false)
        #expect(assets(in: built) == ["image:file:///docs/light.png"])
        #expect(!built.text.string.contains("srcset"))
    }

    @Test func htmlWithAnythingElseInItIsShownAsItIsWritten() {
        let html = "<details>\n<summary>More</summary>\n</details>"
        let built = PreviewBuilder.build(html, base: folder, plantUML: false)
        #expect(built.text.string.contains("<details>") && built.text.string.contains("<summary>More</summary>"))
        #expect(attribute(.folioBlock, at: "<details>", in: built) as? String == "code")
    }

    @Test func anHTMLImageThatCannotBeFoundIsShownByItsAltText() {
        let built = PreviewBuilder.build("<img src=\"icon.png\" alt=\"App icon\">", plantUML: false)
        #expect(built.text.string.contains("App icon") && assets(in: built).isEmpty)
    }

    // MARK: links into Folio

    let page = "See [[oauth]] and [[research/rotation|the options]], then [Priya](folio://annotation/c3d4?repo=svc&path=a.md) and [web](https://example.com)."

    func link(_ text: String, in built: PreviewText) -> URL? { attribute(.folioLink, at: text, in: built) as? URL }

    @Test func aWikiLinkShowsWhatItNamesWithoutTheBrackets() {
        let shown = PreviewBuilder.build(page, plantUML: false).text.string
        #expect(shown.hasPrefix("See oauth and the options, then Priya and web."))
        #expect(!shown.contains("[["))
    }

    @Test func aWikiLinkCarriesItsTargetAndMapsToItsBrackets() {
        let built = PreviewBuilder.build(page, plantUML: false)
        let url = link("the options", in: built)
        #expect(url.flatMap { WikiLink(url: $0) }?.name == "research/rotation")
        let shown = (built.text.string as NSString).range(of: "the options")
        let inFile = (page as NSString).range(of: "[[research/rotation|the options]]")
        #expect(built.sourceRange(forDisplay: shown) == inFile)
    }

    @Test func textAroundWikiLinksMapsToTheSameWordsInTheFile() {
        let built = PreviewBuilder.build(page, plantUML: false)
        let shown = (built.text.string as NSString).range(of: ", then ")
        #expect(built.sourceRange(forDisplay: shown) == (page as NSString).range(of: ", then "))
    }

    @Test func aLinkToAnAnnotationIsOursAndOtherLinksAreNot() {
        let built = PreviewBuilder.build(page, plantUML: false)
        #expect(link("Priya", in: built)?.host == "annotation")
        #expect(link("web", in: built) == nil)
        #expect(attribute(.link, at: "web", in: built) as? URL == URL(string: "https://example.com"))
        // Ours are clicked through the view, not the text view's own link handling.
        #expect(attribute(.link, at: "Priya", in: built) == nil && attribute(.link, at: "oauth", in: built) == nil)
    }

    @Test func aLiveLinkIsDrawnForWhatItIs() {
        let built = PreviewBuilder.build(page, plantUML: false)
        #expect(attribute(.foregroundColor, at: "oauth", in: built) as? NSColor == .linkColor)
        #expect(attribute(.foregroundColor, at: "Priya", in: built) as? NSColor == .systemPurple)
        #expect(attribute(.backgroundColor, at: "Priya", in: built) != nil)
        #expect(attribute(.toolTip, at: "oauth", in: built) == nil)
    }

    @Test func aDeadLinkIsGreyWithItsReasonOnHover() {
        let built = PreviewBuilder.build(page, plantUML: false, linkState: { url in
            url.host == "wiki" ? .dead("not in the wiki") : .live
        })
        #expect(attribute(.foregroundColor, at: "oauth", in: built) as? NSColor == .secondaryLabelColor)
        #expect(attribute(.toolTip, at: "oauth", in: built) as? String == "not in the wiki")
        #expect(attribute(.foregroundColor, at: "Priya", in: built) as? NSColor == .systemPurple)
        // Still a link to Folio, so the view can ask again whether it is live.
        #expect(link("oauth", in: built) != nil)
    }

    @Test func bracketsInCodeAreNotLinks() {
        let built = PreviewBuilder.build("Use `[[x]]` or\n\n```\n[[y]]\n```\n", plantUML: false)
        #expect(built.text.string.contains("[[x]]") && built.text.string.contains("[[y]]"))
        #expect(link("[[x]]", in: built) == nil && link("[[y]]", in: built) == nil)
    }

    @Test func wikiLinksInsideAMarkdownLinkStayText() {
        let built = PreviewBuilder.build("[see [[x]] here](https://example.com)", plantUML: false)
        #expect(built.text.string.contains("[[x]]") || built.text.string.contains("x"))
        #expect(link("x", in: built) == nil)
    }
}
