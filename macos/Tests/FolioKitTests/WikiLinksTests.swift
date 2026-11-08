import Foundation
import FolioKit
import Testing

@Suite struct WikiLinksTests {
    func links(_ text: String) -> [WikiLink] { WikiLinks.find(in: text).map(\.link) }

    // MARK: finding links

    @Test func aPlainLink() {
        #expect(links("See [[requirements]] for it.") == [WikiLink(name: "requirements")])
    }

    @Test func aHeadingAnAliasAndBoth() {
        #expect(links("[[requirements#R4]]") == [WikiLink(name: "requirements", heading: "R4")])
        #expect(links("[[requirements|the requirements]]") == [WikiLink(name: "requirements", alias: "the requirements")])
        #expect(links("[[research/rotation#Options|rotation]]") == [WikiLink(name: "research/rotation", heading: "Options", alias: "rotation")])
    }

    @Test func severalLinksEachWithTheirPlace() {
        let found = WikiLinks.find(in: "a [[x]] b [[y]]")
        #expect(found.map(\.link.name) == ["x", "y"])
        #expect(found.map(\.range) == [NSRange(location: 2, length: 5), NSRange(location: 10, length: 5)])
    }

    @Test func placesAreInUTF16() {
        // The emoji is two UTF-16 units.
        #expect(WikiLinks.find(in: "😀 [[x]]").first?.range == NSRange(location: 3, length: 5))
    }

    @Test func thingsThatAreNotLinks() {
        #expect(links("[[]]").isEmpty)
        #expect(links("[[ ]]").isEmpty)
        #expect(links("[single]").isEmpty)
        #expect(links("[[unclosed").isEmpty)
        #expect(links("[[two\nlines]]").isEmpty)
        #expect(links("[[a]b]]").isEmpty)
    }

    @Test func spacesAroundANameAreLeftOut() {
        #expect(links("[[ requirements ]]") == [WikiLink(name: "requirements")])
    }

    // MARK: what is shown, and the url that carries it

    @Test func theShownTextIsTheAliasElseNameAndHeading() {
        #expect(WikiLink(name: "a").shown == "a")
        #expect(WikiLink(name: "a", heading: "H").shown == "a › H")
        #expect(WikiLink(name: "a", heading: "H", alias: "x").shown == "x")
    }

    @Test func aLinkSurvivesItsUrl() {
        for link in [WikiLink(name: "requirements"), WikiLink(name: "research/rotation options", heading: "R4 & more")] {
            #expect(WikiLink(url: link.url)?.name == link.name)
            #expect(WikiLink(url: link.url)?.heading == link.heading)
        }
        #expect(WikiLink(url: URL(string: "folio://annotation/x")!) == nil)
        #expect(WikiLink(url: URL(string: "folio://wiki")!) == nil)
    }

    // MARK: which file

    let paths = ["index.md", "research/oauth.md", "research/deep/rotation-options.md", "rotation-options.md", "Requirements.md"]

    @Test func aNameMeansTheFileWithoutItsExtension() {
        #expect(WikiLinks.resolve("index", among: paths) == 0)
        #expect(WikiLinks.resolve("index.md", among: paths) == 0)
        #expect(WikiLinks.resolve("oauth", among: paths) == 1)
    }

    @Test func caseDoesNotMatter() {
        #expect(WikiLinks.resolve("requirements", among: paths) == 4)
        #expect(WikiLinks.resolve("OAUTH", among: paths) == 1)
    }

    @Test func aPathNamesTheFileByItsEnd() {
        #expect(WikiLinks.resolve("research/oauth", among: paths) == 1)
        #expect(WikiLinks.resolve("deep/rotation-options", among: paths) == 2)
        #expect(WikiLinks.resolve("/rotation-options", among: paths) == 3)
    }

    @Test func ofSeveralTheShortestPathWins() {
        #expect(WikiLinks.resolve("rotation-options", among: paths) == 3)
        #expect(WikiLinks.resolve("rotation-options", among: ["a/b/r.md", "c/r.md", "d/r.md"].map { $0.replacingOccurrences(of: "r.md", with: "rotation-options.md") }) == 1)
    }

    @Test func aNameIsWholeSegmentsNotAnEndOfAWord() {
        #expect(WikiLinks.resolve("auth", among: paths) == nil)
        #expect(WikiLinks.resolve("tation-options", among: paths) == nil)
    }

    @Test func nothingMatchesNothing() {
        #expect(WikiLinks.resolve("missing", among: paths) == nil)
        #expect(WikiLinks.resolve("", among: paths) == nil)
        #expect(WikiLinks.resolve("a", among: []) == nil)
    }
}
