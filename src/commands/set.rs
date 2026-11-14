use crate::set;
use std::path::PathBuf;

pub fn add(name: &str, files: &[PathBuf], folders: &[PathBuf], root: Option<&PathBuf>) -> anyhow::Result<()> {
    if !files.is_empty() {
        let outcome = set::add_files(name, files, root.map(|r| r.as_path()))?;
        report(&outcome, "");
    }
    if !folders.is_empty() {
        report(&set::add_folders(name, folders)?, "folder ");
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

pub fn list(name: Option<&str>) -> anyhow::Result<()> {
    match name {
        Some(name) => {
            let loaded = set::load(name)?;
            for entry in &loaded.files {
                println!("{}  {}  (root: {})", entry.id, entry.path.display(), set::resolve_root(entry).display());
            }
            for folder in &loaded.folders {
                println!("{}  {}  (folder, {} files)", folder.id, folder.path.display(), set::folder_files(folder).len());
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

/// The tags that make a set's task items open ones, with colours, after adding and removing some.
pub fn tags(name: &str, add: &[String], remove: &[String]) -> anyhow::Result<()> {
    let tags = if add.is_empty() && remove.is_empty() { set::load(name)?.open_tags() } else { set::change_tags(name, add, remove)? };
    for tag in tags {
        println!("#{}  {}  ({})", tag.name, tag.label, tag.color);
    }
    Ok(())
}
