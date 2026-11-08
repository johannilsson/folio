import Foundation
import FolioKit
import Testing

@Suite struct OpenListTests {
    func entry(_ page: String, _ tag: String, _ text: String) -> OpenEntry {
        OpenEntry(pageID: page, page: "\(page).md", item: OpenItem(line: 1, tag: tag, text: text))
    }

    // MARK: grouping

    @Test func byTagRepliedFirstThenWaitingThenInvestigate() {
        let groups = OpenList.byTag([entry("a", "investigate", "i"), entry("a", "waiting", "w"), entry("b", "replied", "r"), entry("b", "waiting", "w2")])
        #expect(groups.map(\.title) == ["Replied", "Waiting", "Investigate"])
        #expect(groups[1].entries.map(\.item.text) == ["w", "w2"])
    }

    @Test func aTagWithNothingIsLeftOut() {
        #expect(OpenList.byTag([entry("a", "waiting", "w")]).map(\.title) == ["Waiting"])
        #expect(OpenList.byTag([]).isEmpty)
    }

    @Test func byFileInTheOrderTheFilesAppear() {
        let groups = OpenList.byFile([entry("b", "waiting", "1"), entry("a", "replied", "2"), entry("b", "investigate", "3")])
        #expect(groups.map(\.title) == ["b.md", "a.md"])
        #expect(groups[0].entries.map(\.item.text) == ["1", "3"])
    }

    // MARK: addresses

    @Test func anAddressIsShortenedToWhereItIs() {
        #expect(OpenList.shortAddress("https://github.com/team/svc/pull/42#issuecomment-981") == "github.com · pull/42")
        #expect(OpenList.shortAddress("https://github.com/johannilsson/folio/pull/118") == "github.com · pull/118")
        #expect(OpenList.shortAddress("https://example.com") == "example.com")
        #expect(OpenList.shortAddress("not an address") == "not an address")
    }

    // MARK: the Open pane

    let here = FolioLink.Candidate(repo: "svc", branch: "main", path: "docs/t.md")
    let file = "/work/svc/docs/t.md"

    func linked(_ text: String, _ folio: String?) -> OpenEntry {
        OpenEntry(pageID: "w", page: "notes.md", item: OpenItem(line: 1, tag: "waiting", text: text, folio: folio))
    }

    @Test func anItemLinkingToAnAnnotationOfTheFileIsAboutThatAnnotation() {
        let item = linked("a", "folio://annotation/c3d4?repo=svc&branch=main&path=docs/t.md").item
        #expect(OpenList.about(item, candidate: here, file: file) == .annotation("c3d4"))
    }

    @Test func anItemLinkingToAPassageOfTheFileIsAboutAPassage() {
        let item = linked("p", "folio://passage?repo=svc&path=docs/t.md&q=rotate").item
        #expect(OpenList.about(item, candidate: here, file: file) == .passage)
    }

    @Test func anItemLinkingElsewhereOrNowhereIsNotAboutTheFile() {
        #expect(OpenList.about(linked("o", "folio://annotation/c3d4?repo=svc&branch=fix&path=docs/t.md").item, candidate: here, file: file) == nil)
        #expect(OpenList.about(linked("o", "folio://annotation/c3d4?repo=svc&branch=main&path=docs/u.md").item, candidate: here, file: file) == nil)
        #expect(OpenList.about(linked("n", nil).item, candidate: here, file: file) == nil)
        // A file in no checkout is found by where it is.
        #expect(OpenList.about(linked("f", "folio://annotation/c3d4?file=/work/svc/docs/t.md").item, candidate: nil, file: file) == .annotation("c3d4"))
    }

    @Test func theWholeSetListsEveryItemAndMarksThoseAboutAnAnnotationOfTheFile() {
        let entries = [
            linked("a", "folio://annotation/c3d4?repo=svc&branch=main&path=docs/t.md"),
            linked("p", "folio://passage?repo=svc&path=docs/t.md&q=rotate"),
            linked("n", nil),
        ]
        let rows = OpenList.paneRows(entries, scope: .set, candidate: here, file: file)
        #expect(rows.map(\.entry.item.text) == ["a", "p", "n"])
        #expect(rows.map(\.aboutAnnotation) == [true, false, false])
    }

    @Test func thisFileListsOnlyTheItemsAboutIt() {
        let entries = [
            linked("n", nil),
            linked("p", "folio://passage?repo=svc&path=docs/t.md&q=rotate"),
            linked("o", "folio://annotation/c3d4?repo=svc&branch=main&path=docs/u.md"),
            linked("a", "folio://annotation/c3d4?repo=svc&branch=main&path=docs/t.md"),
        ]
        let rows = OpenList.paneRows(entries, scope: .file, candidate: here, file: file)
        #expect(rows.map(\.entry.item.text) == ["p", "a"])
        #expect(rows.map(\.aboutAnnotation) == [false, true])
    }
}
