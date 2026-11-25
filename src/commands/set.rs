use crate::set;
use std::path::PathBuf;

pub fn add(name: &str, files: &[PathBuf], folders: &[PathBuf], root: Option<&PathBuf>, references: &[String]) -> anyhow::Result<()> {
    if !references.is_empty() && folders.is_empty() {
        anyhow::bail!("--references needs --folder");
    }
    if !files.is_empty() {
        let outcome = set::add_files(name, files, root.map(|r| r.as_path()))?;
        report(&outcome, "");
    }
    if !folders.is_empty() {
        report(&set::add_folders(name, folders)?, "folder ");
        if !references.is_empty() {
            for folder in folders {
                set::change_references(name, folder, references, &[])?;
            }
        }
    }
    Ok(())
}

fn report(outcome: &set::AddOutcome, what: &str) {
    for path in &outcome.added {
        println!("Added {}{}", what, path.display());
    }
    for path in &outcome.already {
        println!("Already in set: {}{}", what, path.display());
    }
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

pub fn list(name: Option<&str>, files: bool, json: bool) -> anyhow::Result<()> {
    if (files || json) && name.is_none() {
        anyhow::bail!("--files and --json need a set name");
    }
    match name {
        Some(name) if files => list_files(name, json)?,
        Some(name) => {
            let loaded = set::load(name)?;
            for entry in &loaded.files {
                println!("{}  {}  (root: {})", entry.id, entry.path.display(), set::resolve_root(entry).display());
            }
            for folder in &loaded.folders {
                let count = set::folder_files(folder).len();
                if folder.references.is_empty() {
                    println!("{}  {}  (folder, {} files)", folder.id, folder.path.display(), count);
                } else {
                    let refs = set::reference_files(folder).len();
                    println!("{}  {}  (folder, {} files, {} references)", folder.id, folder.path.display(), count, refs);
                }
            }
        }
        None => {
            for name in set::list_names()? {
                match set::load(&name) {
                    Ok(s) if !s.folders.is_empty() => println!("{}  ({} files, {} folders)", name, s.files.len(), s.folders.len()),
                    Ok(s) => println!("{}  ({} files)", name, s.files.len()),
                    Err(_) => println!("{}  (0 files)", name),
                }
            }
        }
    }
    Ok(())
}

/// One entry per member and reference file of each folder: what `folio items --set` reads, and the reference files.
fn list_files(name: &str, json: bool) -> anyhow::Result<()> {
    let loaded = set::load(name)?;
    let mut entries = Vec::new();
    for folder in &loaded.folders {
        for file in set::folder_files(folder) {
            entries.push(serde_json::json!({
                "kind": "member",
                "id": file.id,
                "path": file.path,
                "from_folder": folder.path,
                "root": file.described.root,
                "folio_path": file.described.folio_path,
                "missing": !file.path.exists(),
            }));
        }
        for path in set::reference_files(folder) {
            entries.push(serde_json::json!({
                "kind": "reference",
                "id": format!("r{}", set::path_id(&path)),
                "path": path,
                "from_folder": folder.path,
                "missing": !path.exists(),
            }));
        }
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&entries)?);
    } else {
        for e in &entries {
            println!("{}  {}  {}", e["kind"].as_str().unwrap_or(""), e["id"].as_str().unwrap_or(""), e["path"].as_str().unwrap_or(""));
        }
    }
    Ok(())
}

/// Show, add and remove the reference extensions of a set folder.
pub fn references(name: &str, folder: &PathBuf, add: &[String], remove: &[String]) -> anyhow::Result<()> {
    let now = if add.is_empty() && remove.is_empty() {
        let canonical = dunce::canonicalize(folder).unwrap_or_else(|_| folder.clone());
        set::load(name)?
            .folders
            .into_iter()
            .find(|f| f.path == canonical)
            .ok_or_else(|| anyhow::anyhow!("{} is not a folder of set {}", folder.display(), name))?
            .references
    } else {
        set::change_references(name, folder, add, remove)?
    };
    println!("{}", now.join(","));
    Ok(())
}

/// The tags that make a set's task items open ones, with colours, after adding and removing some.
pub fn tags(name: &str, add: &[String], remove: &[String]) -> anyhow::Result<()> {
    let tags = if add.is_empty() && remove.is_empty() { set::load(name)?.open_tags() } else { set::change_tags(name, add, remove)? };
    for tag in tags {
        println!("#{}  {}  ({})", tag.name, tag.label, tag.color);
    }
    Ok(())
}
