use crate::set;
use crate::wiki::{dead_reason, moved_to, references, Here, LinkTarget, Reference};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// A link to the file, and the page it is in.
#[derive(Serialize)]
struct Found {
    page: PathBuf,
    #[serde(flatten)]
    reference: Reference,
}

/// Every markdown file of the set: its files and the markdown of its folders, each once.
fn set_files(set_name: &str) -> anyhow::Result<Vec<PathBuf>> {
    let loaded = set::load(set_name)?;
    let mut all: Vec<PathBuf> = loaded.files.iter().map(|f| f.path.clone()).collect();
    for folder in &loaded.folders {
        all.extend(set::folder_files(folder).into_iter().map(|f| f.path));
    }
    let mut seen = std::collections::HashSet::new();
    all.retain(|page| seen.insert(dunce::canonicalize(page).unwrap_or_else(|_| page.clone())));
    Ok(all)
}

/// The pages to read for links to `file`: the set's files other than `file` itself.
fn pages(set_name: &str, file: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let file = dunce::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    let mut all = set_files(set_name)?;
    all.retain(|page| dunce::canonicalize(page).unwrap_or_else(|_| page.clone()) != file);
    Ok(all)
}

/// The links in the set's pages to `file`, its passages or its annotations, by page and line.
fn find(file: &Path, set_name: &str) -> anyhow::Result<Vec<Found>> {
    if !file.is_file() {
        anyhow::bail!("cannot read {}", file.display());
    }
    let here = Here::of(file);
    let mut found = Vec::new();
    for page in pages(set_name, file)? {
        // A page removed since the set was read has no links.
        let Ok(text) = std::fs::read_to_string(&page) else { continue };
        found.extend(
            references(&text)
                .into_iter()
                .filter(|r| r.link.points_to(&here))
                .map(|reference| Found { page: page.clone(), reference }),
        );
    }
    Ok(found)
}

/// A link that cannot be followed, the page it is in and why.
#[derive(Serialize)]
struct Dead {
    page: PathBuf,
    #[serde(flatten)]
    reference: Reference,
    reason: String,
}

/// The links of the set's pages that cannot be followed among the set's files.
fn find_dead(set_name: &str) -> anyhow::Result<Vec<Dead>> {
    let files = set_files(set_name)?;
    let open: Vec<Here> = files.iter().map(|f| Here::of(f)).collect();
    let mut dead = Vec::new();
    for page in &files {
        let Ok(text) = std::fs::read_to_string(page) else { continue };
        for reference in references(&text) {
            if let Some(reason) = dead_reason(&reference.link, &open) {
                dead.push(Dead { page: page.clone(), reference, reason });
            }
        }
    }
    Ok(dead)
}

/// Print the wiki pages of a set that link to `file`: to the document, a passage or an annotation.
/// With `dead`, instead the links in the set's pages that cannot be followed.
pub fn run(file: Option<&Path>, set_name: &str, dead: bool, json: bool) -> anyhow::Result<()> {
    if dead {
        let dead = find_dead(set_name)?;
        if json {
            println!("{}", serde_json::to_string_pretty(&dead)?);
            return Ok(());
        }
        for d in &dead {
            println!("{}:{}  {}  → {}", d.page.display(), d.reference.line, d.reference.context, d.reason);
            println!("{:<11} {}", "", d.reference.url);
        }
        if dead.is_empty() {
            println!("No dead links");
        }
        return Ok(());
    }
    let file = file.ok_or_else(|| anyhow::anyhow!("give a file, or --dead"))?;
    let found = find(file, set_name)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&found)?);
        return Ok(());
    }
    for Found { page, reference } in &found {
        let to = match &reference.link.target {
            LinkTarget::Document => "the document".to_string(),
            LinkTarget::Annotation { id } => format!("annotation {}", id),
            LinkTarget::Passage { text, .. } => format!("passage “{}”", text),
        };
        println!("{}:{}  {}  → {}", page.display(), reference.line, reference.context, to);
    }
    if found.is_empty() {
        println!("No pages link to {}", file.display());
    }
    Ok(())
}

