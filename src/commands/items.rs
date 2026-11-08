use crate::set;
use crate::wiki::{open_items, OpenItem};
use serde::Serialize;
use std::path::PathBuf;

/// An open item and the file it is in.
#[derive(Serialize)]
struct Found {
    file: PathBuf,
    #[serde(flatten)]
    item: OpenItem,
}

/// The files to read: those named, and every markdown file of the set (its folders as they are on disk).
fn files(files: &[PathBuf], set_name: Option<&str>) -> anyhow::Result<Vec<PathBuf>> {
    let mut all: Vec<PathBuf> = files.to_vec();
    if let Some(name) = set_name {
        let loaded = set::load(name)?;
        all.extend(loaded.files.iter().map(|f| f.path.clone()));
        for folder in &loaded.folders {
            all.extend(set::folder_files(folder).into_iter().map(|f| f.path));
        }
    }
    Ok(all)
}

/// Print the open items (`#investigate`, `#waiting`, `#replied`) of some files, or of a set.
pub fn run(named: &[PathBuf], set_name: Option<&str>, tag: Option<&str>, json: bool) -> anyhow::Result<()> {
    let mut found = Vec::new();
    for file in files(named, set_name)? {
        let text = std::fs::read_to_string(&file).map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
        found.extend(open_items(&text).into_iter().filter(|i| tag.map_or(true, |t| i.tag == t)).map(|item| Found { file: file.clone(), item }));
    }
    if json {
        println!("{}", serde_json::to_string_pretty(&found)?);
        return Ok(());
    }
    for Found { file, item } in &found {
        println!("{:<11} {}:{}  {}", item.tag, file.display(), item.line, item.text);
        for (label, value) in [("url", &item.url), ("link", &item.folio), ("note", &item.note)] {
            if let Some(value) = value {
                println!("{:<11} {}: {}", "", label, value);
            }
        }
    }
    if found.is_empty() {
        println!("No open items");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_set_is_its_files_and_the_markdown_of_its_folders() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = dunce::canonicalize(std::env::temp_dir()).unwrap().join(format!("folio-items-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("wiki/research")).unwrap();
        std::fs::write(tmp.join("spec.md"), "- [ ] a #waiting\n").unwrap();
        std::fs::write(tmp.join("wiki/index.md"), "- [ ] b #investigate\n").unwrap();
        std::fs::write(tmp.join("wiki/research/r.md"), "- [ ] c #replied\n").unwrap();
        std::fs::write(tmp.join("wiki/notes.txt"), "- [ ] not markdown #waiting\n").unwrap();
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));
        set::add_files("s", &[tmp.join("spec.md")], None).unwrap();
        set::add_folders("s", &[tmp.join("wiki")]).unwrap();

        let all = files(&[], Some("s")).unwrap();
        let names: Vec<_> = all.iter().map(|p| p.strip_prefix(&tmp).unwrap().to_string_lossy().replace('\\', "/")).collect();
        assert_eq!(names, ["spec.md", "wiki/index.md", "wiki/research/r.md"]);
        // Files named too, and a set that is not there is an error.
        assert_eq!(files(&[tmp.join("other.md")], None).unwrap().len(), 1);
        assert!(files(&[], Some("nope")).is_err());
        assert!(run(&[tmp.join("missing.md")], None, None, true).is_err());
        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&tmp).ok();
    }
}

