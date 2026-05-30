use crate::sidecar::Sidecar;
use std::path::Path;
use std::process;

pub fn run(file: &Path, json: bool) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
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
