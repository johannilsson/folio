import Foundation
import FolioKit
import Testing

@Suite struct FileReferencesTests {
    let place = "repo=payments-svc&branch=main&path=docs/t.md&file=/w/docs/t.md"
    let here = FolioLink.Candidate(repo: "payments-svc", branch: "main", path: "docs/t.md")

    func page(_ id: String, _ name: String, _ markdown: String) -> FileReferences.Page {
        FileReferences.Page(id: id, name: name, references: WikiReferences.find(in: markdown))
    }

    @Test func aDocumentLinkIsFoundAndPointsAtTheFile() {
        let found = WikiReferences.find(in: "See [the spec](folio://document?\(place)).")
        #expect(found.count == 1)
        #expect(found[0].link.target == .document)
        #expect(found[0].label == "the spec")
        #expect(found[0].link.points(to: here, file: "/w/docs/t.md"))
        #expect(!found[0].link.points(to: FolioLink.Candidate(repo: "payments-svc", branch: "fix", path: "docs/t.md"), file: "/x/t.md"))
    }

    @Test func aDocumentLinkHasNoTargetToLose() {
        let link = FolioLink(URL(string: "folio://document?\(place)")!)
        #expect(link?.targetFound(markdown: "", sidecar: "") == true)
        #expect(link?.repo == "payments-svc" && link?.path == "docs/t.md")
        #expect(FolioLink(URL(string: "folio://wiki?name=x")!) == nil)
    }

    @Test func everyKindOfLinkToTheFileIsCollectedAndOthersAreNot() {
        let notes = """
        # Notes

        About [the spec](folio://document?\(place)).

        ## Rotation

        - [Priya](folio://annotation/c3d4?\(place))
        - [why](folio://passage?\(place)&q=rotate%20on%20every%20use)
        - [elsewhere](folio://document?repo=payments-svc&branch=main&path=docs/u.md&file=/w/docs/u.md)
        - [other branch](folio://document?repo=payments-svc&branch=fix&path=docs/t.md&file=/w/fix/docs/t.md)
        """
        let found = FileReferences.collect([page("a", "notes.md", notes)], candidate: here, file: "/w/docs/t.md")
        #expect(found.map(\.aim) == [.document, .annotation("c3d4"), .passage("rotate on every use")])
        #expect(found.map(\.backlink.line) == [3, 7, 8])
        #expect(found.map(\.backlink.context) == ["Notes", "Rotation", "Rotation"])
        #expect(found.map(\.aimText) == ["the document", "an annotation", "“rotate on every use”"])
    }

    @Test func aFileOutsideAnyCheckoutIsFoundByWhereItWas() {
        let notes = "[old](folio://document?file=/w/loose.md)\n[other](folio://document?file=/w/else.md)\n"
        let found = FileReferences.collect([page("a", "notes.md", notes)], candidate: nil, file: "/w/loose.md")
        #expect(found.count == 1)
    }

    @Test func pagesComeInNameOrderAndRowsInLineOrder() {
        let link = "[x](folio://document?\(place))"
        let found = FileReferences.collect([
            page("b", "research/b.md", "\(link)\n\nlater \(link)\n"),
            page("a", "a.md", "intro\n\n\(link)\n"),
        ], candidate: here, file: "/w/docs/t.md")
        let groups = FileReferences.byPage(found)
        #expect(groups.map(\.title) == ["a.md", "research/b.md"])
        #expect(groups.map { $0.rows.map(\.backlink.line) } == [[3], [1, 3]])
        #expect(groups.map(\.pageID) == ["a", "b"])
    }

    @Test func aLongPassageIsShortInARow() {
        let words = String(repeating: "rotate ", count: 20)
        let reference = FileReference(
            backlink: Backlink(pageID: "a", page: "a.md", context: "c", label: "", line: 1), aim: .passage(words))
        #expect(reference.aimText.hasSuffix("…”"))
        #expect(reference.aimText.count <= 44)
    }

    @Test func aDocumentLinkInAnItemIsAboutTheFileOnScreen() {
        let item = OpenItem(line: 1, tag: "investigate", text: "Check", folio: "folio://document?\(place)")
        #expect(OpenList.about(item, candidate: here, file: "/w/docs/t.md") == .document)
        #expect(OpenList.about(item, candidate: nil, file: "/w/else.md") == nil)
    }
}
