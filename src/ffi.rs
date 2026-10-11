//! C API for the native macOS shell. Strings in, JSON strings out: Swift does all
//! file IO and calls these for the anchoring and accept logic, so there is one
//! implementation shared with the CLI and the server.

use crate::commands::accept::{apply_ops, compute_ops, mark_accepted};
use crate::set::{self, detect_root, folio_path_in};
use crate::sidecar::{anchor_chars, anchor_raw_chars, Sidecar};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

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

fn paths_from_json(json: &str) -> Result<Vec<PathBuf>, String> {
    let paths: Vec<String> = serde_json::from_str(json).map_err(|e| e.to_string())?;
    Ok(paths.into_iter().map(PathBuf::from).collect())
}

fn path_strings(paths: &[PathBuf]) -> Vec<String> {
    paths.iter().map(|p| p.to_string_lossy().into_owned()).collect()
}

fn set_names_json() -> Result<String, String> {
    let names = set::list_names().map_err(|e| e.to_string())?;
    Ok(json!({ "names": names }).to_string())
}

/// The set's files as the app shows them, plus where its manifest lives (to watch it).
fn set_load_json(name: &str) -> Result<String, String> {
    let manifest = set::set_path(name).map_err(|e| e.to_string())?;
    let loaded = set::load(name).map_err(|e| e.to_string())?;
    let files: Vec<_> = loaded
        .files
        .iter()
        .map(|entry| {
            let described = set::describe(entry);
            json!({
                "id": entry.id,
                "name": described.name,
                "group": described.group,
                "path": entry.path,
                "folio_path": described.folio_path,
            })
        })
        .collect();
    Ok(json!({ "name": name, "manifest": manifest, "files": files }).to_string())
}

fn set_add_json(name: &str, files_json: &str, root: Option<&str>) -> Result<String, String> {
    let files = paths_from_json(files_json)?;
    let outcome = set::add_files(name, &files, root.map(Path::new)).map_err(|e| e.to_string())?;
    Ok(json!({ "added": path_strings(&outcome.added), "already": path_strings(&outcome.already) }).to_string())
}

fn set_remove_json(name: &str, files_json: &str) -> Result<String, String> {
    let removed = set::remove_files(name, &paths_from_json(files_json)?).map_err(|e| e.to_string())?;
    Ok(json!({ "removed": path_strings(&removed) }).to_string())
}

fn set_delete_json(name: &str) -> Result<String, String> {
    set::delete(name).map_err(|e| e.to_string())?;
    Ok("{}".to_string())
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

/// Returns `{"names": [...]}` or `{"error": ...}`. Free with `folio_free`.
///
/// # Safety
/// Takes no pointers.
#[no_mangle]
pub unsafe extern "C" fn folio_set_names() -> *mut c_char {
    finish(set_names_json())
}

/// Returns `{"name", "manifest", "files": [{id, name, group, path, folio_path}]}`.
/// Free with `folio_free`.
///
/// # Safety
/// `name` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn folio_set_load(name: *const c_char) -> *mut c_char {
    finish((|| set_load_json(arg(name)?))())
}

/// Adds the files in `files_json` (an array of paths) to the set, creating it if needed.
/// `root` may be null. Returns `{"added": [...], "already": [...]}`. Free with `folio_free`.
///
/// # Safety
/// `name` and `files_json` must be valid NUL-terminated UTF-8 strings; `root` null or the same.
#[no_mangle]
pub unsafe extern "C" fn folio_set_add(name: *const c_char, files_json: *const c_char, root: *const c_char) -> *mut c_char {
    finish((|| {
        let root = if root.is_null() { None } else { Some(arg(root)?) };
        set_add_json(arg(name)?, arg(files_json)?, root)
    })())
}

/// Removes the files in `files_json` from the set. Returns `{"removed": [...]}`.
/// Free with `folio_free`.
///
/// # Safety
/// All arguments must be valid NUL-terminated UTF-8 strings.
#[no_mangle]
pub unsafe extern "C" fn folio_set_remove(name: *const c_char, files_json: *const c_char) -> *mut c_char {
    finish((|| set_remove_json(arg(name)?, arg(files_json)?))())
}

/// Deletes the set (its manifest only, never the files). Returns `{}`. Free with `folio_free`.
///
/// # Safety
/// `name` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn folio_set_delete(name: *const c_char) -> *mut c_char {
    finish((|| set_delete_json(arg(name)?))())
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
    fn sets_round_trip_through_the_json_api() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = std::env::temp_dir().join(format!("folio-ffi-sets-{}", std::process::id()));
        std::fs::create_dir_all(&tmp).unwrap();
        let tmp = tmp.canonicalize().unwrap();
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));

        // Two files in separate "repos".
        let (a, b) = (tmp.join("a/alpha.md"), tmp.join("b/beta.md"));
        for file in [&a, &b] {
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::create_dir_all(file.parent().unwrap().join(".git")).unwrap();
            std::fs::write(file, "# x\n").unwrap();
        }
        let a_json = serde_json::to_string(&[a.to_string_lossy()]).unwrap();
        let both = serde_json::to_string(&[a.to_string_lossy(), b.to_string_lossy()]).unwrap();

        assert_eq!(serde_json::from_str::<Value>(&set_names_json().unwrap()).unwrap()["names"], json!([]));
        let added: Value = serde_json::from_str(&set_add_json("demo", &a_json, None).unwrap()).unwrap();
        assert_eq!(added["added"].as_array().unwrap().len(), 1);
        // Adding again reports the duplicate rather than failing; the new file is added.
        let again: Value = serde_json::from_str(&set_add_json("demo", &both, None).unwrap()).unwrap();
        assert_eq!(again["added"].as_array().unwrap().len(), 1);
        assert_eq!(again["already"].as_array().unwrap().len(), 1);

        let loaded: Value = serde_json::from_str(&set_load_json("demo").unwrap()).unwrap();
        let files = loaded["files"].as_array().unwrap();
        assert_eq!(files.len(), 2);
        assert_eq!(files[0]["name"], "alpha.md");
        assert_eq!(files[0]["group"], "a");
        assert!(files[0]["folio_path"].as_str().unwrap().ends_with("a/.folio/alpha.md.folio"));
        assert!(loaded["manifest"].as_str().unwrap().ends_with("cfg/sets/demo.json"));

        let removed: Value = serde_json::from_str(&set_remove_json("demo", &a_json).unwrap()).unwrap();
        assert_eq!(removed["removed"].as_array().unwrap().len(), 1);
        assert!(set_remove_json("demo", &a_json).unwrap_err().contains("not in set"));
        assert_eq!(serde_json::from_str::<Value>(&set_load_json("demo").unwrap()).unwrap()["files"].as_array().unwrap().len(), 1);

        set_delete_json("demo").unwrap();
        assert!(set_load_json("demo").is_err());
        assert!(set_load_json("../evil").is_err());

        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&tmp).ok();
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
