import Foundation

/// A link in a wiki page, as Obsidian writes it: `[[name]]`, `[[name#heading]]`, `[[name|shown as]]`.
public struct WikiLink: Equatable {
    public let name: String
    public let heading: String?
    public let alias: String?

    public init(name: String, heading: String? = nil, alias: String? = nil) {
        self.name = name
        self.heading = heading
        self.alias = alias
    }

    /// What the preview shows in place of the brackets: the alias, else the name and the heading.
    public var shown: String { alias ?? (heading.map { "\(name) › \($0)" } ?? name) }

    /// How the link is carried in the preview's text (`folio://wiki?name=…&heading=…`), so a click can
    /// tell it from the other links.
    public var url: URL {
        var components = URLComponents()
        components.scheme = "folio"
        components.host = "wiki"
        // Encoded by hand: `queryItems` leaves "&" and "+" in a value as they are.
        func encoded(_ text: String) -> String {
            text.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~/"))) ?? text
        }
        components.percentEncodedQueryItems = [URLQueryItem(name: "name", value: encoded(name))]
            + (heading.map { [URLQueryItem(name: "heading", value: encoded($0))] } ?? [])
        return components.url ?? URL(string: "folio://wiki")!
    }

    public init?(url: URL) {
        guard url.scheme == "folio", url.host == "wiki",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let name = items.first(where: { $0.name == "name" })?.value, !name.isEmpty else { return nil }
        self.init(name: name, heading: items.first { $0.name == "heading" }?.value)
    }
}

public enum WikiLinks {
    private static let pattern = try! NSRegularExpression(
        pattern: "\\[\\[([^\\[\\]\\n|#]+)(?:#([^\\[\\]\\n|]+))?(?:\\|([^\\[\\]\\n]+))?\\]\\]")

    /// The links in `text`, with where each is (UTF-16, brackets included), in order.
    public static func find(in text: String) -> [(range: NSRange, link: WikiLink)] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return pattern.matches(in: text, range: whole).compactMap { match in
            func group(_ index: Int) -> String? {
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                let value = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            guard let name = group(1) else { return nil }
            return (match.range, WikiLink(name: name, heading: group(2), alias: group(3)))
        }
    }

    /// The file `name` means among `paths` (each relative to the wiki folder), as in Obsidian: the name
    /// without its extension, ignoring case, matches the end of a path; of several, the shortest path
    /// wins, then the first listed. Nil when no file has it.
    public static func resolve(_ name: String, among paths: [String]) -> Int? {
        let wanted = bare(name)
        guard !wanted.isEmpty else { return nil }
        let matching = paths.indices.filter { index in
            let path = bare(paths[index])
            return path == wanted || path.hasSuffix("/" + wanted)
        }
        return matching.min { a, b in
            let (x, y) = (paths[a].split(separator: "/").count, paths[b].split(separator: "/").count)
            return x != y ? x < y : a < b
        }
    }

    /// Lower case, without a leading "/" or a markdown extension.
    private static func bare(_ path: String) -> String {
        var text = path.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasPrefix("/") { text.removeFirst() }
        for ext in [".markdown", ".md"] where text.hasSuffix(ext) {
            text.removeLast(ext.count)
            break
        }
        return text
    }
}
