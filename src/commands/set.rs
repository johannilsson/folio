use crate::set;
use std::path::PathBuf;

pub fn add(name: &str, files: &[PathBuf], root: Option<&PathBuf>) -> anyhow::Result<()> {
    let root = match root {
        Some(r) => Some(
            r.canonicalize()
                .map_err(|e| anyhow::anyhow!("cannot read root {}: {}", r.display(), e))?,
        ),
        None => None,
    };
    let mut current = set::load(name).unwrap_or_else(|_| set::Set::empty());
    for file in files {
        let canonical = file
            .canonicalize()
            .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
        if !canonical.is_file() {
            anyhow::bail!("{} is not a file", file.display());
        }
        if current.add(canonical.clone(), root.clone()) {
            println!("Added {}", canonical.display());
        } else {
            println!("Already in set: {}", canonical.display());
        }
    }
    set::save(name, &current)
}

pub fn rm(name: &str, files: &[PathBuf]) -> anyhow::Result<()> {
    if files.is_empty() {
        set::delete(name)?;
        println!("Deleted set {}", name);
        return Ok(());
    }
    let mut current = set::load(name)?;
    for file in files {
        // The file may no longer exist, so fall back to the path as given.
        let path = file.canonicalize().unwrap_or_else(|_| file.clone());
        if current.remove(&path) {
            println!("Removed {}", path.display());
        } else {
            anyhow::bail!("{} is not in set {}", path.display(), name);
        }
    }
    set::save(name, &current)
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
