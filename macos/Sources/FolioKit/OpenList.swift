import Foundation

/// A task item of a markdown file that is open work: `- [ ] … #waiting`. The file is the record; the list only reads it.
public struct OpenItem: Equatable {
    public let line: Int
    /// "investigate", "waiting" or "replied".
    public let tag: String
    public let text: String
    /// The pull or merge request the question was asked in.
    public let url: String?
    /// The annotation or passage it is about, a `folio://` link.
    public let folio: String?
    /// The first line nested under it: where an answer is summed up.
    public let note: String?

    public init(line: Int, tag: String, text: String, url: String? = nil, folio: String? = nil, note: String? = nil) {
        self.line = line
        self.tag = tag
        self.text = text
        self.url = url
        self.folio = folio
        self.note = note
    }
}

/// An open item and the file it is in: a row of the Open list.
public struct OpenEntry: Equatable {
    /// The file in the window, and its name as the sidebar shows it.
    public let pageID: String
    public let page: String
    public let item: OpenItem

    public init(pageID: String, page: String, item: OpenItem) {
        self.pageID = pageID
        self.page = page
        self.item = item
    }
}

/// How the Open list is grouped.
public enum OpenList {
    public struct Group: Equatable {
        public let title: String
        public let entries: [OpenEntry]
    }

    /// What a tag is called, and the order they are listed in: an answer to read first, then what is waited
    /// for, then what is still to look into.
    public static let tags: [(tag: String, title: String)] = [("replied", "Replied"), ("waiting", "Waiting"), ("investigate", "Investigate")]

    /// By tag, in the order of `tags`; a tag with nothing is left out. Entries keep the order given.
    public static func byTag(_ entries: [OpenEntry]) -> [Group] {
        tags.compactMap { tag, title in
            let some = entries.filter { $0.item.tag == tag }
            return some.isEmpty ? nil : Group(title: title, entries: some)
        }
    }

    /// By file, in the order the files first appear.
    public static func byFile(_ entries: [OpenEntry]) -> [Group] {
        var order: [String] = []
        var groups: [String: [OpenEntry]] = [:]
        for entry in entries {
            if groups[entry.pageID] == nil { order.append(entry.pageID) }
            groups[entry.pageID, default: []].append(entry)
        }
        return order.map { Group(title: groups[$0]?.first?.page ?? "", entries: groups[$0] ?? []) }
    }

    /// What an item is about in the file on screen: one of its annotations, or a passage of it.
    public enum About: Equatable {
        case annotation(String)
        case passage
    }

    /// An item is about the file on screen when its Folio link points at that file (`FolioLink.points(to:file:)`):
    /// about an annotation of it when the link is to one, else about a passage. Nil for any other item.
    /// `candidate` is the file's checkout, nil when it is in none; `file` is its path on disk.
    public static func about(_ item: OpenItem, candidate: FolioLink.Candidate?, file: String) -> About? {
        guard let url = item.folio.flatMap({ URL(string: $0) }), let link = FolioLink(url),
              link.points(to: candidate, file: file) else { return nil }
        switch link.target {
        case .annotation(let id): return .annotation(id)
        case .passage: return .passage
        }
    }

    /// What the Open pane lists: the whole set, or only the items about the file on screen.
    public enum Scope: Equatable {
        case file, set
    }

    /// A row of the Open pane: an item, and whether it is about an annotation of the file on screen (its dot).
    public struct PaneRow: Equatable {
        public let entry: OpenEntry
        public let aboutAnnotation: Bool

        public init(entry: OpenEntry, aboutAnnotation: Bool) {
            self.entry = entry
            self.aboutAnnotation = aboutAnnotation
        }
    }

    /// The rows of the Open pane, in the order given: every entry for the whole set, for this file only those
    /// about it (`about`). A row is marked when its item is about an annotation of the file on screen.
    public static func paneRows(_ entries: [OpenEntry], scope: Scope, candidate: FolioLink.Candidate?, file: String) -> [PaneRow] {
        entries.compactMap { entry in
            let found = Self.about(entry.item, candidate: candidate, file: file)
            if scope == .file, found == nil { return nil }
            if case .annotation = found { return PaneRow(entry: entry, aboutAnnotation: true) }
            return PaneRow(entry: entry, aboutAnnotation: false)
        }
    }

    /// The short form of an address, for a row: where it is, not all of it. "github.com · pull/42".
    public static func shortAddress(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host else { return address }
        let parts = url.path.split(separator: "/").map(String.init)
        // The last two parts of the path say which request ("pull/42", "issues/7").
        let tail = parts.suffix(2).joined(separator: "/")
        return tail.isEmpty ? host : "\(host) · \(tail)"
    }
}
