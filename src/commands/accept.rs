use crate::accept::{apply_ops, compute_ops, mark_accepted};
use crate::sidecar::Sidecar;
use std::path::Path;
use std::process;

pub fn run(
    file: &Path,
    id: Option<&str>,
    all: bool,
    source_filter: Option<&str>,
    dry_run: bool,
) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    let mut sidecar = Sidecar::load(&folio_path)?;
    let doc = std::fs::read_to_string(file)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;

    // Collect indices of annotations to accept
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

    let ops = match compute_ops(&doc, &sidecar, &indices) {
        Ok(ops) => ops,
        Err(msg) => {
            eprintln!("{msg}");
            process::exit(2);
        }
    };

    if dry_run {
        for (start, end, repl) in &ops {
            println!("  [{start}..{end}] → {:?}", repl);
        }
        return Ok(());
    }

    let new_doc = apply_ops(&doc, ops);

    std::fs::write(file, &new_doc)?;

    mark_accepted(&mut sidecar, &indices);
    sidecar.save(&folio_path)?;

    println!("accepted {} annotation(s)", indices.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sidecar::ResolvedAs;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-accept-{}-{}-{}",
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

    /// A file with a delete from an agent and a highlight from the local user.
    fn setup(tag: &str) -> (PathBuf, PathBuf) {
        let tmp = temp_dir(tag);
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let file = tmp.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();
        super::super::annotate::run(&file, "delete", "Hello ", Some("world"), None, None, "bot", "agent").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let folio = crate::location::folio_path(&file);
        (file, folio)
    }

    #[test]
    fn accepting_by_id_edits_the_file_and_resolves_only_that_annotation() {
        let (file, folio) = setup("by-id");
        let id = Sidecar::load(&folio).unwrap().annotations[0].id.clone();

        run(&file, Some(&id), false, None, false).unwrap();

        assert_eq!(std::fs::read_to_string(&file).unwrap(), "Hello .\n");
        let s = Sidecar::load(&folio).unwrap();
        assert!(s.annotations[0].resolved);
        assert_eq!(s.annotations[0].resolved_as, Some(ResolvedAs::Accepted));
        assert!(!s.annotations[1].resolved);
    }

    #[test]
    fn all_with_a_source_filter_accepts_only_that_source() {
        let (file, folio) = setup("source");

        run(&file, None, true, Some("local"), false).unwrap();

        // The local highlight is resolved; the agent's delete is untouched and the text unchanged.
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "Hello world.\n");
        let s = Sidecar::load(&folio).unwrap();
        let resolved: Vec<bool> = s.annotations.iter().map(|a| a.resolved).collect();
        assert_eq!(resolved, vec![false, true]);
    }

    #[test]
    fn dry_run_leaves_the_file_and_sidecar_untouched() {
        let (file, folio) = setup("dry");

        run(&file, None, true, None, true).unwrap();

        assert_eq!(std::fs::read_to_string(&file).unwrap(), "Hello world.\n");
        assert!(Sidecar::load(&folio).unwrap().annotations.iter().all(|a| !a.resolved));
    }
}
