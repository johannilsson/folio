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

/// Which repo a root is a checkout of, and what it has checked out. Wiki links and the set's
/// sidebar name a repo and a branch, never a worktree's folder: folders come and go.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepoIdentity {
    /// The `origin` remote's last path segment without `.git`; with no remote, the main
    /// checkout's folder name.
    pub repo: String,
    /// The branch `HEAD` is on; a detached `HEAD` is its short commit; none when `HEAD` is unreadable.
    pub branch: Option<String>,
    /// A linked worktree of the repo, not its main checkout.
    pub worktree: bool,
}

/// Reads `root`'s repo and branch from the files in `.git`, without running `git`. None when
/// `root` is not a checkout (no `.git`).
pub fn repo_identity(root: &Path) -> Option<RepoIdentity> {
    let dot_git = root.join(".git");
    let git_dir = if dot_git.is_dir() {
        dot_git
    } else {
        // A worktree (or submodule): `.git` is a file that points at its git directory.
        let text = std::fs::read_to_string(&dot_git).ok()?;
        let target = text.lines().find_map(|l| l.strip_prefix("gitdir:"))?.trim();
        let target = Path::new(target);
        if target.is_absolute() { target.to_path_buf() } else { root.join(target) }
    };
    // A linked worktree's git directory names the shared one in `commondir`.
    let common = std::fs::read_to_string(git_dir.join("commondir"))
        .ok()
        .map(|text| git_dir.join(text.trim()));
    let worktree = common.is_some();
    let common = common.map(|c| dunce::canonicalize(&c).unwrap_or(c)).unwrap_or_else(|| git_dir.clone());

    let branch = std::fs::read_to_string(git_dir.join("HEAD")).ok().and_then(|head| {
        let head = head.trim();
        match head.strip_prefix("ref:") {
            Some(reference) => {
                let reference = reference.trim();
                Some(reference.strip_prefix("refs/heads/").unwrap_or(reference).to_string())
            }
            None if head.len() >= 7 => Some(head[..7].to_string()),
            None => None,
        }
    });

    let from_remote = std::fs::read_to_string(common.join("config"))
        .ok()
        .and_then(|config| origin_url(&config))
        .and_then(|url| repo_from_url(&url));
    let repo = from_remote.or_else(|| {
        // The main checkout's folder: above its `.git`, or the bare repository's own name.
        let name = if common.file_name().is_some_and(|n| n == ".git") { common.parent()?.file_name()? } else { common.file_name()? };
        Some(name.to_string_lossy().trim_end_matches(".git").to_string())
    })?;
    Some(RepoIdentity { repo, branch, worktree })
}

fn origin_url(config: &str) -> Option<String> {
    let mut in_origin = false;
    for line in config.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_origin = line.replace(' ', "").eq_ignore_ascii_case("[remote\"origin\"]");
        } else if in_origin {
            if let Some((key, value)) = line.split_once('=') {
                if key.trim().eq_ignore_ascii_case("url") {
                    return Some(value.trim().to_string());
                }
            }
        }
    }
    None
}

