//! What happened on a sidecar since a point in time: new annotations, new replies and
//! resolutions. A poller (`folio changes`, the MCP tool `annotations_since`) asks with the
//! `cursor` of its last answer and gets only what is newer. The times are the ones the
//! sidecar already holds (`created`, `resolved_at`), so nothing new is stored.

use crate::sidecar::{now_iso8601, Annotation, AnnotationKind, AnnotationSource, ResolvedAs, Sidecar};
use serde::Serialize;

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub enum ChangeKind {
    NewAnnotation,
    NewReply,
    Resolved,
}

#[derive(Debug, Serialize)]
pub struct Change {
    pub change: ChangeKind,
    /// The annotation's id (for a reply, the annotation it is on).
    pub id: String,
    /// When it happened.
    pub time: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reply_id: Option<String>,
    /// Who wrote the annotation or the reply. Not given for a resolution: none is recorded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<AnnotationSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<AnnotationKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub replacement: Option<String>,
    /// The comment of a new annotation, or the body of a new reply.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resolved_as: Option<ResolvedAs>,
}

#[derive(Debug, Serialize)]
pub struct Changes {
    /// Pass this as `since` next time.
    pub cursor: String,
    pub changes: Vec<Change>,
}

fn change(kind: ChangeKind, annotation: &Annotation, time: &str) -> Change {
    Change {
        change: kind,
        id: annotation.id.clone(),
        time: time.to_string(),
        reply_id: None,
        author: None,
        source: None,
        kind: None,
        target: None,
        replacement: None,
        text: None,
        resolved_as: None,
    }
}

/// The changes at or after `since` (all of them when it is `None`), oldest first. `since` is
/// inclusive, so a change written in the second of the last cursor is not missed; a caller
/// that sees one twice recognises it by `id`, `reply_id` and `change`. New annotations and
/// replies written by `exclude_author` are left out; resolutions are always given, since
/// the sidecar does not say who resolved.
pub fn since(sidecar: &Sidecar, since: Option<&str>, exclude_author: Option<&str>) -> Vec<Change> {
    let newer = |time: &str| since.is_none_or(|s| time >= s);
    let wanted = |author: &str| exclude_author.is_none_or(|x| author != x);
    let mut out = Vec::new();
    for a in &sidecar.annotations {
        if newer(&a.created) && wanted(&a.author) {
            out.push(Change {
                author: Some(a.author.clone()),
                source: Some(a.source.clone()),
                kind: Some(a.kind.clone()),
                target: a.target.clone(),
                replacement: a.replacement.clone(),
                text: a.comment.clone(),
                ..change(ChangeKind::NewAnnotation, a, &a.created)
            });
        }
        for r in &a.replies {
            if newer(&r.created) && wanted(&r.author) {
                out.push(Change {
                    reply_id: Some(r.id.clone()),
                    author: Some(r.author.clone()),
                    source: Some(r.source.clone()),
                    text: Some(r.body.clone()),
                    ..change(ChangeKind::NewReply, a, &r.created)
                });
            }
        }
        if let (true, Some(at)) = (a.resolved, &a.resolved_at) {
            if newer(at) {
                out.push(Change { resolved_as: a.resolved_as, ..change(ChangeKind::Resolved, a, at) });
            }
        }
    }
    // Stable, so changes in the same second stay in file order.
    out.sort_by(|a, b| a.time.cmp(&b.time));
    out
}

/// `since` with the cursor to ask with next time: the time of this call.
pub fn report(sidecar: &Sidecar, since_time: Option<&str>, exclude_author: Option<&str>) -> Changes {
    Changes { cursor: now_iso8601(), changes: since(sidecar, since_time, exclude_author) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sidecar() -> Sidecar {
        serde_json::from_str(
            r#"{"version":1,"annotations":[
              {"id":"a1","kind":"comment","source":"agent","author":"bot","context_before":"x","target":"y","comment":"hm","created":"2026-01-01T10:00:00Z","resolved":false,
               "replies":[
                 {"id":"r1","author":"me","source":"local","body":"why?","created":"2026-01-01T10:05:00Z"},
                 {"id":"r2","author":"bot","source":"agent","body":"because","created":"2026-01-01T10:06:00Z"}]},
              {"id":"a2","kind":"replace","source":"agent","author":"other","context_before":"x","target":"y","replacement":"z","created":"2026-01-01T10:01:00Z","resolved":true,"resolved_as":"accepted","resolved_at":"2026-01-01T10:07:00Z"},
              {"id":"a3","kind":"highlight","source":"local","author":"me","context_before":"x","target":"y","created":"2026-01-01T10:02:00Z","resolved":false}
            ]}"#,
        )
        .unwrap()
    }

    fn keys(changes: &[Change]) -> Vec<String> {
        changes
            .iter()
            .map(|c| format!("{}:{}", serde_json::to_value(&c.change).unwrap().as_str().unwrap(), c.reply_id.as_deref().unwrap_or(&c.id)))
            .collect()
    }

    #[test]
    fn without_since_everything_is_given_oldest_first() {
        let all = since(&sidecar(), None, None);
        assert_eq!(
            keys(&all),
            ["new_annotation:a1", "new_annotation:a2", "new_annotation:a3", "new_reply:r1", "new_reply:r2", "resolved:a2"]
        );
    }

    #[test]
    fn since_is_inclusive() {
        let from = since(&sidecar(), Some("2026-01-01T10:05:00Z"), None);
        assert_eq!(keys(&from), ["new_reply:r1", "new_reply:r2", "resolved:a2"]);
        assert!(since(&sidecar(), Some("2026-01-01T10:07:01Z"), None).is_empty());
    }

    #[test]
    fn the_filter_is_optional_and_leaves_out_one_author() {
        let s = sidecar();
        assert_eq!(since(&s, None, None).len(), 6);
        assert_eq!(keys(&since(&s, None, Some("bot"))), ["new_annotation:a2", "new_annotation:a3", "new_reply:r1", "resolved:a2"]);
        assert_eq!(since(&s, None, Some("nobody")).len(), 6);
    }

    #[test]
    fn resolutions_are_given_whoever_wrote_the_annotation() {
        // a2 is by "other", resolved by someone unrecorded: an agent must learn its suggestion was accepted.
        let got = since(&sidecar(), None, Some("other"));
        assert!(keys(&got).contains(&"resolved:a2".to_string()));
        assert!(!keys(&got).contains(&"new_annotation:a2".to_string()));
    }

    #[test]
    fn a_change_says_what_it_is() {
        let all = since(&sidecar(), None, None);
        let json = serde_json::to_value(&all).unwrap();
        assert_eq!(json[0]["kind"], "comment");
        assert_eq!(json[0]["text"], "hm");
        assert_eq!(json[1]["replacement"], "z");
        assert_eq!(json[3]["reply_id"], "r1");
        assert_eq!(json[3]["text"], "why?");
        assert_eq!(json[5]["resolved_as"], "accepted");
        assert!(json[5].get("author").is_none());
    }

    #[test]
    fn an_empty_sidecar_has_no_changes_and_still_a_cursor() {
        let r = report(&Sidecar::empty(), Some("2026-01-01T00:00:00Z"), None);
        assert!(r.changes.is_empty());
        assert!(r.cursor.ends_with('Z'));
    }
}
