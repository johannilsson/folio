import AppKit
import Foundation

/// A task item of a markdown file that is open work: `- [ ] … #waiting`. The file is the record; the list only reads it.
public struct OpenItem: Equatable {
    public let line: Int
    /// A tag the set lists (`OpenTag.name`).
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

/// A tag that makes a task item open, as its set lists it: how it is written, what the list calls it and its colour.
public struct OpenTag: Equatable {
    public let name: String
    public let label: String
    /// The system colour's name (red, orange, yellow, green, blue, purple, pink, gray).
    public let colorName: String

    public init(name: String, label: String? = nil, colorName: String = "gray") {
        self.name = name
        self.label = label ?? name.prefix(1).uppercased() + name.dropFirst()
        self.colorName = colorName
    }

    public var color: NSColor {
        switch colorName {
        case "red": return .systemRed
        case "orange": return .systemOrange
        case "yellow": return .systemYellow
        case "green": return .systemGreen
        case "blue": return .systemBlue
        case "purple": return .systemPurple
        case "pink": return .systemPink
        default: return .systemGray
        }
    }

    /// What a set that lists none of its own has (src/wiki.rs `default_tags`): an answer to read first, then
    /// what is waited for, then what is still to look into.
    public static let defaults = [OpenTag(name: "replied", colorName: "green"), OpenTag(name: "waiting", colorName: "orange"), OpenTag(name: "investigate")]

    /// The tag called `name` among `tags`; one that is not listed is plain.
    public static func find(_ name: String, in tags: [OpenTag]) -> OpenTag {
        tags.first { $0.name == name } ?? OpenTag(name: name)
    }
}

/// How the Open list is grouped.
public enum OpenList {
    public struct Group: Equatable {
        public let title: String
        public let entries: [OpenEntry]
    }

    /// By tag, in the order of `tags` and then any other in the order they first appear; a tag with nothing
    /// is left out. Entries keep the order given.
    public static func byTag(_ entries: [OpenEntry], tags: [OpenTag] = OpenTag.defaults) -> [Group] {
        var order = tags
        for entry in entries where !order.contains(where: { $0.name == entry.item.tag }) { order.append(OpenTag(name: entry.item.tag)) }
        return order.compactMap { tag in
            let some = entries.filter { $0.item.tag == tag.name }
            return some.isEmpty ? nil : Group(title: tag.label, entries: some)
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

    /// What an item is about in the file on screen: one of its annotations, a passage of it, or all of it.
    public enum About: Equatable {
        case annotation(String)
        case passage
        case document
    }

    /// An item is about the file on screen when its Folio link points at that file (`FolioLink.points(to:file:)`):
    /// about an annotation of it when the link is to one, a passage when it is to one, else the document. Nil for any other item.
    /// `candidate` is the file's checkout, nil when it is in none; `file` is its path on disk.
    public static func about(_ item: OpenItem, candidate: FolioLink.Candidate?, file: String) -> About? {
        guard let url = item.folio.flatMap({ URL(string: $0) }), let link = FolioLink(url),
              link.points(to: candidate, file: file) else { return nil }
        switch link.target {
        case .annotation(let id): return .annotation(id)
        case .passage: return .passage
        case .document: return .document
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
