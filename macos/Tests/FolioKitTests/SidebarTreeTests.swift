import Foundation
import FolioKit
import Testing

@Suite struct SidebarTreeTests {
    typealias Row = SidebarTree.Row

    @Test func filesInTheFolderHaveNoHeadings() {
        #expect(SidebarTree.rows(["a.md", "b.md"]) == [
            .file(index: 0, name: "a.md", depth: 0),
            .file(index: 1, name: "b.md", depth: 0),
        ])
    }

    @Test func aSubfolderGetsAHeadingBeforeItsFirstFile() {
        #expect(SidebarTree.rows(["a.md", "research/b.md", "research/c.md"]) == [
            .file(index: 0, name: "a.md", depth: 0),
            .folder(name: "research", depth: 1),
            .file(index: 1, name: "b.md", depth: 1),
            .file(index: 2, name: "c.md", depth: 1),
        ])
    }

    @Test func nestedAndSiblingFoldersEachGetTheirHeadings() {
        #expect(SidebarTree.rows(["archive/x.md", "research/z.md", "research/deep/y.md"]) == [
            .folder(name: "archive", depth: 1),
            .file(index: 0, name: "x.md", depth: 1),
            .folder(name: "research", depth: 1),
            .file(index: 1, name: "z.md", depth: 1),
            .folder(name: "deep", depth: 2),
            .file(index: 2, name: "y.md", depth: 2),
        ])
    }

    @Test func aFolderWithOnlySubfoldersStillGetsItsHeading() {
        #expect(SidebarTree.rows(["a/b/c.md"]) == [
            .folder(name: "a", depth: 1),
            .folder(name: "b", depth: 2),
            .file(index: 0, name: "c.md", depth: 2),
        ])
    }

    @Test func noFilesNoRows() {
        #expect(SidebarTree.rows([]).isEmpty)
    }

    @Test func theNoticeNamesUpToTwoFilesOfAKind() {
        #expect(SidebarTree.notice(added: ["c.md"], removed: [], changed: ["b.md"]) == "c.md added, b.md changed")
        #expect(SidebarTree.notice(added: [], removed: ["x.md", "y.md"], changed: []) == "x.md removed, y.md removed")
    }

    @Test func theNoticeCountsMoreThanTwo() {
        #expect(SidebarTree.notice(added: ["a", "b", "c"], removed: [], changed: []) == "3 files added")
    }

    @Test func noChangeNoNotice() {
        #expect(SidebarTree.notice(added: [], removed: [], changed: []) == nil)
    }

    // MARK: repo and branch

    typealias Checkout = SidebarTree.Checkout

    @Test func aCheckoutIsHeadedByRepoAndBranch() {
        let main = Checkout(root: "/work/payments-svc", repo: "payments-svc", branch: "main", worktree: false)
        #expect(SidebarTree.headings([main]) == ["/work/payments-svc": "payments-svc · main"])
    }

    @Test func aWorktreeSaysSoAndKeepsItsReposName() {
        let main = Checkout(root: "/work/payments-svc", repo: "payments-svc", branch: "main", worktree: false)
        let linked = Checkout(root: "/work/payments-svc-logout", repo: "payments-svc", branch: "fix/logout", worktree: true)
        let titles = SidebarTree.headings([main, linked])
        #expect(titles["/work/payments-svc"] == "payments-svc · main")
        #expect(titles["/work/payments-svc-logout"] == "payments-svc · fix/logout · worktree")
    }

    @Test func aFolderThatIsNotACheckoutIsHeadedByItsName() {
        let plain = Checkout(root: "/notes", repo: "notes", branch: nil, worktree: false)
        #expect(SidebarTree.headings([plain])["/notes"] == "notes")
    }

    @Test func twoClonesOnTheSameBranchGetEnoughOfTheirPathToTellThemApart() {
        let a = Checkout(root: "/a/payments-svc", repo: "payments-svc", branch: "main", worktree: false)
        let b = Checkout(root: "/b/payments-svc", repo: "payments-svc", branch: "main", worktree: false)
        let titles = SidebarTree.headings([a, b])
        #expect(titles["/a/payments-svc"] == "payments-svc · main — a/payments-svc")
        #expect(titles["/b/payments-svc"] == "payments-svc · main — b/payments-svc")
    }

    @Test func clonesWhoseLastTwoFoldersAreTheSameGetMoreOfThePath() {
        let a = Checkout(root: "/x/a/svc", repo: "svc", branch: "main", worktree: false)
        let b = Checkout(root: "/y/a/svc", repo: "svc", branch: "main", worktree: false)
        let titles = SidebarTree.headings([a, b])
        #expect(titles["/x/a/svc"] == "svc · main — x/a/svc")
        #expect(titles["/y/a/svc"] == "svc · main — y/a/svc")
    }

    @Test func theSubtitleNamesTheOtherBranchesTheSameFileIsOn() {
        let main = Checkout(root: "/work/payments-svc", repo: "payments-svc", branch: "main", worktree: false)
        let linked = Checkout(root: "/work/payments-svc-logout", repo: "payments-svc", branch: "fix/logout", worktree: true)
        let others = [(name: "docs/t.md", checkout: main), (name: "docs/t.md", checkout: linked), (name: "docs/api.md", checkout: linked)]
        #expect(SidebarTree.subtitle(name: "docs/t.md", checkout: main, others: others) == "docs/t.md · also on fix/logout")
        #expect(SidebarTree.subtitle(name: "docs/api.md", checkout: linked, others: others) == "docs/api.md")
    }

    @Test func aSameNamedFileInAnotherRepoIsNotTheSameFile() {
        let a = Checkout(root: "/a/one", repo: "one", branch: "main", worktree: false)
        let b = Checkout(root: "/b/two", repo: "two", branch: "main", worktree: false)
        let others = [(name: "README.md", checkout: a), (name: "README.md", checkout: b)]
        #expect(SidebarTree.subtitle(name: "README.md", checkout: a, others: others) == "README.md")
    }

    @Test func aCheckoutWithoutABranchIsNamedByItsFolder() {
        let a = Checkout(root: "/work/svc", repo: "svc", branch: "main", worktree: false)
        let detached = Checkout(root: "/work/svc-old", repo: "svc", branch: nil, worktree: true)
        let others = [(name: "a.md", checkout: a), (name: "a.md", checkout: detached)]
        #expect(SidebarTree.subtitle(name: "a.md", checkout: a, others: others) == "a.md · also on svc-old")
    }

    @Test func noCheckoutNoSuffix() {
        #expect(SidebarTree.subtitle(name: "a.md", checkout: nil, others: []) == "a.md")
    }
}
