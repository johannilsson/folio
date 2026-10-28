import AppKit
import FolioKit
import Testing

@Suite struct PreviewTextTests {
    /// "A **bold** word" as the preview shows it, "A bold word": the bold marks are left out.
    let file = "A **bold** word" as NSString
    func bold() -> PreviewText {
        var text = PreviewText()
        text.text = NSMutableAttributedString(string: "A bold word")
        text.segments = [
            .init(display: NSRange(location: 0, length: 2), source: NSRange(location: 0, length: 2), linear: true),
            .init(display: NSRange(location: 2, length: 4), source: NSRange(location: 4, length: 4), linear: true),
            .init(display: NSRange(location: 6, length: 5), source: NSRange(location: 10, length: 5), linear: true),
        ]
        return text
    }

    @Test func mapsDisplayedWordsToTheFileAndBack() {
        let text = bold()
        let shown = (text.text.string as NSString).range(of: "bold word")
        #expect(text.sourceRange(forDisplay: shown) == file.range(of: "bold** word"))
        #expect(text.displayRange(forSource: file.range(of: "bold")) == (text.text.string as NSString).range(of: "bold"))
    }

    @Test func aPositionInsideMarksSnapsToTheShownText() {
        let text = bold()
        // Inside the closing "**": a start snaps forward to " word", an end back to after "bold".
        #expect(text.displayLocation(forSource: 9, end: false) == 6)
        #expect(text.displayLocation(forSource: 9, end: true) == 6)
        #expect(text.displayLocation(forSource: 3, end: false) == 2)
    }

    @Test func textOnlyInTheRenderingHasNoPlaceInTheFile() {
        // "- one" shown as "• one".
        var text = PreviewText()
        text.text = NSMutableAttributedString(string: "• one")
        text.segments = [
            .init(display: NSRange(location: 0, length: 2), source: nil, linear: false),
            .init(display: NSRange(location: 2, length: 3), source: NSRange(location: 2, length: 3), linear: true),
        ]
        #expect(text.sourceRange(forDisplay: NSRange(location: 0, length: 1)) == nil)
        #expect(text.sourceRange(forDisplay: NSRange(location: 2, length: 3)) == NSRange(location: 2, length: 3))
    }

    @Test func aSegmentThatIsNotLinearMapsAsAWhole() {
        // "a &amp; b" shown as "a & b".
        var text = PreviewText()
        text.text = NSMutableAttributedString(string: "a & b")
        text.segments = [
            .init(display: NSRange(location: 0, length: 2), source: NSRange(location: 0, length: 2), linear: true),
            .init(display: NSRange(location: 2, length: 1), source: NSRange(location: 2, length: 5), linear: false),
            .init(display: NSRange(location: 3, length: 2), source: NSRange(location: 7, length: 2), linear: true),
        ]
        #expect(text.sourceRange(forDisplay: NSRange(location: 2, length: 1)) == NSRange(location: 2, length: 5))
        #expect(text.displayLocation(forSource: 4, end: false) == 2)
        #expect(text.displayLocation(forSource: 4, end: true) == 3)
    }

    @Test func aSuggestionPreviewIsInTheTextButNotInTheFile() {
        var text = bold()
        text.insertGhost(NSAttributedString(string: "XY"), at: 4)
        #expect(text.text.string == "A boXYld word")
        #expect(text.sourceRange(forDisplay: NSRange(location: 4, length: 2)) == nil)
        let after = (text.text.string as NSString).range(of: "ld word")
        #expect(text.sourceRange(forDisplay: after) == file.range(of: "ld** word"))
        #expect(text.displayRange(forSource: file.range(of: "word")) == (text.text.string as NSString).range(of: "word"))
    }
}

@Suite struct PreviewFrontmatterTests {
    let file = "---\ntitle: \"Hello\"\ntags:\n  - a\n  - b\n---\n# Heading\n"

    @Test func readsKeysAndValues() throws {
        let front = try #require(PreviewFrontmatter.split(file))
        #expect(front.entries.map(\.key) == ["title", "tags"])
        #expect(front.entries.map(\.value) == ["Hello", "a, b"])
        #expect(front.range == NSRange(location: 0, length: (file as NSString).range(of: "# Heading").location))
    }

    @Test func aValueWrittenAsShownHasItsPlaceInTheFile() throws {
        let front = try #require(PreviewFrontmatter.split(file))
        let all = file as NSString
        #expect(front.entries[0].keyRange == all.range(of: "title"))
        #expect(front.entries[0].valueRange == all.range(of: "Hello"))
        // A list joined onto its key is not written that way in the file.
        #expect(front.entries[1].valueRange == nil)
    }

    @Test func aFileWithCRLFLineEndingsHasItsFrontmatterToo() throws {
        let crlf = file.replacingOccurrences(of: "\n", with: "\r\n")
        let front = try #require(PreviewFrontmatter.split(crlf))
        let all = crlf as NSString
        #expect(front.entries.map(\.key) == ["title", "tags"])
        #expect(front.entries.map(\.value) == ["Hello", "a, b"])
        #expect(front.entries[0].valueRange == all.range(of: "Hello"))
        #expect(front.entries[1].keyRange == all.range(of: "tags"))
        #expect(front.range == NSRange(location: 0, length: all.range(of: "# Heading").location))
    }

    @Test func aFileWithoutFrontmatterHasNone() {
        #expect(PreviewFrontmatter.split("# Heading\n---\n") == nil)
    }
}
