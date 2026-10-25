import Foundation

/// The small part of HTML that READMEs use for layout: a centred heading or paragraph, an image with
/// a width, a `<picture>` around it. `parse` reads a block of HTML into what to draw, or returns nil
/// when it has anything else in it (a table, `<details>`), and the block is shown as its source instead.
enum PreviewHTML {
    struct Image: Equatable {
        var source: String
        var alt: String
        /// The `width` attribute in points, when it is a plain number.
        var width: Double?
    }

    enum Element: Equatable {
        case heading(level: Int, text: String, centered: Bool)
        case paragraph(text: String, centered: Bool)
        case image(Image, centered: Bool)
    }

    /// Tags that wrap content; the ones that only wrap (`picture`, `a`, `b`, ...) leave their content as it is,
    /// and `source` and `br` have none.
    private static let containers: Set<String> = ["p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6"]
    private static let transparent: Set<String> = ["picture", "a", "b", "strong", "i", "em", "span", "u"]
    private static let ignored: Set<String> = ["source", "br"]

    static func parse(_ html: String) -> [Element]? {
        var elements: [Element] = []
        var text = ""
        /// The open containers: tag and whether it centres what is in it.
        var open: [(tag: String, centered: Bool)] = []
        var index = html.startIndex

        func centered() -> Bool { open.contains { $0.centered } }
        func flush() {
            let shown = collapse(decode(text))
            text = ""
            guard !shown.isEmpty else { return }
            if let heading = open.last(where: { $0.tag.count == 2 && $0.tag.hasPrefix("h") }), let level = Int(heading.tag.dropFirst()) {
                elements.append(.heading(level: level, text: shown, centered: centered()))
            } else {
                elements.append(.paragraph(text: shown, centered: centered()))
            }
        }

        while index < html.endIndex {
            guard html[index] == "<" else {
                text.append(html[index])
                index = html.index(after: index)
                continue
            }
            if html[index...].hasPrefix("<!--") {
                guard let end = html.range(of: "-->", range: index..<html.endIndex) else { return nil }
                index = end.upperBound
                continue
            }
            guard let close = html[index...].firstIndex(of: ">") else { return nil }
            let inside = html[html.index(after: index)..<close]
            index = html.index(after: close)

            let closing = inside.hasPrefix("/")
            let body = closing ? inside.dropFirst() : inside[...]
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            guard !name.isEmpty else { return nil }
            let attributes = Self.attributes(String(body.dropFirst(name.count)))

            if containers.contains(name) {
                flush()
                if closing {
                    if let last = open.lastIndex(where: { $0.tag == name }) { open.removeSubrange(last...) }
                } else {
                    // A paragraph or heading left open ends where the next one begins.
                    if name != "div", name != "center" {
                        while let last = open.last, last.tag != "div", last.tag != "center" { open.removeLast() }
                    }
                    let style = (attributes["style"] ?? "").lowercased().filter { !$0.isWhitespace }
                    let centres = (attributes["align"] ?? "").lowercased() == "center" || style.contains("text-align:center")
                    open.append((name, centres || name == "center"))
                }
            } else if name == "img", !closing {
                flush()
                guard let source = attributes["src"], !source.isEmpty else { return nil }
                let width = attributes["width"].flatMap { Double($0.hasSuffix("px") ? String($0.dropLast(2)) : $0) }
                elements.append(.image(Image(source: decode(source), alt: decode(attributes["alt"] ?? ""), width: width), centered: centered()))
            } else if transparent.contains(name) || ignored.contains(name) {
                if name == "br" { text.append(" ") }
            } else {
                return nil
            }
        }
        flush()
        return elements
    }

    private static func collapse(_ string: String) -> String {
        string.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `name="value"` pairs of a tag, names in lower case; single quotes and bare values too.
    private static func attributes(_ string: String) -> [String: String] {
        var found: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return found }
        let whole = NSRange(string.startIndex..., in: string)
        expression.enumerateMatches(in: string, range: whole) { match, _, _ in
            guard let match, let name = Range(match.range(at: 1), in: string) else { return }
            for group in 2...4 {
                if let value = Range(match.range(at: group), in: string) {
                    found[string[name].lowercased()] = String(string[value])
                    return
                }
            }
        }
        return found
    }

    private static func decode(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = string
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }
}
