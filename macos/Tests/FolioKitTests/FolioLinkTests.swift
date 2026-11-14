import Foundation
import FolioKit
import Testing

@Suite struct FolioLinkTests {
    typealias Candidate = FolioLink.Candidate

    func link(_ text: String) -> FolioLink? { URL(string: text).flatMap(FolioLink.init) }

    // MARK: reading a link

    @Test func anAnnotationLinkNamesRepoBranchPathAndFile() {
        let parsed = link("folio://annotation/ann_k7mx?repo=payments-svc&branch=fix/logout&path=docs/t.md&file=/work/payments-svc/docs/t.md")
        #expect(parsed == link("folio://annotation/ann_k7mx?repo=payments-svc&branch=fix/logout&path=docs/t.md&file=/work/payments-svc/docs/t.md"))
        #expect(parsed?.target == .annotation("ann_k7mx"))
        #expect(parsed?.repo == "payments-svc")
        #expect(parsed?.branch == "fix/logout")
        #expect(parsed?.path == "docs/t.md")
        #expect(parsed?.file == "/work/payments-svc/docs/t.md")
    }

    @Test func anOlderLinkHasOnlyAFile() {
        let parsed = link("folio://annotation/ann_x?file=/tmp/a.md")
        #expect(parsed?.target == .annotation("ann_x"))
        #expect(parsed?.file == "/tmp/a.md")
        #expect(parsed?.repo == nil && parsed?.branch == nil && parsed?.path == nil)
    }

    @Test func aPassageLinkCarriesItsTextDecoded() {
        let parsed = link("folio://passage?repo=r&path=a.md&q=rotate%20on%20every%20use&before=We%20")
        #expect(parsed?.target == .passage(text: "rotate on every use", before: "We "))
        #expect(link("folio://passage?repo=r&path=a.md&q=x")?.target == .passage(text: "x", before: ""))
    }

    @Test func linksThatAreNotOursOrAreIncompleteAreNotLinks() {
        #expect(link("folio://passage?repo=r&path=a.md") == nil)
        #expect(link("folio://annotation/") == nil)
        #expect(link("folio://set/x") == nil)
        #expect(link("https://example.com/annotation/x") == nil)
    }

    // MARK: finding the file

    let main = Candidate(repo: "payments-svc", branch: "main", path: "docs/t.md")
    let linked = Candidate(repo: "payments-svc", branch: "fix/logout", path: "docs/t.md")
    let other = Candidate(repo: "other", branch: "main", path: "docs/t.md")

    @Test func aLinkFindsTheCopyOnItsBranch() {
        let onLogout = link("folio://annotation/a?repo=payments-svc&branch=fix/logout&path=docs/t.md")
        #expect(onLogout?.resolve(among: [main, linked, other]) == .found(1))
        let onMain = link("folio://annotation/a?repo=payments-svc&branch=main&path=docs/t.md")
        #expect(onMain?.resolve(among: [main, linked, other]) == .found(0))
    }

    @Test func aBranchNoCheckoutIsOnAnyMoreIsGone() {
        let gone = link("folio://annotation/a?repo=payments-svc&branch=fix/login&path=docs/t.md")
        #expect(gone?.resolve(among: [main, linked]) == .branchGone("fix/login"))
        #expect(FolioLink.message(for: .branchGone("fix/login"), repo: "payments-svc") == "fix/login isn't checked out any more")
    }

    @Test func aFileTheBranchLacksIsMissing() {
        let missing = link("folio://annotation/a?repo=payments-svc&branch=main&path=docs/gone.md")
        #expect(missing?.resolve(among: [main, linked]) == .missing("docs/gone.md"))
        #expect(FolioLink.message(for: .missing("docs/gone.md"), repo: nil) == "docs/gone.md isn't in this checkout")
    }

    @Test func aLinkWithoutABranchMeansAnyCheckoutOfTheRepo() {
        let anyBranch = link("folio://annotation/a?repo=payments-svc&path=docs/t.md")
        #expect(anyBranch?.resolve(among: [other, linked, main]) == .found(1))
    }

    @Test func aRepoThatIsNotOpenGoesByFile() {
        let elsewhere = link("folio://annotation/a?repo=unknown&branch=main&path=docs/t.md&file=/x/docs/t.md")
        #expect(elsewhere?.resolve(among: [main, linked]) == .unknown)
        #expect(link("folio://annotation/a?file=/x/t.md")?.resolve(among: [main]) == .unknown)
        #expect(FolioLink.message(for: .unknown, repo: "unknown") == "unknown isn't in an open set")
        #expect(FolioLink.message(for: .unknown, repo: nil) == nil)
        #expect(FolioLink.message(for: .found(0), repo: "r") == nil)
    }

    // MARK: whether the target is still there

    let markdown = "# Tokens\n\nWe rotate on every use, so a token is valid for one exchange.\n"
    func sidecar(resolved: Bool) -> String {
        """
        {"version":1,"annotations":[{"id":"c3d4","kind":"comment","source":"agent","author":"priya",
        "context_before":"We ","target":"rotate on every use","comment":"Enough?","created":"2026-11-01T10:00:00Z","resolved":\(resolved)}]}
        """
    }

    @Test func anAnnotationLinkFindsItsTargetWhileItIsOpenAndItsTextIsThere() throws {
        let link = try #require(FolioLink(URL(string: "folio://annotation/c3d4?file=/t.md")!))
        #expect(link.targetFound(markdown: markdown, sidecar: sidecar(resolved: false)))
        // Resolved (accepted, dismissed) or deleted: gone.
        #expect(!link.targetFound(markdown: markdown, sidecar: sidecar(resolved: true)))
        #expect(!link.targetFound(markdown: markdown, sidecar: #"{"version":1,"annotations":[]}"#))
        // Its text edited away.
        #expect(!link.targetFound(markdown: "# Tokens\n\nWe keep tokens for a day.\n", sidecar: sidecar(resolved: false)))
    }

    @Test func aPassageLinkFindsItsTargetWhileTheTextHasIt() throws {
        let link = try #require(FolioLink(URL(string: "folio://passage?file=/t.md&q=valid%20for%20one%20exchange")!))
        #expect(link.targetFound(markdown: markdown, sidecar: ""))
        #expect(!link.targetFound(markdown: "# Tokens\n\nWe keep tokens for a day.\n", sidecar: ""))
    }

    @Test func notFoundNamesTheFile() {
        #expect(FolioLink.notFoundMessage(file: "/work/svc/docs/token-refresh.md") == "Not found in token-refresh.md")
    }
}
