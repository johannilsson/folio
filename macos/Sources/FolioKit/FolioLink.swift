import Foundation

/// A link into Folio: `folio://annotation/<id>?repo=…&branch=…&path=…&file=…` to an annotation,
/// `folio://passage?repo=…&branch=…&path=…&file=…&q=…[&before=…]` to a passage of the text, or
/// `folio://document?repo=…&branch=…&path=…&file=…` to the file as a whole, as `folio link` writes them. A link names the repo and branch and the file's path in that checkout,
/// which outlive a worktree's folder; `file` is where the file was, kept for a link whose repo is not
/// open. A link without a repo is an older one and has only `file`.
public struct FolioLink: Equatable {
    public enum Target: Equatable {
        /// The file itself.
        case document
        case annotation(String)
        /// Rendered text, and the rendered words just before it when it appears more than once.
        case passage(text: String, before: String)
    }

    public let target: Target
    public let repo: String?
    public let branch: String?
    /// The file's path in its checkout ("docs/token-refresh.md").
    public let path: String?
    /// Where the file was, as an absolute path.
    public let file: String?

    public init?(_ url: URL) {
        guard url.scheme == "folio", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func query(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        switch components.host {
        case "document":
            target = .document
        case "annotation":
            let id = url.lastPathComponent
            guard !id.isEmpty, id != "/" else { return nil }
            target = .annotation(id)
        case "passage":
            guard let text = query("q") else { return nil }
            target = .passage(text: text, before: query("before") ?? "")
        default:
            return nil
        }
        repo = query("repo")
        branch = query("branch")
        path = query("path")
        file = query("file")
    }

    /// A file that is open, as far as finding a link's target goes.
    public struct Candidate: Equatable {
        public let repo: String
        public let branch: String?
        public let path: String

        public init(repo: String, branch: String?, path: String) {
            self.repo = repo
            self.branch = branch
            self.path = path
        }
    }

    public enum Resolution: Equatable {
        /// The index in the candidates given.
        case found(Int)
        /// The repo is open but not on this branch any more.
        case branchGone(String)
        /// The repo is open on the branch, without this file.
        case missing(String)
        /// The link's repo is not among the candidates (or it has none): go by `file`.
        case unknown
    }

    /// Which open file the link means. A link names repo, branch and path, never a folder.
    public func resolve(among candidates: [Candidate]) -> Resolution {
        guard let repo, let path else { return .unknown }
        let same = candidates.indices.filter { candidates[$0].repo == repo }
        guard !same.isEmpty else { return .unknown }
        let onBranch = branch.map { branch in same.filter { candidates[$0].branch == branch } } ?? same
        guard !onBranch.isEmpty else { return .branchGone(branch ?? "") }
        if let found = onBranch.first(where: { candidates[$0].path == path }) { return .found(found) }
        return .missing(path)
    }

    /// Whether the link names this file: by repo, branch and path when it has them, else by where the file
    /// was. `candidate` is the file's checkout, nil when it is in none; `file` is its path on disk.
    public func points(to candidate: Candidate?, file: String) -> Bool {
        if let repo, let path {
            guard let candidate else { return false }
            return repo == candidate.repo && path == candidate.path && (branch == nil || branch == candidate.branch)
        }
        guard let linked = self.file else { return false }
        return URL(fileURLWithPath: linked).resolvingSymlinksInPath().path == URL(fileURLWithPath: file).resolvingSymlinksInPath().path
    }

    /// Whether what the link points at is in its file: an annotation the sidecar has, unresolved, whose text the
    /// markdown still has, or a passage the markdown has. Found the way the app anchors (`Rust.anchor`, raw).
    /// `markdown` and `sidecar` are the text of the file the link resolved to and of its sidecar.
    public func targetFound(markdown: String, sidecar: String) -> Bool {
        switch target {
        case .document:
            return true
        case .annotation(let id):
            guard let annotation = (try? Sidecar.parse(sidecar))?.annotations.first(where: { $0.id == id && !$0.resolved }) else { return false }
            var item: [String: Any] = ["id": id, "context_before": annotation.contextBefore]
            if let target = annotation.target { item["target"] = target }
            return Self.anchors(item, in: markdown)
        case .passage(let text, let before):
            return Self.anchors(["id": "passage", "context_before": before, "target": text], in: markdown)
        }
    }

    private static func anchors(_ item: [String: Any], in markdown: String) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: [item]),
              let answer = try? Rust.anchor(doc: markdown, itemsJSON: String(decoding: data, as: UTF8.self), raw: true),
              let entry = (try? JSONSerialization.jsonObject(with: Data(answer.utf8)) as? [[String: Any]])?.first else { return false }
        return entry["char_from"] is NSNumber
    }

    /// What is said of a link whose file is there without its target: "Not found in token-refresh.md".
    public static func notFoundMessage(file: String) -> String {
        "Not found in \((file as NSString).lastPathComponent)"
    }

    /// What is said when a link cannot be followed, nil when it can.
    public static func message(for resolution: Resolution, repo: String?) -> String? {
        switch resolution {
        case .found: return nil
        case .branchGone(let branch): return "\(branch) isn't checked out any more"
        case .missing(let path): return "\(path) isn't in this checkout"
        case .unknown: return repo.map { "\($0) isn't in an open set" }
        }
    }
}
