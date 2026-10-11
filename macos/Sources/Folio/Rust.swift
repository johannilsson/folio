import CFolio
import Foundation

struct RustError: Error, CustomStringConvertible {
    let description: String
}

/// Swift face of libfolio (src/ffi.rs): the same anchoring and accept code the CLI and
/// the HTTP server use.
enum Rust {
    static func sidecarPath(for file: String) throws -> String {
        try take(folio_sidecar_path(file))
    }

    /// `items` is the JSON request body of `/api/anchor`; the result is its JSON response.
    static func anchor(doc: String, itemsJSON: String, raw: Bool) throws -> String {
        try take(folio_anchor(doc, itemsJSON, raw))
    }

    /// The patched markdown (nil when accepting changes nothing in it) and the new
    /// sidecar text.
    static func accept(doc: String, sidecarJSON: String, id: String) throws -> (doc: String?, sidecar: String) {
        let out = try take(folio_accept(doc, sidecarJSON, id))
        guard let obj = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let sidecar = obj["sidecar"] as? String else {
            throw RustError(description: "unexpected accept result")
        }
        return (obj["doc"] as? String, sidecar)
    }

    /// Copies the result out, frees it, and turns `{"error": ...}` into a thrown error.
    private static func take(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
        guard let ptr else { throw RustError(description: "libfolio returned null") }
        defer { folio_free(ptr) }
        let text = String(cString: ptr)
        if text.hasPrefix("{\"error\""),
           let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let message = obj["error"] as? String {
            throw RustError(description: message)
        }
        return text
    }
}
