use crate::set;
use std::path::PathBuf;

pub fn add(name: &str, files: &[PathBuf], root: Option<&PathBuf>) -> anyhow::Result<()> {
    let outcome = set::add_files(name, files, root.map(|r| r.as_path()))?;
    for path in &outcome.added {
        println!("Added {}", path.display());
    }
    for path in &outcome.already {
        println!("Already in set: {}", path.display());
    }
    Ok(())
}

pub fn rm(name: &str, files: &[PathBuf]) -> anyhow::Result<()> {
    if files.is_empty() {
        set::delete(name)?;
        println!("Deleted set {}", name);
        return Ok(());
    }
    for path in set::remove_files(name, files)? {
        println!("Removed {}", path.display());
    }
    Ok(())
}

pub fn list(name: Option<&str>) -> anyhow::Result<()> {
    match name {
        Some(name) => {
            for entry in set::load(name)?.files {
                println!("{}  {}  (root: {})", entry.id, entry.path.display(), set::resolve_root(&entry).display());
            }
        }
        None => {
            for name in set::list_names()? {
                let count = set::load(&name).map(|s| s.files.len()).unwrap_or(0);
                println!("{}  ({} files)", name, count);
            }
        }
    }
    Ok(())
}
