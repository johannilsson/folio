import Foundation

/// A reply on an annotation's thread. The shapes mirror the sidecar (folio-sidecar-spec.md,
/// src/sidecar.rs); `source` and `kind` stay strings so a value this app does not know still loads.
struct ThreadReply: Codable, Equatable {
    var id: String
    var author: String
    var source: String
    var body: String
    var created: String
}

struct Annotation: Codable, Equatable {
    var id: String
    var kind: String
    var source: String
    var author: String
    var contextBefore: String
    var target: String?
    var replacement: String?
    var comment: String?
    var created: String
    var resolved: Bool
    var resolvedAs: String?
    var resolvedAt: String?
    var replies: [ThreadReply]?

    var isComment: Bool { kind == "comment" }

    /// The line a suggestion's card shows: what changes to what.
    var summary: String {
        func shorten(_ text: String?, _ limit: Int = 60) -> String {
            let flat = (text ?? "").replacingOccurrences(of: "\n", with: " ")
            return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        }
        switch kind {
        case "replace": return "\"\(shorten(target))\" → \"\(shorten(replacement))\""
        case "insert": return "\"\(shorten(replacement))\""
        case "comment": return shorten(comment, 32)
        default: return "\"\(shorten(target))\""
        }
    }
}

struct Sidecar: Codable, Equatable {
    var version: Int
    var annotations: [Annotation]

    static let empty = Sidecar(version: 1, annotations: [])

    static func parse(_ text: String) throws -> Sidecar {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Sidecar.self, from: Data(text.utf8))
    }
}

extension Annotation {
    /// The annotation as the sidecar spells it, for `Rust.edit`.
    func sidecarObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
