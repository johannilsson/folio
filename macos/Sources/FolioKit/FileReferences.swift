import Foundation

/// A wiki page's link to the file on screen: to the document, to a passage of it, or to one of its
/// annotations. The References tab of the inspector lists them, by page.
public struct FileReference: Equatable {
    public enum Aim: Equatable {
        case document
        case annotation(String)
        case passage(String)
    }

    public let backlink: Backlink
    public let aim: Aim

    public init(backlink: Backlink, aim: Aim) {
        self.backlink = backlink
        self.aim = aim
    }

    /// What the link points at, for a row: "the document", "an annotation", "“rotate on every use”".
    public var aimText: String {
        switch aim {
        case .document: return "the document"
        case .annotation: return "an annotation"
        case .passage(let text):
            let words = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return "“\(words.count > 40 ? String(words.prefix(40)) + "…" : words)”"
        }
    }
}

public enum FileReferences {
    /// A wiki page, as the References tab sees it: its id in the window, its name, and what it holds.
    public struct Page {
        public let id: String
        public let name: String
        public let references: [WikiReferences.Reference]

        public init(id: String, name: String, references: [WikiReferences.Reference]) {
            self.id = id
            self.name = name
            self.references = references
        }
    }

    /// The links in `pages` to the file on screen, by repo, branch and path as for following a link (the copy on
    /// another branch has its own). `candidate` is the file's checkout, nil when it is in none; `file` is its path
    /// on disk. In page order, then line order.
    public static func collect(_ pages: [Page], candidate: FolioLink.Candidate?, file: String) -> [FileReference] {
        var found: [FileReference] = []
        for page in pages {
            for reference in page.references where reference.link.points(to: candidate, file: file) {
                let aim: FileReference.Aim
                switch reference.link.target {
                case .document: aim = .document
                case .annotation(let id): aim = .annotation(id)
                case .passage(let text, _): aim = .passage(text)
                }
                let backlink = Backlink(pageID: page.id, page: page.name, context: reference.context, label: reference.label, line: reference.line)
                found.append(FileReference(backlink: backlink, aim: aim))
            }
        }
        return found.sorted { ($0.backlink.page, $0.backlink.line) < ($1.backlink.page, $1.backlink.line) }
    }

    /// One page's links.
    public struct Group: Equatable {
        public let pageID: String
        public let title: String
        public let rows: [FileReference]
    }

    /// The links grouped by page, pages in the order of their first link.
    public static func byPage(_ references: [FileReference]) -> [Group] {
        var order: [String] = []
        var rows: [String: [FileReference]] = [:]
        for reference in references {
            let id = reference.backlink.pageID
            if rows[id] == nil { order.append(id) }
            rows[id, default: []].append(reference)
        }
        return order.map { Group(pageID: $0, title: rows[$0]?.first?.backlink.page ?? "", rows: rows[$0] ?? []) }
    }
}
