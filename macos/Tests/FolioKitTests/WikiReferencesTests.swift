import Foundation
import FolioKit
import Testing

@Suite struct WikiReferencesTests {
    let annotation = "folio://annotation/c3d4?repo=payments-svc&branch=main&path=docs/t.md"
    let passage = "folio://passage?repo=payments-svc&branch=main&path=docs/t.md&q=rotate%20on%20every%20use"

    // MARK: finding links

    @Test func aMarkdownLinkHasItsWordsAsLabel() {
        let found = WikiReferences.find(in: "Asked [Priya’s question](\(annotation)) again.")
        #expect(found.count == 1)
        #expect(found[0].label == "Priya’s question")
        #expect(found[0].link.target == .annotation("c3d4"))
    }

    @Test func aBareUrlHasNoLabel() {
        let found = WikiReferences.find(in: "See \(passage) for it.")
        #expect(found.map(\.label) == [""])
        #expect(found[0].link.target == .passage(text: "rotate on every use", before: ""))
    }

    @Test func theContextIsTheHeadingTheLinkIsUnder() {
        let page = "# Threat model\n\n## T3 · Token replay\n\nSee [it](\(annotation)).\n\n## T4 · Brute force\n\nNothing.\n"
        let found = WikiReferences.find(in: page)
        #expect(found.first?.context == "T3 · Token replay")
        #expect(found.first?.line == 5)
    }

    @Test func withoutAHeadingTheContextIsTheLineWithoutItsListMarker() {
        let found = WikiReferences.find(in: "intro\n- [ ] Key rotation, asked in review [Priya](\(annotation))\n")
        #expect(found.first?.context.hasPrefix("Key rotation, asked in review [Priya](") == true)
        #expect(found.first?.line == 2)
    }

    @Test func aHashInAFencedBlockIsNotAHeading() {
        let page = "# Real\n\n```\n# not a heading\n```\n\n[x](\(annotation))\n"
        #expect(WikiReferences.find(in: page).first?.context == "Real")
    }

    @Test func severalLinksEachWithTheirOwnLine() {
        let page = "# A\n[one](\(annotation))\n# B\n[two](\(passage))\n"
        let found = WikiReferences.find(in: page)
        #expect(found.map(\.line) == [2, 4])
        #expect(found.map(\.context) == ["A", "B"])
        #expect(found.map(\.label) == ["one", "two"])
    }

    @Test func otherLinksAreNotReferences() {
        #expect(WikiReferences.find(in: "[web](https://example.com) [set](folio://set/x) [[wiki]]").isEmpty)
        #expect(WikiReferences.find(in: "no links at all").isEmpty)
        #expect(WikiReferences.find(in: "").isEmpty)
    }

    @Test func aLongLineIsCutShort() {
        let line = String(repeating: "word ", count: 40) + "[a](\(annotation))"
        let context = WikiReferences.find(in: line).first?.context ?? ""
        #expect(context.count <= 81 && context.hasSuffix("…"))
    }

    @Test func linesAreCountedInUTF16SafeWays() {
        // An emoji before the link, on an earlier line: the line number must not drift.
        #expect(WikiReferences.find(in: "😀😀\n😀 [x](\(annotation))").first?.line == 2)
    }

    // MARK: which file a link is to

    typealias Candidate = FolioLink.Candidate
    let main = Candidate(repo: "payments-svc", branch: "main", path: "docs/t.md")

    func link(_ text: String) -> FolioLink { FolioLink(URL(string: text)!)! }

    @Test func aLinkIsToTheFileByRepoBranchAndPath() {
        #expect(link(annotation).points(to: main, file: "/x/docs/t.md"))
        #expect(!link(annotation).points(to: Candidate(repo: "payments-svc", branch: "fix/logout", path: "docs/t.md"), file: "/x/docs/t.md"))
        #expect(!link(annotation).points(to: Candidate(repo: "payments-svc", branch: "main", path: "docs/other.md"), file: "/x/docs/t.md"))
        #expect(!link(annotation).points(to: Candidate(repo: "other", branch: "main", path: "docs/t.md"), file: "/x/docs/t.md"))
    }

    @Test func aLinkWithoutABranchIsToAnyCheckout() {
        let anyBranch = link("folio://annotation/c3d4?repo=payments-svc&path=docs/t.md")
        #expect(anyBranch.points(to: main, file: "/x"))
        #expect(anyBranch.points(to: Candidate(repo: "payments-svc", branch: "fix/logout", path: "docs/t.md"), file: "/x"))
    }

    @Test func aFileOutsideACheckoutIsNotWhatARepoLinkNames() {
        #expect(!link(annotation).points(to: nil, file: "/x/docs/t.md"))
    }

    @Test func anOlderLinkIsToTheFileWhereItWas() {
        let older = link("folio://annotation/c3d4?file=/work/docs/t.md")
        #expect(older.points(to: nil, file: "/work/docs/t.md"))
        #expect(older.points(to: main, file: "/work/docs/t.md"))
        #expect(!older.points(to: main, file: "/elsewhere/docs/t.md"))
    }
}
