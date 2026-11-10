import Foundation

/// A wiki page's link to an annotation or a passage, as the card of that annotation lists it.
public struct Backlink: Equatable {
    /// The wiki page the link is in: the id of its file in the window, and its path in the wiki folder.
    public let pageID: String
    public let page: String
    /// The heading the link is under, else the line it is in.
    public let context: String
    /// The words of the link ("Priya"), empty for a bare URL. They find the place in the page.
    public let label: String
    public let line: Int

    public init(pageID: String, page: String, context: String, label: String, line: Int) {
        self.pageID = pageID
        self.page = page
        self.context = context
        self.label = label
        self.line = line
    }
}

/// The `folio://annotation`, `folio://passage` and `folio://document` links in a wiki page.
public enum WikiReferences {
    public struct Reference: Equatable {
        public let link: FolioLink
        /// 1-based.
        public let line: Int
        public let context: String
        public let label: String
    }

    private static let pattern = try! NSRegularExpression(pattern: "folio://(?:annotation|passage|document)[^\\s)>\\]\"']*")

    public static func find(in markdown: String) -> [Reference] {
        let text = markdown as NSString
        let matches = pattern.matches(in: markdown, range: NSRange(location: 0, length: text.length))
        guard !matches.isEmpty else { return [] }

        // Where each line starts, and the headings (not those in a fenced block of code).
        var starts = [0]
        var lines: [String] = []
        var headings: [(line: Int, text: String)] = []
        var fenced = false
        var offset = 0
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            lines.append(line)
            offset += (line as NSString).length + 1
            starts.append(offset)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            if !fenced, line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#")))
                if !title.isEmpty, line.drop(while: { $0 == "#" }).first == " " { headings.append((index, title)) }
            }
        }

        return matches.compactMap { match in
            guard let url = URL(string: text.substring(with: match.range)), let link = FolioLink(url) else { return nil }
            let line = (starts.lastIndex { $0 <= match.range.location } ?? 0)
            let heading = headings.last { $0.line <= line }?.text
            return Reference(link: link, line: line + 1, context: heading ?? snippet(of: lines[line]), label: label(before: match.range.location, in: text, lineStart: starts[line]))
        }
    }

    /// The words of the markdown link a URL is the target of: `[these](url)`.
    private static func label(before at: Int, in text: NSString, lineStart: Int) -> String {
        guard at - lineStart >= 2, text.substring(with: NSRange(location: at - 2, length: 2)) == "](" else { return "" }
        let head = text.substring(with: NSRange(location: lineStart, length: at - 2 - lineStart)) as NSString
        let open = head.range(of: "[", options: .backwards)
        return open.location == NSNotFound ? "" : head.substring(from: open.upperBound).trimmingCharacters(in: .whitespaces)
    }

    /// A line without its list marker, short.
    private static func snippet(of line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        for marker in ["- [ ] ", "- [x] ", "- ", "* ", "+ ", "> "] where text.hasPrefix(marker) {
            text.removeFirst(marker.count)
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.count > 80 ? String(text.prefix(80)) + "…" : text
    }
}
