use serde::{Deserialize, Serialize};
use crate::location::{detect_root, folio_path_in};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetFile {
    pub id: String,
    pub path: PathBuf,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub root: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Set {
    pub version: u32,
    pub files: Vec<SetFile>,
}

impl Set {
    pub fn empty() -> Self {
        Self { version: 1, files: Vec::new() }
    }

    /// Add `path` (already canonical) unless present. Returns false for duplicates.
    pub fn add(&mut self, path: PathBuf, root: Option<PathBuf>) -> bool {
        if self.files.iter().any(|f| f.path == path) {
            return false;
        }
        let mut id = path_id(&path);
        while self.files.iter().any(|f| f.id == id) {
            id.push('x');
        }
        self.files.push(SetFile { id, path, root });
        true
    }

    /// Remove `path`. Returns false if it was not in the set.
    pub fn remove(&mut self, path: &Path) -> bool {
        let before = self.files.len();
        self.files.retain(|f| f.path != path);
        self.files.len() != before
    }
}

/// Stable short id derived from the path (FNV-1a), so re-adding a file after
/// removing it gives the same URL.
fn path_id(path: &Path) -> String {
    let mut hash: u64 = 0xcbf29ce484222325;
    for b in path.to_string_lossy().bytes() {
        hash ^= b as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", hash & 0xffff_ffff)
}

pub fn config_dir() -> anyhow::Result<PathBuf> {
    if let Some(d) = std::env::var_os("FOLIO_CONFIG_DIR").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(d));
    }
    if let Some(d) = std::env::var_os("XDG_CONFIG_HOME").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(d).join("folio"));
    }
    // Windows has no HOME of its own; the app data folder is where config goes.
    #[cfg(windows)]
    if let Some(d) = std::env::var_os("APPDATA").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(d).join("folio"));
    }
    let home = std::env::var_os("HOME")
        .ok_or_else(|| anyhow::anyhow!("cannot locate config dir: HOME is not set"))?;
    Ok(PathBuf::from(home).join(".config").join("folio"))
}

fn sets_dir() -> anyhow::Result<PathBuf> {
    Ok(config_dir()?.join("sets"))
}

fn validate_name(name: &str) -> anyhow::Result<()> {
    let ok = !name.is_empty()
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
        && !name.starts_with('.');
    if !ok {
        anyhow::bail!("invalid set name '{}': use letters, digits, '-', '_' and '.'", name);
    }
    Ok(())
}

pub fn set_path(name: &str) -> anyhow::Result<PathBuf> {
    validate_name(name)?;
    Ok(sets_dir()?.join(format!("{}.json", name)))
}

pub fn load(name: &str) -> anyhow::Result<Set> {
    let path = set_path(name)?;
    let content = std::fs::read_to_string(&path)
        .map_err(|e| anyhow::anyhow!("cannot read set '{}' ({}): {}", name, path.display(), e))?;
    let set: Set = serde_json::from_str(&content)
        .map_err(|e| anyhow::anyhow!("invalid set file {}: {}", path.display(), e))?;
    if set.version != 1 {
        anyhow::bail!("unsupported set version {} (expected 1)", set.version);
    }
    Ok(set)
}

pub fn save(name: &str, set: &Set) -> anyhow::Result<()> {
    let path = set_path(name)?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(set)?)?;
    Ok(())
}

pub fn delete(name: &str) -> anyhow::Result<()> {
    let path = set_path(name)?;
    std::fs::remove_file(&path)
        .map_err(|e| anyhow::anyhow!("cannot delete set '{}': {}", name, e))
}

pub fn list_names() -> anyhow::Result<Vec<String>> {
    let dir = sets_dir()?;
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Ok(Vec::new());
    };
    let mut names: Vec<String> = entries
        .filter_map(|e| e.ok())
        .filter_map(|e| {
            let p = e.path();
            if p.extension()? == "json" {
                Some(p.file_stem()?.to_string_lossy().to_string())
            } else {
                None
            }
        })
        .collect();
    names.sort();
    Ok(names)
}

pub fn resolve_root(entry: &SetFile) -> PathBuf {
    entry.root.clone().unwrap_or_else(|| detect_root(&entry.path))
}

/// How a set file is shown and where its sidecar lives.
pub struct Described {
    /// Path relative to the root.
    pub name: String,
    /// Root directory name, used to group files.
    pub group: String,
    pub folio_path: PathBuf,
}

pub fn describe(entry: &SetFile) -> Described {
    let root = resolve_root(entry);
    Described {
        name: entry.path.strip_prefix(&root).unwrap_or(&entry.path).to_string_lossy().to_string(),
        group: root.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default(),
        folio_path: folio_path_in(&root, &entry.path),
    }
}

/// What `add_files` did with each path.
pub struct AddOutcome {
    pub added: Vec<PathBuf>,
    pub already: Vec<PathBuf>,
}

/// Add files to the set `name`, creating it if needed. Paths are canonicalised; a
/// missing or non-file path fails before anything is saved.
pub fn add_files(name: &str, files: &[PathBuf], root: Option<&Path>) -> anyhow::Result<AddOutcome> {
    let root = match root {
        Some(r) => Some(
            r.canonicalize()
                .map_err(|e| anyhow::anyhow!("cannot read root {}: {}", r.display(), e))?,
        ),
        None => None,
    };
    let mut current = load(name).unwrap_or_else(|_| Set::empty());
    let mut outcome = AddOutcome { added: Vec::new(), already: Vec::new() };
    for file in files {
        let canonical = file
            .canonicalize()
            .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
        if !canonical.is_file() {
            anyhow::bail!("{} is not a file", file.display());
        }
        if current.add(canonical.clone(), root.clone()) {
            outcome.added.push(canonical);
        } else {
            outcome.already.push(canonical);
        }
    }
    save(name, &current)?;
    Ok(outcome)
}

