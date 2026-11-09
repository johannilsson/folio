use crate::sidecar::Sidecar;
use std::path::Path;

/// Print what changed on a file's annotations since a time, as JSON (see `changes`).
pub fn run(file: &Path, since: Option<&str>, exclude_author: Option<&str>) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    let sidecar = if folio_path.exists() { Sidecar::load(&folio_path)? } else { Sidecar::empty() };
    println!("{}", serde_json::to_string_pretty(&crate::changes::report(&sidecar, since, exclude_author))?);
    Ok(())
}
