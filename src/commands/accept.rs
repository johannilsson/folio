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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sidecar::AnnotationSource;

    fn ann(id: &str, kind: AnnotationKind, ctx: &str, target: Option<&str>, repl: Option<&str>) -> crate::sidecar::Annotation {
        crate::sidecar::Annotation {
            id: id.into(),
            kind,
            source: AnnotationSource::Agent,
            author: "tester".into(),
            context_before: ctx.into(),
            target: target.map(String::from),
            replacement: repl.map(String::from),
            comment: None,
            created: "2026-01-01T00:00:00Z".into(),
            resolved: false,
            resolved_as: None,
            resolved_at: None,
            replies: vec![],
        }
    }

    fn sidecar(annotations: Vec<crate::sidecar::Annotation>) -> Sidecar {
        Sidecar { version: 1, annotations }
    }

    #[test]
    fn replace_delete_and_insert_become_edits_and_comments_do_not() {
        let doc = "The quick brown fox jumps.";
        let s = sidecar(vec![
            ann("r", AnnotationKind::Replace, "The ", Some("quick"), Some("slow")),
            ann("d", AnnotationKind::Delete, "quick brown ", Some("fox "), None),
            ann("i", AnnotationKind::Insert, "fox jumps", None, Some(" high")),
            ann("c", AnnotationKind::Comment, "The ", Some("quick"), None),
        ]);
        let ops = compute_ops(doc, &s, &[0, 1, 2, 3]).unwrap();
        assert_eq!(
            ops,
            vec![
                (4, 9, "slow".to_string()),
                (16, 20, String::new()),
                (25, 25, " high".to_string()),
            ]
        );
    }

    #[test]
    fn anchoring_failure_names_the_annotation() {
        let s = sidecar(vec![ann("gone", AnnotationKind::Delete, "nowhere ", Some("missing"), None)]);
        let err = compute_ops("some text", &s, &[0]).unwrap_err();
        assert!(err.contains("gone"), "{err}");
    }

    #[test]
    fn ops_apply_in_reverse_so_earlier_offsets_stay_valid() {
        let doc = "The quick brown fox jumps.";
        let ops = vec![
            (4, 9, "slow".to_string()),
            (16, 20, String::new()),
            (25, 25, " high".to_string()),
        ];
        assert_eq!(apply_ops(doc, ops), "The slow brown jumps high.");
    }

    #[test]
    fn mark_accepted_resolves_only_the_given_indices() {
        let mut s = sidecar(vec![
            ann("a", AnnotationKind::Comment, "x", None, None),
            ann("b", AnnotationKind::Comment, "y", None, None),
        ]);
        mark_accepted(&mut s, &[1]);
        assert!(!s.annotations[0].resolved);
        assert!(s.annotations[1].resolved);
        assert_eq!(s.annotations[1].resolved_as.as_deref(), Some("accepted"));
        assert!(s.annotations[1].resolved_at.is_some());
    }
}
