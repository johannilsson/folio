use crate::sidecar::Sidecar;
use std::path::Path;

pub fn run(file: &Path) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
    if folio_path.exists() {
        return Ok(());
    }
    if let Some(parent) = folio_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Sidecar::empty().save(&folio_path)?;
    println!("Created {}", folio_path.display());
    Ok(())
}
