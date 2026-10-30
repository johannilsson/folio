//! Accepting annotations: the edits they imply on the markdown, applied in reverse order,
//! and marking them resolved. Shared by `folio accept` and the app (through `ffi`).

use crate::sidecar::{now_iso8601, AnnotationKind, ResolvedAs, Sidecar};

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
        ann.resolved_as = Some(ResolvedAs::outcome(&ann.kind, true));
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
        assert_eq!(s.annotations[1].resolved_as, Some(ResolvedAs::Dismissed));
        assert!(s.annotations[1].resolved_at.is_some());
    }

    #[test]
    fn outcome_depends_on_kind_and_decision() {
        use AnnotationKind::*;
        for accept in [true, false] {
            assert_eq!(ResolvedAs::outcome(&Comment, accept), ResolvedAs::Dismissed);
        }
        assert_eq!(ResolvedAs::outcome(&Highlight, true), ResolvedAs::Accepted);
        assert_eq!(ResolvedAs::outcome(&Replace, false), ResolvedAs::Rejected);
    }
}
