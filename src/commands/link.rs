use crate::sidecar::Sidecar;
use std::path::Path;

/// Percent-encode everything but unreserved characters and `/`.
fn encode(path: &str) -> String {
    let mut out = String::new();
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// Where a file is, as a link names it: the repo and branch it is checked out on and its path in
/// that checkout (they outlive a worktree's folder), and the absolute path as a fallback.
fn place(file: &Path) -> String {
    let file = crate::location::absolute(file);
    let root = crate::location::detect_root(&file);
    let mut query = String::new();
    if let Some(identity) = crate::location::repo_identity(&root) {
        query.push_str(&format!("repo={}&", encode(&identity.repo)));
        if let Some(branch) = &identity.branch {
            query.push_str(&format!("branch={}&", encode(branch)));
        }
        let relative = file.strip_prefix(&root).unwrap_or(&file).to_string_lossy().replace('\\', "/");
        query.push_str(&format!("path={}&", encode(&relative)));
    }
    query.push_str(&format!("file={}", encode(&file.to_string_lossy())));
    query
}

/// The link that opens `file` in Folio with the annotation `id` in view.
pub fn url(file: &Path, id: &str) -> String {
    format!("folio://annotation/{}?{}", encode(id), place(file))
}

/// The link that opens `file` with `text` selected. `before` is the rendered text just before it,
/// for a passage that appears more than once; the engine anchors it as it does an annotation.
pub fn passage_url(file: &Path, text: &str, before: &str) -> String {
    let before = if before.is_empty() { String::new() } else { format!("&before={}", encode(before)) };
    format!("folio://passage?{}&q={}{}", place(file), encode(text), before)
}

/// A markdown link's text: short, and about what it points at.
fn label(text: &str) -> String {
    let text = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let mut short: String = text.chars().take(40).collect();
    if text.chars().count() > 40 {
        short.push('…');
    }
    short.replace('[', "(").replace(']', ")")
}

/// Print the link to an annotation or a passage, for pasting into another document. With
/// `markdown`, a whole markdown link whose text is the author and the start of the comment (or the
/// passage), so the document still reads once the target is gone.
pub fn run(file: &Path, id: Option<&str>, passage: Option<&str>, before: Option<&str>, markdown: bool) -> anyhow::Result<()> {
    let (link, text) = match (id, passage) {
        (Some(id), None) => {
            let sidecar = Sidecar::load(&crate::location::folio_path(file))?;
            let annotation = sidecar
                .annotations
                .iter()
                .find(|a| a.id == id)
                .ok_or_else(|| anyhow::anyhow!("no annotation {} in {}", id, file.display()))?;
            let about = annotation.comment.as_deref().or(annotation.target.as_deref()).unwrap_or(id);
            (url(file, id), format!("{}: “{}”", annotation.author, label(about)))
        }
        (None, Some(passage)) => {
            let before = before.unwrap_or("");
            let doc = std::fs::read_to_string(file)
                .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
            let rendered = crate::sidecar::render_plain_text(&doc);
            let found = rendered.matches(passage).count();
            if found == 0 || crate::sidecar::anchor_raw_chars(&doc, before, Some(passage)).is_none() {
                anyhow::bail!("{:?} is not in {}", passage, file.display());
            }
            if found > 1 && before.is_empty() {
                anyhow::bail!("{:?} appears {} times in {}: add --before with the words just ahead of it", passage, found, file.display());
            }
            (passage_url(file, passage, before), label(passage))
        }
        _ => anyhow::bail!("give an annotation id, or --passage"),
    };
    if markdown {
        println!("[{}]({})", text, link);
    } else {
        println!("{}", link);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn the_path_is_percent_encoded() {
        if cfg!(windows) {
            let link = url(Path::new(r"C:\definitely\not here\a&b.md"), "ann_k7mxpq2r");
            assert_eq!(link, "folio://annotation/ann_k7mxpq2r?file=C%3A%5Cdefinitely%5Cnot%20here%5Ca%26b.md");
        } else {
            let link = url(Path::new("/definitely/not here/a&b.md"), "ann_k7mxpq2r");
            assert_eq!(link, "folio://annotation/ann_k7mxpq2r?file=/definitely/not%20here/a%26b.md");
        }
    }

    /// A checkout with a remote, a branch and a document in it.
    fn repo_with(doc: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!("folio-link-repo-{}-{}", std::process::id(), doc.len()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::write(dir.join(".git/HEAD"), "ref: refs/heads/fix/logout\n").unwrap();
        std::fs::write(dir.join(".git/config"), "[remote \"origin\"]\n\turl = git@host:team/payments-svc.git\n").unwrap();
        std::fs::create_dir_all(dir.join("docs")).unwrap();
        std::fs::write(dir.join("docs/t.md"), doc).unwrap();
        // The paths as the code under test sees them: `dunce` leaves out the `\\?\` prefix `canonicalize`
        // adds on Windows, and joins with the platform's separator ("docs/t.md" would keep its "/").
        (dunce::canonicalize(&dir).unwrap(), dunce::canonicalize(dir.join("docs/t.md")).unwrap())
    }

    #[test]
    fn a_link_names_the_repo_the_branch_and_the_path_in_the_checkout() {
        let (root, file) = repo_with("We rotate on every use.\n");
        let link = url(&file, "ann_k7mxpq2r");
        assert!(
            link.starts_with("folio://annotation/ann_k7mxpq2r?repo=payments-svc&branch=fix/logout&path=docs/t.md&file="),
            "{link}"
        );
        assert!(link.ends_with(&encode(&file.to_string_lossy())), "{link}");
        std::fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_passage_link_carries_the_text_and_what_comes_before_it() {
        let (root, file) = repo_with("We rotate on every use. Then we rotate again.\n");
        let link = passage_url(&file, "rotate on every use", "We ");
        assert!(link.starts_with("folio://passage?repo=payments-svc&branch=fix/logout&path=docs/t.md&file="), "{link}");
        assert!(link.ends_with("&q=rotate%20on%20every%20use&before=We%20"), "{link}");
        assert!(!passage_url(&file, "again", "").contains("before"));
        std::fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_passage_must_be_in_the_file_and_unambiguous() {
        let (root, file) = repo_with("We rotate here. We rotate there and there.\n");
        assert!(run(&file, None, Some("nowhere"), None, false).unwrap_err().to_string().contains("is not in"));
        let err = run(&file, None, Some("rotate"), None, false).unwrap_err().to_string();
        assert!(err.contains("appears 2 times") && err.contains("--before"), "{err}");
        assert!(run(&file, None, Some("rotate"), Some("We "), false).is_ok());
        assert!(run(&file, None, Some("there and there"), None, false).is_ok());
        assert!(run(&file, None, None, None, false).unwrap_err().to_string().contains("--passage"));
        std::fs::remove_dir_all(root).ok();
    }

    #[test]
    fn a_label_is_short_and_cannot_close_the_link() {
        assert_eq!(label("Does   rotation alone\ncover [it]?"), "Does rotation alone cover (it)?");
        assert_eq!(label(&"a".repeat(60)), format!("{}…", "a".repeat(40)));
    }

    #[test]
    fn run_rejects_an_unknown_annotation_id() {
        let dir = std::env::temp_dir().join(format!("folio-link-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.canonicalize().unwrap().join("a.md");
        std::fs::write(&file, "Hello.\n").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let id = Sidecar::load(&crate::location::folio_path(&file)).unwrap().annotations[0].id.clone();
        assert!(run(&file, Some(&id), None, None, false).is_ok());
        let err = run(&file, Some("ann_nope"), None, None, false).unwrap_err().to_string();
        assert!(err.contains("no annotation ann_nope"), "{err}");
    }
}
