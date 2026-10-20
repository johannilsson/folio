use crate::sidecar::{now_iso8601, Sidecar};
use std::path::Path;
use std::process;

pub fn run(
    file: &Path,
    id: Option<&str>,
    all: bool,
    source_filter: Option<&str>,
    dry_run: bool,
) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
    let mut sidecar = Sidecar::load(&folio_path)?;

    let indices: Vec<usize> = sidecar
        .annotations
        .iter()
        .enumerate()
        .filter(|(_, a)| !a.resolved)
        .filter(|(_, a)| {
            if all {
                source_filter
                    .map(|s| a.source.to_string() == s)
                    .unwrap_or(true)
            } else {
                id.map(|i| a.id == i).unwrap_or(false)
            }
        })
        .map(|(i, _)| i)
        .collect();

    if indices.is_empty() {
        eprintln!("no matching pending annotations");
        process::exit(1);
    }

    if dry_run {
        for &idx in &indices {
            println!("  would reject {}", sidecar.annotations[idx].id);
        }
        return Ok(());
    }

    let now = now_iso8601();
    for &idx in &indices {
        let ann = &mut sidecar.annotations[idx];
        ann.resolved = true;
        ann.resolved_as = Some("rejected".to_string());
        ann.resolved_at = Some(now.clone());
    }
    sidecar.save(&folio_path)?;

    println!("rejected {} annotation(s)", indices.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-reject-{}-{}-{}",
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

    /// A file with two annotations, one from an agent and one from the local user.
    fn setup(tag: &str) -> (PathBuf, PathBuf) {
        let tmp = temp_dir(tag);
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let file = tmp.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();
        super::super::annotate::run(&file, "delete", "Hello ", Some("world"), None, None, "bot", "agent").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let folio = super::super::folio_path(&file);
        (file, folio)
    }

    #[test]
    fn rejecting_by_id_resolves_only_that_annotation() {
        let (file, folio) = setup("by-id");
        let id = Sidecar::load(&folio).unwrap().annotations[0].id.clone();

        run(&file, Some(&id), false, None, false).unwrap();

        let s = Sidecar::load(&folio).unwrap();
        assert!(s.annotations[0].resolved);
        assert_eq!(s.annotations[0].resolved_as.as_deref(), Some("rejected"));
        assert!(s.annotations[0].resolved_at.is_some());
        assert!(!s.annotations[1].resolved);
    }

    #[test]
    fn all_with_a_source_filter_rejects_only_that_source() {
        let (file, folio) = setup("source");

        run(&file, None, true, Some("agent"), false).unwrap();

        let s = Sidecar::load(&folio).unwrap();
        let resolved: Vec<bool> = s.annotations.iter().map(|a| a.resolved).collect();
        assert_eq!(resolved, vec![true, false]);
    }

    #[test]
    fn dry_run_leaves_the_sidecar_untouched() {
        let (file, folio) = setup("dry");

        run(&file, None, true, None, true).unwrap();

        let s = Sidecar::load(&folio).unwrap();
        assert!(s.annotations.iter().all(|a| !a.resolved));
    }
}
