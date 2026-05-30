use crate::sidecar::{AnnotationKind, Sidecar};
use std::path::Path;

pub fn run(
    file: &Path,
    kind_filter: Option<&str>,
    source_filter: Option<&str>,
    json: bool,
) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
    let sidecar = Sidecar::load(&folio_path)?;

    let pending: Vec<_> = sidecar
        .annotations
        .iter()
        .filter(|a| !a.resolved)
        .filter(|a| {
            kind_filter
                .map(|k| a.kind.to_string() == k)
                .unwrap_or(true)
        })
        .filter(|a| {
            source_filter
                .map(|s| a.source.to_string() == s)
                .unwrap_or(true)
        })
        .collect();

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
