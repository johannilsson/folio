import Foundation
import FolioKit
import Testing

@Suite struct SidecarTests {
    /// The annotation from folio-sidecar-spec.md, as an agent writes it.
    let json = """
    {
      "version": 1,
      "annotations": [{
        "id": "ann_lf4k2a9x",
        "kind": "replace",
        "source": "agent",
        "author": "claude",
        "context_before": "limits are stored in Redis and shared across",
        "target": "all gateway replicas",
        "replacement": "all gateway replicas and survive restarts",
        "comment": "The original omitted restart durability, which is a key property.",
        "created": "2026-05-29T10:00:00Z",
        "resolved": false,
        "replies": [{
          "id": "reply-1748908800000",
          "author": "me",
          "source": "local",
          "body": "Good catch — I'll check with the infra team first.",
          "created": "2026-06-01T08:00:00Z"
        }]
      }]
    }
    """

    @Test func parsesTheSpecExample() throws {
        let sidecar = try Sidecar.parse(json)
        #expect(sidecar.version == 1)
        let annotation = try #require(sidecar.annotations.first)
        #expect(annotation.kind == .replace)
        #expect(annotation.contextBefore == "limits are stored in Redis and shared across")
        #expect(annotation.resolvedAs == nil)
        #expect(annotation.replies?.map(\.author) == ["me"])
        #expect(annotation.summary == "\"all gateway replicas\" → \"all gateway replicas and survive restarts\"")
    }

    @Test func keepsAKindItDoesNotKnow() throws {
        let sidecar = try Sidecar.parse(json.replacingOccurrences(of: "\"replace\"", with: "\"move\""))
        let kind = try #require(sidecar.annotations.first?.kind)
        #expect(kind == .unknown("move"))
        #expect(String(decoding: try JSONEncoder().encode(kind), as: UTF8.self) == "\"move\"")
    }
}
