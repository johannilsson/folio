use crate::sidecar::Sidecar;
use std::path::Path;
use std::process;

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
    match Sidecar::load(&folio_path) {
        Ok(s) => {
            if json {
                println!(
                    "{}",
                    serde_json::json!({
                        "valid": true,
                        "annotations": s.annotations.len()
                    })
                );
            } else {
                println!(
                    "{}  valid  ({} annotations)",
                    folio_path.display(),
                    s.annotations.len()
                );
            }
            Ok(())
        }
        Err(e) => {
            if json {
                println!("{}", serde_json::json!({ "valid": false, "error": e.to_string() }));
            } else {
                eprintln!("error: {}", e);
            }
            process::exit(3);
        }
    }
}
