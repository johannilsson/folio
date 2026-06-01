use crate::sidecar::{now_iso8601, AnnotationKind, Sidecar};
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

    // Anchor all before touching anything
    let mut ops: Vec<(usize, usize, String)> = Vec::new(); // (start, end, replacement)
    for &idx in &indices {
        let ann = &sidecar.annotations[idx];
        let (raw_start, raw_end) = match ann.anchor(&doc) {
            Some(pair) => pair,
            None => {
                let target_str = ann.target.as_deref().unwrap_or("(none)");
                eprintln!(
                    "anchoring failed for {} ({}): could not find {:?} + {:?}",
                    ann.id, ann.kind, ann.context_before, target_str
                );
                process::exit(2);
            }
        };

        let (start, end, repl) = match &ann.kind {
            AnnotationKind::Replace => {
                (raw_start, raw_end, ann.replacement.clone().unwrap_or_default())
            }
            AnnotationKind::Delete => (raw_start, raw_end, String::new()),
            AnnotationKind::Insert => {
                let repl = ann.replacement.clone().unwrap_or_default();
                (raw_start, raw_start, repl)
            }
            // comment/highlight: no doc change
            _ => continue,
        };

        ops.push((start, end, repl));
    }

    if dry_run {
        for (start, end, repl) in &ops {
            println!("  [{start}..{end}] → {:?}", repl);
        }
        return Ok(());
    }

    // Apply ops in reverse order to preserve byte offsets
    let mut new_doc = doc.clone();
    ops.sort_by(|a, b| b.0.cmp(&a.0));
    for (start, end, repl) in ops {
        new_doc.replace_range(start..end, &repl);
    }

    std::fs::write(file, &new_doc)?;

    let now = now_iso8601();
    for &idx in &indices {
        let ann = &mut sidecar.annotations[idx];
        ann.resolved = true;
        ann.resolved_as = Some("accepted".to_string());
        ann.resolved_at = Some(now.clone());
    }
    sidecar.save(&folio_path)?;

    println!("accepted {} annotation(s)", indices.len());
    Ok(())
}
