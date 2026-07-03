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
    let unanchorable: Vec<(String, String)> = if let Ok(content) = std::fs::read_to_string(file) {
        s.annotations
            .iter()
            .filter(|a| !a.resolved && a.anchor(&content).is_none())
            .map(|a| (a.id.clone(), a.kind.to_string()))
            .collect()
    } else {
        vec![]
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
