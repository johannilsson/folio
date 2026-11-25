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

/// The file's name for the heading, or the path as given when it has none (`..`, `/`).
fn display_name(file: &Path) -> String {
    file.file_name().unwrap_or(file.as_os_str()).to_string_lossy().into_owned()
}

/// An annotation as JSON, with where it anchors in `content`: `anchored`, and when it does,
/// the `start` and `end` byte offsets into the file (equal for a comment or an insertion).
fn with_position(ann: &Annotation, content: &str) -> serde_json::Value {
    let mut value = serde_json::to_value(ann).unwrap_or_default();
    let span = ann.anchor(content);
    value["anchored"] = serde_json::json!(span.is_some());
    if let Some((start, end)) = span {
        value["start"] = serde_json::json!(start);
        value["end"] = serde_json::json!(end);
    }
    value
}

pub fn run(
    file: &Path,
    kind_filter: Option<&str>,
    source_filter: Option<&str>,
    json: bool,
    positions: bool,
) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    let sidecar = Sidecar::load(&folio_path)?;

    let pending = pending(&sidecar, kind_filter, source_filter);

    if json {
        if positions {
            let content = std::fs::read_to_string(file)
                .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
            let located: Vec<_> = pending.iter().map(|a| with_position(a, &content)).collect();
            println!("{}", serde_json::to_string_pretty(&located)?);
        } else {
            println!("{}", serde_json::to_string_pretty(&pending)?);
        }
        return Ok(());
    }

    let name = display_name(file);
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

    #[test]
    fn a_position_is_the_byte_span_of_the_target() {
        let s = sidecar("positions");
        let doc = "Hello world.\n";
        let delete = with_position(&s.annotations[0], doc);
        assert_eq!((delete["anchored"].as_bool(), delete["start"].as_u64(), delete["end"].as_u64()), (Some(true), Some(6), Some(11)));
        assert_eq!(delete["id"], s.annotations[0].id);
    }

    #[test]
    fn an_annotation_that_no_longer_anchors_has_no_span() {
        let s = sidecar("unanchored");
        let value = with_position(&s.annotations[0], "Something else entirely.\n");
        assert_eq!(value["anchored"], false);
        assert!(value.get("start").is_none() && value.get("end").is_none());
    }

    #[test]
    fn a_path_without_a_file_name_is_shown_as_given() {
        assert_eq!(display_name(Path::new("docs/a.md")), "a.md");
        assert_eq!(display_name(Path::new("..")), "..");
        assert_eq!(display_name(Path::new("/")), "/");
    }
}
