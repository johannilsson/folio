//! Edits made from the editor, one action at a time: resolving, adding a comment, replying
//! and editing a comment. Undo puts the annotation back as it was (`Restore`, or `Remove` for
//! one that did not exist). The app applies every action to the sidecar as it is on disk
//! (never to a copy of its own), so what an agent wrote in the meantime survives. Accepting
//! is separate: it also patches the markdown (`commands::accept`).

use crate::sidecar::{generate_id, now_iso8601, Annotation, AnnotationKind, AnnotationSource, Sidecar, ThreadReply};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Edit {
    /// Reject a suggestion or dismiss a comment: the annotation stays in the file, resolved.
    Resolve { id: String },
    /// Put an annotation back exactly as given: replaces the one with its id, or adds it.
    Restore { annotation: Annotation },
    /// A new comment from the reader. Its id and time are assigned here.
    AddComment {
        context_before: String,
        #[serde(default)]
        target: Option<String>,
        comment: String,
        author: String,
        source: AnnotationSource,
    },
    /// Undo of `AddComment`.
    Remove { id: String },
    /// A reply on a thread. Its id and time are assigned here.
    Reply {
        id: String,
        body: String,
        author: String,
        source: AnnotationSource,
    },
    EditComment { id: String, comment: String },
}

/// The sidecar after an edit, and the id of what the edit created (an annotation or a reply).
#[derive(Debug, Serialize)]
pub struct Edited {
    pub sidecar: Sidecar,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

fn find<'a>(sidecar: &'a mut Sidecar, id: &str) -> Result<&'a mut Annotation, String> {
    sidecar
        .annotations
        .iter_mut()
        .find(|a| a.id == id)
        .ok_or_else(|| format!("no annotation with id {id}"))
}

fn fresh_id(taken: impl Fn(&str) -> bool, prefix: &str) -> String {
    loop {
        let candidate = generate_id().replacen("ann_", prefix, 1);
        if !taken(&candidate) {
            return candidate;
        }
    }
}

