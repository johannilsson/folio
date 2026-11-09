use crate::set;
use crate::wiki::{references, Here, LinkTarget, Reference};
use serde::Serialize;
use std::path::{Path, PathBuf};

/// A link to the file, and the page it is in.
#[derive(Serialize)]
struct Found {
    page: PathBuf,
    #[serde(flatten)]
    reference: Reference,
}

/// The pages of a set to read: its files and the markdown of its folders, each once, without `file`.
fn pages(set_name: &str, file: &Path) -> anyhow::Result<Vec<PathBuf>> {
    let loaded = set::load(set_name)?;
    let mut all: Vec<PathBuf> = loaded.files.iter().map(|f| f.path.clone()).collect();
    for folder in &loaded.folders {
        all.extend(set::folder_files(folder).into_iter().map(|f| f.path));
    }
    let mut seen = std::collections::HashSet::new();
    let file = dunce::canonicalize(file).unwrap_or_else(|_| file.to_path_buf());
    all.retain(|page| {
        let page = dunce::canonicalize(page).unwrap_or_else(|_| page.clone());
        page != file && seen.insert(page)
    });
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

/// Print the wiki pages of a set that link to `file`: to the document, a passage or an annotation.
pub fn run(file: &Path, set_name: &str, json: bool) -> anyhow::Result<()> {
    let found = find(file, set_name)?;
    if json {
        println!("{}", serde_json::to_string_pretty(&found)?);
        return Ok(());
    }
    for Found { page, reference } in &found {
        let to = match &reference.link.target {
            LinkTarget::Document => "the document".to_string(),
            LinkTarget::Annotation { id } => format!("annotation {}", id),
            LinkTarget::Passage { text } => format!("passage “{}”", text),
        };
        println!("{}:{}  {}  → {}", page.display(), reference.line, reference.context, to);
    }
    if found.is_empty() {
        println!("No pages link to {}", file.display());
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
        assert!(run(&spec, "s", true).is_ok());
        std::env::remove_var("FOLIO_CONFIG_DIR");
        std::fs::remove_dir_all(&tmp).ok();
    }
}
