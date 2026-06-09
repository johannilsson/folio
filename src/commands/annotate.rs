use crate::sidecar::{Annotation, AnnotationKind, AnnotationSource, Sidecar, generate_id, now_iso8601};
use std::path::Path;

pub fn run(
    file: &Path,
    kind: &str,
    context_before: &str,
    target: Option<&str>,
    replacement: Option<&str>,
    comment: Option<&str>,
    author: &str,
    source: &str,
) -> anyhow::Result<()> {
    let kind = parse_kind(kind)?;
    let source = parse_source(source)?;

    validate_fields(&kind, target, replacement, comment)?;

    let folio_path = super::folio_path(file);
    let mut sidecar = if folio_path.exists() {
        Sidecar::load(&folio_path)?
    } else {
        if let Some(parent) = folio_path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        Sidecar::empty()
    };

    let existing_ids: std::collections::HashSet<&str> =
        sidecar.annotations.iter().map(|a| a.id.as_str()).collect();
    let id = loop {
        let candidate = generate_id();
        if !existing_ids.contains(candidate.as_str()) {
            break candidate;
        }
    };

    let annotation = Annotation {
        id: id.clone(),
        kind,
        source,
        author: author.to_string(),
        context_before: context_before.to_string(),
        target: target.map(str::to_string),
        replacement: replacement.map(str::to_string),
        comment: comment.map(str::to_string),
        created: now_iso8601(),
        resolved: false,
        resolved_as: None,
        resolved_at: None,
        replies: vec![],
    };

    sidecar.annotations.push(annotation);
    sidecar.save(&folio_path)?;
    println!("{}", id);
    Ok(())
}

fn parse_kind(s: &str) -> anyhow::Result<AnnotationKind> {
    match s {
        "replace" => Ok(AnnotationKind::Replace),
        "delete" => Ok(AnnotationKind::Delete),
        "insert" => Ok(AnnotationKind::Insert),
        "comment" => Ok(AnnotationKind::Comment),
        "highlight" => Ok(AnnotationKind::Highlight),
        _ => anyhow::bail!("unknown kind '{}'; expected replace, delete, insert, comment, or highlight", s),
    }
}

fn parse_source(s: &str) -> anyhow::Result<AnnotationSource> {
    match s {
        "local" => Ok(AnnotationSource::Local),
        "agent" => Ok(AnnotationSource::Agent),
        "github" => Ok(AnnotationSource::Github),
        "gitlab" => Ok(AnnotationSource::Gitlab),
        _ => anyhow::bail!("unknown source '{}'; expected local, agent, github, or gitlab", s),
    }
}

fn validate_fields(
    kind: &AnnotationKind,
    target: Option<&str>,
    replacement: Option<&str>,
    comment: Option<&str>,
) -> anyhow::Result<()> {
    match kind {
        AnnotationKind::Replace => {
            if target.is_none() {
                anyhow::bail!("--target is required for kind 'replace'");
            }
            if replacement.is_none() {
                anyhow::bail!("--replacement is required for kind 'replace'");
            }
        }
        AnnotationKind::Delete => {
            if target.is_none() {
                anyhow::bail!("--target is required for kind 'delete'");
            }
        }
        AnnotationKind::Insert => {
            if replacement.is_none() {
                anyhow::bail!("--replacement is required for kind 'insert'");
            }
        }
        AnnotationKind::Comment => {
            if comment.is_none() {
                anyhow::bail!("--comment is required for kind 'comment'");
            }
        }
        AnnotationKind::Highlight => {
            if target.is_none() {
                anyhow::bail!("--target is required for kind 'highlight'");
            }
        }
    }
    Ok(())
}