pub fn apply(mut sidecar: Sidecar, edit: Edit) -> Result<Edited, String> {
    let mut created = None;
    match edit {
        Edit::Resolve { id } => {
            let ann = find(&mut sidecar, &id)?;
            // Already resolved (say, accepted by the CLI while the card was still showing): keep how.
            if ann.resolved {
                return Ok(Edited { sidecar, id: None });
            }
            ann.resolved = true;
            // A comment is dismissed; a suggestion (or highlight) is rejected.
            let outcome = if ann.kind == AnnotationKind::Comment { "dismissed" } else { "rejected" };
            ann.resolved_as = Some(outcome.to_string());
            ann.resolved_at = Some(now_iso8601());
        }
        Edit::Restore { annotation } => {
            match sidecar.annotations.iter_mut().find(|a| a.id == annotation.id) {
                Some(slot) => *slot = annotation,
                None => sidecar.annotations.push(annotation),
            }
        }
        Edit::AddComment { context_before, target, comment, author, source } => {
            let id = fresh_id(|c| sidecar.annotations.iter().any(|a| a.id == c), "ann_");
            sidecar.annotations.push(Annotation {
                id: id.clone(),
                kind: AnnotationKind::Comment,
                source,
                author,
                context_before,
                target,
                replacement: None,
                comment: Some(comment),
                created: now_iso8601(),
                resolved: false,
                resolved_as: None,
                resolved_at: None,
                replies: vec![],
            });
            created = Some(id);
        }
        Edit::Remove { id } => {
            let before = sidecar.annotations.len();
            sidecar.annotations.retain(|a| a.id != id);
            if sidecar.annotations.len() == before {
                return Err(format!("no annotation with id {id}"));
            }
        }
        Edit::Reply { id, body, author, source } => {
            let ann = find(&mut sidecar, &id)?;
            let reply_id = fresh_id(|c| ann.replies.iter().any(|r| r.id == c), "reply_");
            ann.replies.push(ThreadReply { id: reply_id.clone(), author, source, body, created: now_iso8601() });
            created = Some(reply_id);
        }
        Edit::EditComment { id, comment } => {
            find(&mut sidecar, &id)?.comment = Some(comment);
        }
    }
    Ok(Edited { sidecar, id: created })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sidecar() -> Sidecar {
        serde_json::from_str(
            r#"{"version":1,"annotations":[
              {"id":"c1","kind":"comment","source":"agent","author":"a","context_before":"x","target":"y","comment":"hm","created":"2026-01-01T00:00:00Z","resolved":false},
              {"id":"r1","kind":"replace","source":"agent","author":"a","context_before":"x","target":"y","replacement":"z","created":"2026-01-01T00:00:00Z","resolved":false}
            ]}"#,
        )
        .unwrap()
    }

    fn edit(json: &str) -> Edit {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn a_comment_is_dismissed_and_a_suggestion_rejected() {
        let out = apply(sidecar(), edit(r#"{"op":"resolve","id":"c1"}"#)).unwrap().sidecar;
        let out = apply(out, edit(r#"{"op":"resolve","id":"r1"}"#)).unwrap().sidecar;
        assert_eq!(out.annotations[0].resolved_as.as_deref(), Some("dismissed"));
        assert_eq!(out.annotations[1].resolved_as.as_deref(), Some("rejected"));
        assert!(out.annotations.iter().all(|a| a.resolved && a.resolved_at.is_some()));
    }

    #[test]
    fn resolving_an_already_resolved_annotation_keeps_its_outcome() {
        let mut s = sidecar();
        s.annotations[1].resolved = true;
        s.annotations[1].resolved_as = Some("accepted".into());
        s.annotations[1].resolved_at = Some("2026-01-02T00:00:00Z".into());
        let out = apply(s, edit(r#"{"op":"resolve","id":"r1"}"#)).unwrap().sidecar;
        assert_eq!(out.annotations[1].resolved_as.as_deref(), Some("accepted"));
        assert_eq!(out.annotations[1].resolved_at.as_deref(), Some("2026-01-02T00:00:00Z"));
    }

    #[test]
    fn restoring_puts_an_annotation_back_as_it_was() {
        let before = sidecar().annotations[1].clone();
        let resolved = apply(sidecar(), edit(r#"{"op":"resolve","id":"r1"}"#)).unwrap().sidecar;
        assert!(resolved.annotations[1].resolved);
        let out = apply(resolved, Edit::Restore { annotation: before.clone() }).unwrap().sidecar;
        assert_eq!(serde_json::to_value(&out.annotations[1]).unwrap(), serde_json::to_value(&before).unwrap());
        // One that is gone is added again; order of the others is kept.
        let removed = apply(out, Edit::Remove { id: "c1".into() }).unwrap().sidecar;
        let back = apply(removed, Edit::Restore { annotation: sidecar().annotations[0].clone() }).unwrap().sidecar;
        assert_eq!(back.annotations.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), ["r1", "c1"]);
    }

    #[test]
    fn a_new_comment_gets_an_id_and_removing_it_undoes_the_add() {
        let added = apply(
            sidecar(),
            edit(r#"{"op":"add_comment","context_before":"a ","target":"b","comment":"note","author":"me","source":"local"}"#),
        )
        .unwrap();
        let id = added.id.clone().unwrap();
        assert!(id.starts_with("ann_") && id.len() == 12);
        let ann = added.sidecar.annotations.last().unwrap();
        assert_eq!((ann.id.as_str(), ann.kind.clone(), ann.resolved), (id.as_str(), AnnotationKind::Comment, false));
        assert_eq!(ann.comment.as_deref(), Some("note"));
        let out = apply(added.sidecar, Edit::Remove { id }).unwrap().sidecar;
        assert_eq!(out.annotations.len(), 2);
    }

    #[test]
    fn a_reply_is_added_with_its_own_id() {
        let added = apply(
            sidecar(),
            edit(r#"{"op":"reply","id":"c1","body":"thanks","author":"me","source":"local"}"#),
        )
        .unwrap();
        let reply_id = added.id.clone().unwrap();
        assert!(reply_id.starts_with("reply_"));
        assert_eq!(added.sidecar.annotations[0].replies[0].body, "thanks");
        assert_eq!(added.sidecar.annotations[0].replies[0].id, reply_id);
    }

    #[test]
    fn editing_replaces_the_comment() {
        let out = apply(sidecar(), edit(r#"{"op":"edit_comment","id":"c1","comment":"better"}"#)).unwrap().sidecar;
        assert_eq!(out.annotations[0].comment.as_deref(), Some("better"));
    }

    #[test]
    fn unknown_ids_are_errors() {
        for json in [
            r#"{"op":"resolve","id":"nope"}"#,
            r#"{"op":"remove","id":"nope"}"#,
            r#"{"op":"reply","id":"nope","body":"x","author":"me","source":"local"}"#,
            r#"{"op":"edit_comment","id":"nope","comment":"x"}"#,
        ] {
            assert!(apply(sidecar(), edit(json)).is_err(), "{json}");
        }
    }

    #[test]
    fn an_agents_other_annotations_are_untouched() {
        // The edit applies to what is on disk, so everything else comes through as it was.
        let out = apply(sidecar(), edit(r#"{"op":"resolve","id":"c1"}"#)).unwrap().sidecar;
        assert_eq!(serde_json::to_value(&out.annotations[1]).unwrap(), serde_json::to_value(&sidecar().annotations[1]).unwrap());
    }
}
