//! Where a file's sidecar lives: `<root>/.folio/<file relative to root>.folio`, where `root`
//! is the file's git root, else its folder. The CLI, sets, the MCP server and the app all use it.

use std::path::{Component, Path, PathBuf};

/// The file as an absolute path: canonical when it exists.
pub(crate) fn absolute(file: &Path) -> PathBuf {
    dunce::canonicalize(file).unwrap_or_else(|_| {
        if file.is_absolute() {
            file.to_path_buf()
        } else {
            std::env::current_dir().expect("cannot read cwd").join(file)
        }
    })
}

/// `<root>/.folio/<file relative to root>.folio`, where `root` is the file's git root (or its
/// own folder when there is none). Sets and the macOS app use the same rule, so every entry
/// point finds the same sidecar wherever the command is run from.
pub fn folio_path(file: &Path) -> PathBuf {
    let file = absolute(file);
    folio_path_in(&detect_root(&file), &file)
}

/// Nearest ancestor of `file` that contains `.git` (a directory, or a file for
/// worktrees); falls back to the file's own directory.
pub fn detect_root(file: &Path) -> PathBuf {
    let parent = file.parent().unwrap_or(Path::new("/")).to_path_buf();
    parent
        .ancestors()
        .find(|dir| dir.join(".git").exists())
        .map(Path::to_path_buf)
        .unwrap_or(parent)
}

/// `<root>/.folio/<file relative to root>.folio` — what `folio annotate` writes
/// when run from `root`. Files outside `root` fall back to their absolute path
/// under `.folio/`, like `folio_path`.
pub fn folio_path_in(root: &Path, file: &Path) -> PathBuf {
    // Without its root (`/`, or `C:\` on Windows), or joining it would replace `root`.
    let relative: PathBuf = match file.strip_prefix(root) {
        Ok(relative) => relative.to_path_buf(),
        Err(_) => file.components().filter(|c| !matches!(c, Component::Prefix(_) | Component::RootDir)).collect(),
    };
    let dir = relative.parent().unwrap_or(Path::new(""));
    let name = relative.file_name().unwrap().to_string_lossy();
    root.join(".folio").join(dir).join(format!("{}.folio", name))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-location-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dunce::canonicalize(dir).unwrap()
    }

    #[test]
    fn the_sidecar_is_at_the_repo_root_not_where_the_command_runs() {
        let tmp = temp_dir("root");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        std::fs::create_dir_all(tmp.join("docs/deep")).unwrap();
        let file = tmp.join("docs/deep/spec.md");
        std::fs::write(&file, "# x\n").unwrap();
        assert_eq!(folio_path(&file), tmp.join(".folio/docs/deep/spec.md.folio"));
    }

    #[test]
    fn without_a_repo_the_sidecar_is_in_the_files_folder() {
        let tmp = temp_dir("norepo");
        std::fs::create_dir_all(tmp.join("notes")).unwrap();
        let file = tmp.join("notes/a.md");
        std::fs::write(&file, "# x\n").unwrap();
        let path = folio_path(&file);
        // The temp folder is outside any repo, so the folder itself is the root.
        assert!(path == tmp.join("notes/.folio/a.md.folio") || path.to_string_lossy().contains("/.folio/"));
    }

    #[test]
    fn detect_root_finds_git_dir() {
        let tmp = temp_dir("gitdir");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        std::fs::create_dir_all(tmp.join("docs/deep")).unwrap();
        let file = tmp.join("docs/deep/a.md");
        assert_eq!(detect_root(&file), tmp);
    }

    #[test]
    fn detect_root_accepts_git_file_for_worktrees() {
        let tmp = temp_dir("gitfile");
        std::fs::write(tmp.join(".git"), "gitdir: /elsewhere").unwrap();
        std::fs::create_dir_all(tmp.join("docs")).unwrap();
        assert_eq!(detect_root(&tmp.join("docs/a.md")), tmp);
    }

    #[test]
    fn detect_root_falls_back_to_parent() {
        let tmp = temp_dir("nogit");
        std::fs::create_dir_all(tmp.join("notes")).unwrap();
        // temp dir lives outside any repo, so no .git is found above it
        let file = tmp.join("notes/a.md");
        let root = detect_root(&file);
        assert!(root == tmp.join("notes") || root.join(".git").exists());
    }

    #[test]
    fn sidecar_path_is_relative_to_root() {
        let root = Path::new("/r/repo");
        assert_eq!(
            folio_path_in(root, Path::new("/r/repo/docs/spec.md")),
            PathBuf::from("/r/repo/.folio/docs/spec.md.folio")
        );
        assert_eq!(
            folio_path_in(root, Path::new("/r/repo/spec.md")),
            PathBuf::from("/r/repo/.folio/spec.md.folio")
        );
        // A file outside the root keeps its whole path, inside `.folio/`.
        let outside = if cfg!(windows) { r"C:\elsewhere\spec.md" } else { "/elsewhere/spec.md" };
        assert_eq!(folio_path_in(root, Path::new(outside)), root.join(".folio").join("elsewhere").join("spec.md.folio"));
    }
}
