//! C API for the native macOS shell. Strings in, JSON strings out: Swift does all
//! file IO and calls these for the anchoring and accept logic, so there is one
//! implementation shared with the CLI and the server.

use crate::commands::accept::{apply_ops, compute_ops, mark_accepted};
use crate::set::{detect_root, folio_path_in};
use crate::sidecar::{anchor_chars, anchor_raw_chars, Sidecar};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;

#[derive(Deserialize)]
struct AnchorRequestItem {
    id: String,
    context_before: String,
    #[serde(default)]
    target: Option<String>,
}

#[derive(Serialize)]
struct AnchorResultItem {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    char_from: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    char_to: Option<usize>,
}

/// Same request and response shape as `POST /api/anchor` (and `/api/anchor-raw`
/// when `raw`).
fn anchor_json(doc: &str, items_json: &str, raw: bool) -> Result<String, String> {
    let items: Vec<AnchorRequestItem> = serde_json::from_str(items_json).map_err(|e| e.to_string())?;
    let results: Vec<AnchorResultItem> = items
        .iter()
        .map(|item| {
            let found = if raw {
                anchor_raw_chars(doc, &item.context_before, item.target.as_deref())
            } else {
                anchor_chars(doc, &item.context_before, item.target.as_deref())
            };
            AnchorResultItem {
                id: item.id.clone(),
                char_from: found.map(|(f, _)| f),
                char_to: found.map(|(_, t)| t),
            }
        })
        .collect();
    serde_json::to_string(&results).map_err(|e| e.to_string())
}

/// Accept one pending annotation, as `POST /api/accept` does. Returns the patched
/// document (null when accepting changes nothing in the markdown) and the sidecar
/// (serialized exactly as `Sidecar::save` writes it).
fn accept_json(doc: &str, sidecar_json: &str, id: &str) -> Result<String, String> {
    let mut sidecar: Sidecar = serde_json::from_str(sidecar_json).map_err(|e| e.to_string())?;
    let idx = sidecar
        .annotations
        .iter()
        .position(|a| a.id == id && !a.resolved)
        .ok_or("no pending annotation with that id")?;
    let ops = compute_ops(doc, &sidecar, &[idx])?;
    let new_doc = if ops.is_empty() {
        None
    } else {
        Some(apply_ops(doc, ops))
    };
    mark_accepted(&mut sidecar, &[idx]);
    let sidecar_out = serde_json::to_string_pretty(&sidecar).map_err(|e| e.to_string())?;
    Ok(json!({ "doc": new_doc, "sidecar": sidecar_out }).to_string())
}

/// Where the sidecar for `file` lives: `<git root or file's folder>/.folio/<relative path>.folio`.
fn sidecar_path(file: &str) -> String {
    let file = Path::new(file);
    folio_path_in(&detect_root(file), file).to_string_lossy().into_owned()
}

fn finish(result: Result<String, String>) -> *mut c_char {
    let text = result.unwrap_or_else(|e| json!({ "error": e }).to_string());
    CString::new(text).unwrap_or_default().into_raw()
}

unsafe fn arg<'a>(p: *const c_char) -> Result<&'a str, String> {
    if p.is_null() {
        return Err("null argument".to_string());
    }
    CStr::from_ptr(p).to_str().map_err(|e| e.to_string())
}

/// Returns a JSON array of anchor results, or `{"error": ...}`. Free with `folio_free`.
///
/// # Safety
/// `doc` and `items_json` must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn folio_anchor(doc: *const c_char, items_json: *const c_char, raw: bool) -> *mut c_char {
    finish((|| anchor_json(arg(doc)?, arg(items_json)?, raw))())
}

/// Returns `{"doc": <string|null>, "sidecar": <string>}` or `{"error": ...}`.
/// Free with `folio_free`.
///
/// # Safety
/// All arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn folio_accept(doc: *const c_char, sidecar_json: *const c_char, id: *const c_char) -> *mut c_char {
    finish((|| accept_json(arg(doc)?, arg(sidecar_json)?, arg(id)?))())
}

