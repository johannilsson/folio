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

/// Anchor each annotation against `doc` and return the `(start, end, replacement)`
/// edits that accepting them implies. Comment/highlight produce no edit. Anchors
/// are all resolved against the untouched doc before anything is applied.
pub fn compute_ops(
    doc: &str,
    sidecar: &Sidecar,
    indices: &[usize],
) -> Result<Vec<(usize, usize, String)>, String> {
    let mut ops = Vec::new();
    for &idx in indices {
        let ann = &sidecar.annotations[idx];
        let (raw_start, raw_end) = ann.anchor(doc).ok_or_else(|| {
            let target_str = ann.target.as_deref().unwrap_or("(none)");
            format!(
                "anchoring failed for {} ({}): could not find {:?} + {:?}",
                ann.id, ann.kind, ann.context_before, target_str
            )
        })?;

        let op = match &ann.kind {
            AnnotationKind::Replace => {
                (raw_start, raw_end, ann.replacement.clone().unwrap_or_default())
            }
            AnnotationKind::Delete => (raw_start, raw_end, String::new()),
            AnnotationKind::Insert => {
                (raw_start, raw_start, ann.replacement.clone().unwrap_or_default())
            }
            // comment/highlight: no doc change
            _ => continue,
        };
        ops.push(op);
    }
    Ok(ops)
}

/// Apply edits in reverse order so earlier byte offsets stay valid.
pub fn apply_ops(doc: &str, mut ops: Vec<(usize, usize, String)>) -> String {
    let mut new_doc = doc.to_string();
    ops.sort_by_key(|b| std::cmp::Reverse(b.0));
    for (start, end, repl) in ops {
        new_doc.replace_range(start..end, &repl);
    }
    new_doc
}

pub fn mark_accepted(sidecar: &mut Sidecar, indices: &[usize]) {
    let now = now_iso8601();
    for &idx in indices {
        let ann = &mut sidecar.annotations[idx];
        ann.resolved = true;
        ann.resolved_as = Some("accepted".to_string());
        ann.resolved_at = Some(now.clone());
    }
}
