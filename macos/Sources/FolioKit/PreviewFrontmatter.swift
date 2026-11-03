import Foundation

/// The YAML block at the top of a file. The preview shows it as a small box of key and value rows
/// instead of reading it as markdown. The parsing is simple: top-level `key: value` pairs, list items
/// joined onto their key.
public struct PreviewFrontmatter {
    public struct Entry {
        public var key: String
        public var keyRange: NSRange
        public var value: String
        /// Where the value is in the file, when it is written there as it is shown.
        public var valueRange: NSRange?
    }

    /// From the opening `---` to the end of the closing one's line.
    public var range: NSRange
    public var entries: [Entry]

    public static func split(_ text: String) -> PreviewFrontmatter? {
        guard text.hasPrefix("---"),
              let block = try? NSRegularExpression(pattern: "^---\\r?\\n([\\s\\S]*?)\\r?\\n---[ \\t]*(?:\\r?\\n|$)"),
              let pair = try? NSRegularExpression(pattern: "^([^\\s:#-][^:]*):\\s*(.*)$") else { return nil }
        let all = text as NSString
        guard let match = block.firstMatch(in: text, range: NSRange(location: 0, length: all.length)) else { return nil }
        let yaml = match.range(at: 1)
        var entries: [Entry] = []
        var lineStart = yaml.location
        for raw in (all.substring(with: yaml) as NSString).components(separatedBy: "\n") {
            defer { lineStart += (raw as NSString).length + 1 }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let text = line as NSString
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let kv = pair.firstMatch(in: line, range: NSRange(location: 0, length: text.length)) {
                let key = text.substring(with: kv.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let rawValue = kv.range(at: 2)
                let value = clean(text.substring(with: rawValue))
                let keyAt = text.range(of: key)
                var valueRange: NSRange?
                if !value.isEmpty {
                    let found = text.range(of: value, options: [], range: rawValue)
                    if found.location != NSNotFound { valueRange = NSRange(location: lineStart + found.location, length: found.length) }
                }
                entries.append(Entry(key: key, keyRange: NSRange(location: lineStart + keyAt.location, length: keyAt.length),
                                     value: value, valueRange: valueRange))
            } else if !entries.isEmpty {
                var item = trimmed
                if item.hasPrefix("-") { item = String(item.dropFirst()).trimmingCharacters(in: .whitespaces) }
                let part = clean(item)
                if part.isEmpty { continue }
                entries[entries.count - 1].value = entries[entries.count - 1].value.isEmpty ? part : entries[entries.count - 1].value + ", " + part
                entries[entries.count - 1].valueRange = nil
            }
        }
        return PreviewFrontmatter(range: match.range, entries: entries)
    }

    private static func clean(_ value: String) -> String {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.range(of: "^[|>][+-]?$", options: .regularExpression) != nil { return "" }
        if v.hasPrefix("[") && v.hasSuffix("]") { v = String(v.dropFirst().dropLast()) }
        if v.count >= 2, let first = v.first, first == "\"" || first == "'", v.last == first { v = String(v.dropFirst().dropLast()) }
        return v.trimmingCharacters(in: .whitespaces)
    }
}