/// Returns the sidecar path as a plain string, or `{"error": ...}`. Free with `folio_free`.
///
/// # Safety
/// `file` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn folio_sidecar_path(file: *const c_char) -> *mut c_char {
    finish((|| Ok(sidecar_path(arg(file)?)))())
}

/// Frees a string returned by any `folio_*` function.
///
/// # Safety
/// `ptr` must come from this library and not have been freed already.
#[no_mangle]
pub unsafe extern "C" fn folio_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    const DOC: &str = "# Title\n\nThe quick **brown** fox jumps.\n";

    #[test]
    fn anchor_matches_direct_call_in_both_modes() {
        let items = r#"[{"id":"a","context_before":"The quick ","target":"brown"},{"id":"b","context_before":"nothing like this","target":"x"}]"#;
        for raw in [false, true] {
            let out: Vec<Value> = serde_json::from_str(&anchor_json(DOC, items, raw).unwrap()).unwrap();
            let direct = if raw {
                anchor_raw_chars(DOC, "The quick ", Some("brown"))
            } else {
                anchor_chars(DOC, "The quick ", Some("brown"))
            }
            .unwrap();
            assert_eq!(out[0]["char_from"], direct.0);
            assert_eq!(out[0]["char_to"], direct.1);
            assert!(out[1].get("char_from").is_none());
        }
    }

    fn sidecar_with(kind: &str, extra: &str) -> String {
        format!(
            r#"{{"version":1,"annotations":[{{"id":"x1","kind":"{kind}","source":"agent","author":"a","context_before":"The quick **brown** ","created":"2026-01-01T00:00:00Z","resolved":false{extra}}}]}}"#
        )
    }

    #[test]
    fn accept_replace_patches_doc_and_resolves() {
        let sc = sidecar_with("replace", r#","target":"fox","replacement":"dog""#);
        let out: Value = serde_json::from_str(&accept_json(DOC, &sc, "x1").unwrap()).unwrap();
        assert_eq!(out["doc"], "# Title\n\nThe quick **brown** dog jumps.\n");
        let saved: Sidecar = serde_json::from_str(out["sidecar"].as_str().unwrap()).unwrap();
        assert!(saved.annotations[0].resolved);
        assert_eq!(saved.annotations[0].resolved_as.as_deref(), Some("accepted"));
    }

    #[test]
    fn accept_comment_leaves_doc_alone() {
        let sc = sidecar_with("comment", r#","target":"fox","comment":"hm""#);
        let out: Value = serde_json::from_str(&accept_json(DOC, &sc, "x1").unwrap()).unwrap();
        assert!(out["doc"].is_null());
    }

    #[test]
    fn accept_errors_are_reported() {
        let sc = sidecar_with("replace", r#","target":"fox","replacement":"dog""#);
        assert!(accept_json(DOC, &sc, "missing").unwrap_err().contains("no pending"));
        let unanchored = sc.replace("fox", "wolf");
        assert!(accept_json(DOC, &unanchored, "x1").unwrap_err().contains("anchoring failed"));
    }

    #[test]
    fn sidecar_path_uses_git_root() {
        let dir = std::env::temp_dir().join(format!("folio-ffi-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::create_dir_all(dir.join("docs")).unwrap();
        let file = dir.join("docs/a.md");
        assert_eq!(
            sidecar_path(file.to_str().unwrap()),
            dir.join(".folio/docs/a.md.folio").to_string_lossy()
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn extern_wrappers_report_errors() {
        unsafe {
            let doc = CString::new(DOC).unwrap();
            let bad = CString::new("not json").unwrap();
            let p = folio_anchor(doc.as_ptr(), bad.as_ptr(), false);
            let text = CStr::from_ptr(p).to_str().unwrap().to_string();
            folio_free(p);
            assert!(serde_json::from_str::<Value>(&text).unwrap().get("error").is_some());

            let p = folio_sidecar_path(std::ptr::null());
            assert!(CStr::from_ptr(p).to_str().unwrap().contains("error"));
            folio_free(p);
        }
    }
}
