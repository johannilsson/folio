pub mod accept;
pub mod annotate;
pub mod check;
pub mod init;
pub mod open;
pub mod reject;
pub mod render;
pub mod review;
pub mod set;

use std::path::{Path, PathBuf};

/// The file as an absolute path: canonical when it exists.
fn absolute(file: &Path) -> PathBuf {
    file.canonicalize().unwrap_or_else(|_| {
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
    crate::set::folio_path_in(&crate::set::detect_root(&file), &file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-path-{}-{}-{}",
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

}
