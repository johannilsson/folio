use crate::sidecar::{Annotation, AnnotationKind, Sidecar};
use std::path::Path;

/// Unresolved annotations, narrowed by kind and source when given.
fn pending<'a>(
    sidecar: &'a Sidecar,
    kind_filter: Option<&str>,
    source_filter: Option<&str>,
) -> Vec<&'a Annotation> {
    sidecar
        .annotations
        .iter()
        .filter(|a| !a.resolved)
        .filter(|a| kind_filter.map(|k| a.kind.to_string() == k).unwrap_or(true))
        .filter(|a| source_filter.map(|s| a.source.to_string() == s).unwrap_or(true))
        .collect()
}

pub fn run(
    file: &Path,
    kind_filter: Option<&str>,
    source_filter: Option<&str>,
    json: bool,
) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    let sidecar = Sidecar::load(&folio_path)?;

    let pending = pending(&sidecar, kind_filter, source_filter);

    if json {
        println!("{}", serde_json::to_string_pretty(&pending)?);
        return Ok(());
    }

    let name = file.file_name().unwrap().to_string_lossy();
    println!("{name}  ·  {} pending annotations\n", pending.len());

    for ann in &pending {
        let author_str = format!("{}/{}", ann.source, ann.author);
        println!("  {}  {}   {}", ann.id, ann.kind, author_str);

        match ann.kind {
            AnnotationKind::Replace => {
                if let Some(t) = &ann.target {
                    println!("  ❝ …{}❞", t);
                }
                if let Some(r) = &ann.replacement {
                    println!("  → {}", r);
                }
            }
            AnnotationKind::Delete => {
                if let Some(t) = &ann.target {
                    println!("  ❝ …{}❞", t);
                }
            }
            AnnotationKind::Insert => {
                if let Some(r) = &ann.replacement {
                    println!("  + {}", r);
                }
            }
            AnnotationKind::Comment | AnnotationKind::Highlight => {
                println!(
                    "  ❝ {}…❞",
                    ann.context_before
                        .chars()
                        .take(60)
                        .collect::<String>()
                );
            }
        }

        if let Some(c) = &ann.comment {
            println!("  {}", c);
        }
        println!();
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sidecar(tag: &str) -> Sidecar {
        let dir = std::env::temp_dir().join(format!("folio-review-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();
        let _ = std::fs::remove_file(crate::location::folio_path(&file));
        super::super::annotate::run(&file, "delete", "Hello ", Some("world"), None, None, "bot", "agent").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let mut s = Sidecar::load(&crate::location::folio_path(&file)).unwrap();
        s.annotations.push(s.annotations[0].clone());
        s.annotations[2].resolved = true;
        s
    }

    #[test]
    fn resolved_annotations_are_never_listed() {
        let s = sidecar("resolved");
        assert_eq!(pending(&s, None, None).len(), 2);
    }

    #[test]
    fn kind_and_source_filters_narrow_the_list() {
        let s = sidecar("filters");
        assert_eq!(pending(&s, Some("delete"), None).len(), 1);
        assert_eq!(pending(&s, None, Some("local")).len(), 1);
        assert!(pending(&s, Some("delete"), Some("local")).is_empty());
        assert!(pending(&s, Some("bogus"), None).is_empty());
    }
}