/// `url` with its branch and file replaced by those of `to`.
fn moved(url: &str, to: &Here) -> String {
    let (head, query) = url.split_once('?').unwrap_or((url, ""));
    let pairs: Vec<String> = query
        .split('&')
        .map(|pair| match pair.split_once('=') {
            Some(("branch", _)) => format!("branch={}", crate::commands::link::encode(to.branch.as_deref().unwrap_or(""))),
            Some(("file", _)) => format!("file={}", crate::commands::link::encode(&to.file.to_string_lossy())),
            _ => pair.to_string(),
        })
        .collect();
    format!("{}?{}", head, pairs.join("&"))
}

/// Writes `text` over `page` through a temp file and a rename, so a reader never sees half of it.
fn write(page: &Path, text: &str) -> anyhow::Result<()> {
    let temp = page.with_extension("folio-tmp");
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, page).map_err(|e| {
        std::fs::remove_file(&temp).ok();
        anyhow::anyhow!("cannot write {}: {}", page.display(), e)
    })
}

/// Repairs the links whose branch is gone when one checkout in the set has the file: the link names
/// that branch (and file) instead. Everything else is the reader's or the agent's call (`refs --dead`).
pub fn relink(set_name: &str, dry_run: bool) -> anyhow::Result<()> {
    let files = set_files(set_name)?;
    let open: Vec<Here> = files.iter().map(|f| Here::of(f)).collect();
    let mut changed = 0;
    for page in &files {
        let Ok(mut text) = std::fs::read_to_string(page) else { continue };
        let mut fixed = 0;
        for reference in references(&text.clone()) {
            let Some(index) = moved_to(&reference.link, &open) else { continue };
            let new = moved(&reference.url, &open[index]);
            println!("{}:{}  {} → {}", page.display(), reference.line, reference.link.branch.as_deref().unwrap_or(""), open[index].branch.as_deref().unwrap_or(""));
            text = text.replace(&reference.url, &new);
            fixed += 1;
        }
        if fixed > 0 {
            changed += fixed;
            if !dry_run {
                write(page, &text)?;
            }
        }
    }
    if changed == 0 {
        println!("No links to repair");
    } else if dry_run {
        println!("{} link(s) would change", changed);
    } else {
        println!("{} link(s) repaired", changed);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pages_of_a_set_that_link_to_a_file() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = dunce::canonicalize(std::env::temp_dir()).unwrap().join(format!("folio-refs-{}", std::process::id()));
        std::fs::create_dir_all(tmp.join("svc/.git")).unwrap();
        std::fs::write(tmp.join("svc/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(tmp.join("svc/.git/config"), "[remote \"origin\"]\n\turl = git@host:team/svc.git\n").unwrap();
        std::fs::create_dir_all(tmp.join("svc/docs")).unwrap();
        std::fs::create_dir_all(tmp.join("wiki")).unwrap();
        let spec = tmp.join("svc/docs/spec.md");
        std::fs::write(&spec, "We rotate on every use.\n").unwrap();
        std::fs::write(tmp.join("svc/docs/other.md"), "Other.\n").unwrap();
        let document = crate::commands::link::document_url(&spec);
        let passage = crate::commands::link::passage_url(&spec, "rotate on every use", "");
        let elsewhere = crate::commands::link::document_url(&tmp.join("svc/docs/other.md"));
        let other_branch = document.replace("branch=main", "branch=fix");
        std::fs::write(
            tmp.join("wiki/requirements.md"),
            format!("# R4\n\nSee [the spec]({document}).\n\n## Rotation\n\n- [ ] [why]({passage}) #investigate\n- [other]({elsewhere}) [fix]({other_branch})\n"),
        )
        .unwrap();
        std::fs::write(tmp.join("wiki/index.md"), "Nothing here.\n").unwrap();
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));
        set::add_files("s", &[spec.clone()], None).unwrap();
        set::add_folders("s", &[tmp.join("wiki")]).unwrap();

        let found = find(&spec, "s").unwrap();
        let summary: Vec<_> = found
            .iter()
            .map(|f| (f.page.file_name().unwrap().to_string_lossy().to_string(), f.reference.line, f.reference.context.clone(), f.reference.label.clone()))
            .collect();
        assert_eq!(
            summary,
            [
                ("requirements.md".to_string(), 3, "R4".to_string(), "the spec".to_string()),
                ("requirements.md".to_string(), 7, "Rotation".to_string(), "why".to_string()),
            ]
        );
        assert!(find(&tmp.join("svc/docs/missing.md"), "s").is_err());
        assert!(find(&spec, "nope").is_err());
        assert!(run(Some(&spec), "s", false, true).is_ok());
        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&tmp).ok();
    }

    /// A checkout of `svc` on `branch`, with docs/spec.md in it.
    fn checkout(tmp: &Path, name: &str, branch: &str, text: &str) -> PathBuf {
        let dir = tmp.join(name);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        std::fs::write(dir.join(".git/HEAD"), format!("ref: refs/heads/{branch}\n")).unwrap();
        std::fs::write(dir.join(".git/config"), "[remote \"origin\"]\n\turl = git@host:team/svc.git\n").unwrap();
        std::fs::create_dir_all(dir.join("docs")).unwrap();
        std::fs::write(dir.join("docs/spec.md"), text).unwrap();
        dunce::canonicalize(dir.join("docs/spec.md")).unwrap()
    }

    #[test]
    fn dead_links_say_why_and_a_gone_branch_moves_to_the_checkout_that_has_the_file() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = dunce::canonicalize(std::env::temp_dir()).unwrap().join(format!("folio-dead-{}", std::process::id()));
        let old = checkout(&tmp, "old", "fix/logout", "We rotate on every use.\n");
        let main = checkout(&tmp, "main", "main", "We rotate on every use.\n");
        std::fs::create_dir_all(tmp.join("wiki")).unwrap();
        // The links are written from the fix branch's checkout, which is not in the set (it was removed).
        let on_fix = crate::commands::link::document_url(&old);
        let passage = crate::commands::link::passage_url(&old, "rotate on every use", "");
        std::fs::write(
            tmp.join("wiki/notes.md"),
            format!("# Notes\n\n[spec]({on_fix})\n\n[why]({passage})\n\n[web](https://example.com)\n"),
        )
        .unwrap();
        std::env::set_var("FOLIO_CONFIG_DIR", tmp.join("cfg"));
        set::add_files("s", &[main.clone()], None).unwrap();
        set::add_folders("s", &[tmp.join("wiki")]).unwrap();

        // Only `main` is in the set; the links name fix/logout, which no file of the set is on.
        let dead = find_dead("s").unwrap();
        assert_eq!(dead.len(), 2);
        assert!(dead.iter().all(|d| d.reason == "fix/logout isn't checked out any more"), "{:?}", dead.iter().map(|d| &d.reason).collect::<Vec<_>>());

        // Moving them: the one checkout of svc that has docs/spec.md is main.
        relink("s", true).unwrap();
        assert_eq!(find_dead("s").unwrap().len(), 2, "a dry run writes nothing");
        relink("s", false).unwrap();
        let page = std::fs::read_to_string(tmp.join("wiki/notes.md")).unwrap();
        assert!(page.contains("branch=main&path=docs/spec.md"), "{page}");
        assert!(page.contains(&format!("file={}", crate::commands::link::encode(&main.to_string_lossy()))), "{page}");
        assert!(page.contains("[web](https://example.com)"));
        assert!(find_dead("s").unwrap().is_empty());

        // The passage edited away, the file there: a different reason, and nothing to repair.
        std::fs::write(&main, "Tokens are replaced on every refresh.\n").unwrap();
        let dead = find_dead("s").unwrap();
        assert_eq!(dead.len(), 1);
        assert_eq!(dead[0].reason, "Not found in spec.md");
        assert_eq!(dead[0].reference.line, 5);
        relink("s", false).unwrap();
        assert_eq!(find_dead("s").unwrap().len(), 1);
        assert!(run(None, "s", true, true).is_ok());
        assert!(run(None, "s", false, false).is_err());
        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&tmp).ok();
    }
}
