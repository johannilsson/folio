use crate::sidecar::Sidecar;
use std::path::Path;
use std::process;
use serde_json::json;

fn warn_adjacent_sidecar(file: &Path, folio_path: &Path) {
    let ext = file.extension().unwrap_or_default().to_string_lossy();
    let adjacent = file.with_extension(format!("{}.folio", ext));
    if adjacent.exists() {
        let adjacent_canonical = adjacent.canonicalize().ok();
        let folio_canonical = folio_path.canonicalize().ok();
        if adjacent_canonical != folio_canonical {
            eprintln!(
                "warning: found adjacent sidecar {} — this file is ignored; active sidecar is {}",
                adjacent.display(),
                folio_path.display()
            );
        }
    }
}

/// `(id, kind)` of each unresolved annotation that cannot anchor in `content`.
fn unanchorable(s: &Sidecar, content: &str) -> Vec<(String, String)> {
    s.annotations
        .iter()
        .filter(|a| !a.resolved && a.anchor(content).is_none())
        .map(|a| (a.id.clone(), a.kind.to_string()))
        .collect()
}

pub fn run(file: &Path, json: bool) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
    warn_adjacent_sidecar(file, &folio_path);
    let s = match Sidecar::load(&folio_path) {
        Ok(s) => s,
        Err(e) => {
            if json {
                println!("{}", json!({ "valid": false, "error": e.to_string() }));
            } else {
                eprintln!("error: {}", e);
            }
            process::exit(3);
        }
    };

    // Check that every unresolved annotation can anchor in the source document.
    let unanchorable = match std::fs::read_to_string(file) {
        Ok(content) => unanchorable(&s, &content),
        Err(_) => vec![],
    };

    if unanchorable.is_empty() {
        if json {
            println!("{}", json!({ "valid": true, "annotations": s.annotations.len() }));
        } else {
            println!(
                "{}  valid  ({} annotations)",
                folio_path.display(),
                s.annotations.len()
            );
        }
        Ok(())
    } else {
        if json {
            let ids: Vec<&str> = unanchorable.iter().map(|(id, _)| id.as_str()).collect();
            println!(
                "{}",
                json!({ "valid": false, "annotations": s.annotations.len(), "unanchorable": ids })
            );
        } else {
            for (id, kind) in &unanchorable {
                eprintln!("error: {} ({}): cannot anchor — context_before + target not found in rendered document", id, kind);
            }
        }
        process::exit(3);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-check-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    /// A file with a sidecar holding a `delete` of "world" and a `highlight` of "Hello".
    fn setup(tag: &str) -> (PathBuf, Sidecar) {
        let tmp = temp_dir(tag);
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let file = tmp.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();
        super::super::annotate::run(&file, "delete", "Hello ", Some("world"), None, None, "bot", "agent").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let s = Sidecar::load(&super::super::folio_path(&file)).unwrap();
        (file, s)
    }

    #[test]
    fn annotations_that_anchor_are_not_reported() {
        let (_, s) = setup("anchored");
        assert!(unanchorable(&s, "Hello world.\n").is_empty());
    }

    #[test]
    fn an_annotation_whose_text_is_gone_is_reported_with_its_kind() {
        let (_, s) = setup("gone");
        let found = unanchorable(&s, "Hello there.\n");
        assert_eq!(found, vec![(s.annotations[0].id.clone(), "delete".to_string())]);
    }

    #[test]
    fn resolved_annotations_are_not_checked() {
        let (_, mut s) = setup("resolved");
        s.annotations[0].resolved = true;
        assert!(unanchorable(&s, "Hello there.\n").is_empty());
    }
}