/// Remove files from the set `name`; a file that is not in it is an error.
pub fn remove_files(name: &str, files: &[PathBuf]) -> anyhow::Result<Vec<PathBuf>> {
    let mut current = load(name)?;
    let mut removed = Vec::new();
    for file in files {
        // The file may no longer exist, so fall back to the path as given.
        let path = file.canonicalize().unwrap_or_else(|_| file.clone());
        if !current.remove(&path) {
            anyhow::bail!("{} is not in set {}", path.display(), name);
        }
        removed.push(path);
    }
    save(name, &current)?;
    Ok(removed)
}

// FOLIO_CONFIG_DIR is process-wide, so tests that set it (here and in ffi.rs) run one at a time.
#[cfg(test)]
pub(crate) static TEST_ENV: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
mod tests {
    use super::*;
    use TEST_ENV as ENV;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-set-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn explicit_root_overrides_detection() {
        let entry = SetFile {
            id: "x".into(),
            path: PathBuf::from("/a/b/c.md"),
            root: Some(PathBuf::from("/a")),
        };
        assert_eq!(resolve_root(&entry), PathBuf::from("/a"));
    }

    #[test]
    fn add_skips_duplicates_and_ids_are_stable() {
        let mut set = Set::empty();
        assert!(set.add(PathBuf::from("/a/x.md"), None));
        assert!(!set.add(PathBuf::from("/a/x.md"), None));
        let id = set.files[0].id.clone();
        assert!(set.remove(Path::new("/a/x.md")));
        assert!(set.add(PathBuf::from("/a/x.md"), None));
        assert_eq!(set.files[0].id, id);
        assert!(!set.remove(Path::new("/a/missing.md")));
    }

    #[test]
    fn save_load_delete_round_trip() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("cfg");
        std::env::set_var("FOLIO_CONFIG_DIR", &tmp);

        assert!(list_names().unwrap().is_empty());
        let mut set = Set::empty();
        set.add(PathBuf::from("/a/x.md"), None);
        set.add(PathBuf::from("/b/y.md"), Some(PathBuf::from("/b")));
        save("demo", &set).unwrap();

        assert_eq!(list_names().unwrap(), vec!["demo".to_string()]);
        let loaded = load("demo").unwrap();
        assert_eq!(loaded.files.len(), 2);
        assert_eq!(loaded.files[0].root, None);
        assert_eq!(loaded.files[1].root, Some(PathBuf::from("/b")));

        delete("demo").unwrap();
        assert!(load("demo").is_err());
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn add_files_reports_duplicates_and_saves_nothing_on_a_bad_path() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("addfiles");
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));
        let a = tmp.join("a.md");
        std::fs::write(&a, "# a\n").unwrap();

        let first = add_files("s", &[a.clone()], None).unwrap();
        assert_eq!(first.added, vec![a.clone()]);
        let again = add_files("s", &[a.clone()], None).unwrap();
        assert!(again.added.is_empty());
        assert_eq!(again.already, vec![a.clone()]);

        // A missing file and a folder both fail, and the good file before them is not saved.
        let b = tmp.join("b.md");
        std::fs::write(&b, "# b\n").unwrap();
        assert!(add_files("s", &[b.clone(), tmp.join("missing.md")], None).is_err());
        assert!(add_files("s", &[b.clone(), tmp.clone()], None).is_err());
        assert_eq!(load("s").unwrap().files.len(), 1);
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn remove_files_fails_for_a_file_not_in_the_set_and_saves_nothing() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("rmfiles");
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));
        let a = tmp.join("a.md");
        std::fs::write(&a, "# a\n").unwrap();
        add_files("s", &[a.clone()], None).unwrap();

        assert!(remove_files("s", &[a.clone(), tmp.join("other.md")]).is_err());
        assert_eq!(load("s").unwrap().files.len(), 1);

        // A file deleted from disk can still be removed by the path it was added with.
        std::fs::remove_file(&a).unwrap();
        assert_eq!(remove_files("s", &[a.clone()]).unwrap(), vec![a]);
        assert!(load("s").unwrap().files.is_empty());
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn load_rejects_an_unsupported_version() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("version");
        std::env::set_var("FOLIO_CONFIG_DIR", &tmp);
        save("v2", &Set { version: 2, files: Vec::new() }).unwrap();
        let err = load("v2").unwrap_err().to_string();
        assert!(err.contains("unsupported set version 2"), "{err}");
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn list_names_is_sorted_and_skips_files_that_are_not_sets() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("names");
        std::env::set_var("FOLIO_CONFIG_DIR", &tmp);
        save("zeta", &Set::empty()).unwrap();
        save("alpha", &Set::empty()).unwrap();
        std::fs::write(tmp.join("sets").join("notes.txt"), "x").unwrap();
        assert_eq!(list_names().unwrap(), vec!["alpha".to_string(), "zeta".to_string()]);
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn load_reports_a_malformed_set_file() {
        let _guard = ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = temp_dir("malformed");
        std::env::set_var("FOLIO_CONFIG_DIR", &tmp);
        std::fs::create_dir_all(tmp.join("sets")).unwrap();
        std::fs::write(tmp.join("sets").join("bad.json"), "{ not json").unwrap();
        let err = load("bad").unwrap_err().to_string();
        assert!(err.contains("invalid set file"), "{err}");
        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    #[test]
    fn rejects_bad_names() {
        assert!(validate_name("../evil").is_err());
        assert!(validate_name("").is_err());
        assert!(validate_name(".hidden").is_err());
        assert!(validate_name("checkout-redesign_2").is_ok());
    }
}
