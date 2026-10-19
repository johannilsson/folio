import Foundation

/// What an annotation proposes. A kind this app does not know still loads, and is written back as it was.
enum AnnotationKind: Codable, Equatable {
    case replace, delete, insert, highlight, comment
    case unknown(String)

    init(name: String) {
        switch name {
        case "replace": self = .replace
        case "delete": self = .delete
        case "insert": self = .insert
        case "highlight": self = .highlight
        case "comment": self = .comment
        default: self = .unknown(name)
        }
    }

    /// The sidecar's spelling, which the cards also use in their messages ("Rejected replace").
    var name: String {
        switch self {
        case .replace: return "replace"
        case .delete: return "delete"
        case .insert: return "insert"
        case .highlight: return "highlight"
        case .comment: return "comment"
        case .unknown(let name): return name
        }
    }

    init(from decoder: Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// A reply on an annotation's thread. The shapes mirror the sidecar (folio-sidecar-spec.md,
/// src/sidecar.rs); `source` stays a string so a value this app does not know still loads.
struct ThreadReply: Codable, Equatable {
    var id: String
    var author: String
    var source: String
    var body: String
    var created: String
}

struct Annotation: Codable, Equatable {
    var id: String
    var kind: AnnotationKind
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

    var isComment: Bool { kind == .comment }

    /// The line a suggestion's card shows: what changes to what.
    var summary: String {
        func shorten(_ text: String?, _ limit: Int = 60) -> String {
            let flat = (text ?? "").replacingOccurrences(of: "\n", with: " ")
            return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
        }
        switch kind {
        case .replace: return "\"\(shorten(target))\" → \"\(shorten(replacement))\""
        case .insert: return "\"\(shorten(replacement))\""
        case .comment: return shorten(comment, 32)
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
