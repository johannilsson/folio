import Foundation

/// What an annotation proposes. A kind this app does not know still loads, and is written back as it was.
public enum AnnotationKind: Codable, Equatable {
    case replace, delete, insert, highlight, comment
    case unknown(String)

    public init(name: String) {
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
    public var name: String {
        switch self {
        case .replace: return "replace"
        case .delete: return "delete"
        case .insert: return "insert"
        case .highlight: return "highlight"
        case .comment: return "comment"
        case .unknown(let name): return name
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(name: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}

/// A reply on an annotation's thread. The shapes mirror the sidecar (folio-sidecar-spec.md,
/// src/sidecar.rs); `source` stays a string so a value this app does not know still loads.
public struct ThreadReply: Codable, Equatable {
    public var id: String
    public var author: String
    public var source: String
    public var body: String
    public var created: String
}

public struct Annotation: Codable, Equatable {
    public var id: String
    public var kind: AnnotationKind
    public var source: String
    public var author: String
    public var contextBefore: String
    public var target: String?
    public var replacement: String?
    public var comment: String?
    public var created: String
    public var resolved: Bool
    public var resolvedAs: String?
    public var resolvedAt: String?
    public var replies: [ThreadReply]?

    public var isComment: Bool { kind == .comment }

    /// The line a suggestion's card shows: what changes to what.
    public var summary: String {
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

public struct Sidecar: Codable, Equatable {
    public var version: Int
    public var annotations: [Annotation]

    public static let empty = Sidecar(version: 1, annotations: [])

    public static func parse(_ text: String) throws -> Sidecar {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Sidecar.self, from: Data(text.utf8))
    }
}