/// `git@host:team/repo.git`, `https://host/team/repo.git/` and `/srv/git/repo` all name `repo`.
fn repo_from_url(url: &str) -> Option<String> {
    let url = url.trim().trim_end_matches(['/', '\\']);
    let url = url.strip_suffix(".git").unwrap_or(url);
    let name = url.rsplit(['/', ':', '\\']).next()?;
    (!name.is_empty()).then(|| name.to_string())
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
    // A path with no file name (`/`, or one ending in `..`) must not panic the MCP server.
    let name = relative.file_name().map(|n| n.to_string_lossy()).unwrap_or_default();
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

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn a_checkout_is_named_after_its_origin_and_its_branch() {
        let tmp = temp_dir("identity");
        write(&tmp.join(".git/HEAD"), "ref: refs/heads/main\n");
        write(&tmp.join(".git/config"), "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = git@github.com:team/payments-svc.git\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n");
        assert_eq!(
            repo_identity(&tmp),
            Some(RepoIdentity { repo: "payments-svc".into(), branch: Some("main".into()), worktree: false })
        );
    }

    #[test]
    fn a_branch_with_slashes_keeps_them() {
        let tmp = temp_dir("slashes");
        write(&tmp.join(".git/HEAD"), "ref: refs/heads/fix/logout\n");
        assert_eq!(repo_identity(&tmp).unwrap().branch.as_deref(), Some("fix/logout"));
    }

    #[test]
    fn a_worktree_is_the_same_repo_on_its_own_branch() {
        let tmp = temp_dir("worktree");
        let main = tmp.join("payments-svc");
        write(&main.join(".git/HEAD"), "ref: refs/heads/main\n");
        write(&main.join(".git/config"), "[remote \"origin\"]\n\turl = https://github.com/team/svc.git\n");
        let linked = tmp.join("payments-svc-logout");
        write(&main.join(".git/worktrees/logout/HEAD"), "ref: refs/heads/fix/logout\n");
        write(&main.join(".git/worktrees/logout/commondir"), "../..\n");
        write(&linked.join(".git"), &format!("gitdir: {}\n", main.join(".git/worktrees/logout").display()));
        assert_eq!(
            repo_identity(&linked),
            Some(RepoIdentity { repo: "svc".into(), branch: Some("fix/logout".into()), worktree: true })
        );
        assert_eq!(repo_identity(&main).unwrap().branch.as_deref(), Some("main"));
    }

    #[test]
    fn without_a_remote_a_worktree_is_named_after_the_main_checkouts_folder() {
        let tmp = temp_dir("noremote");
        let main = tmp.join("payments-svc");
        write(&main.join(".git/HEAD"), "ref: refs/heads/main\n");
        let linked = tmp.join("elsewhere");
        write(&main.join(".git/worktrees/w/HEAD"), "ref: refs/heads/topic\n");
        write(&main.join(".git/worktrees/w/commondir"), "../..\n");
        write(&linked.join(".git"), &format!("gitdir: {}\n", main.join(".git/worktrees/w").display()));
        assert_eq!(repo_identity(&linked).unwrap().repo, "payments-svc");
        assert_eq!(repo_identity(&main).unwrap().repo, "payments-svc");
    }

    #[test]
    fn a_detached_head_is_its_short_commit() {
        let tmp = temp_dir("detached");
        write(&tmp.join(".git/HEAD"), "0123456789abcdef0123456789abcdef01234567\n");
        assert_eq!(repo_identity(&tmp).unwrap().branch.as_deref(), Some("0123456"));
    }

    #[test]
    fn an_empty_git_directory_is_a_repo_with_no_branch() {
        let tmp = temp_dir("emptygit");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let identity = repo_identity(&tmp).unwrap();
        assert_eq!(identity.branch, None);
        assert_eq!(Some(identity.repo.as_str()), tmp.file_name().and_then(|n| n.to_str()));
    }

    #[test]
    fn a_folder_that_is_not_a_checkout_has_no_identity() {
        let tmp = temp_dir("plain");
        assert_eq!(repo_identity(&tmp), None);
        // A `.git` file that points nowhere is not one either.
        write(&tmp.join(".git"), "not a pointer\n");
        assert_eq!(repo_identity(&tmp), None);
    }

    #[test]
    fn urls_name_the_repo_by_their_last_segment() {
        for url in ["git@github.com:team/repo.git", "https://host/team/repo.git/", "/srv/git/repo", "ssh://host/repo.git", "C:\\git\\repo.git"] {
            assert_eq!(repo_from_url(url).as_deref(), Some("repo"), "{url}");
        }
        assert_eq!(repo_from_url(""), None);
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

    #[test]
    fn a_path_without_a_file_name_does_not_panic() {
        let root = Path::new("/r/repo");
        assert_eq!(folio_path_in(root, Path::new("/r/repo")), PathBuf::from("/r/repo/.folio/.folio"));
        assert_eq!(folio_path_in(Path::new("/"), Path::new("/")), PathBuf::from("/.folio/.folio"));
    }
}
