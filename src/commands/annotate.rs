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

    let folio_path = crate::location::folio_path(file);
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

    let content = std::fs::read_to_string(file)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;
    if annotation.anchor(&content).is_none() {
        anyhow::bail!(
            "annotation cannot be anchored: context_before + target not found in {}",
            file.display()
        );
    }

    sidecar.annotations.push(annotation);
    sidecar.save(&folio_path)?;
    println!("{}", id);
    Ok(())
}

pub(crate) fn parse_kind(s: &str) -> anyhow::Result<AnnotationKind> {
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

pub(crate) fn validate_fields(
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-annotate-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir.canonicalize().unwrap()
    }

    #[test]
    fn parse_kind_and_source_reject_unknown_values() {
        assert!(parse_kind("replace").is_ok());
        assert!(parse_kind("highlight").is_ok());
        assert!(parse_kind("bogus").is_err());
        assert!(parse_source("agent").is_ok());
        assert!(parse_source("gitlab").is_ok());
        assert!(parse_source("bogus").is_err());
    }

    #[test]
    fn each_kind_requires_its_own_fields() {
        use AnnotationKind::*;
        assert!(validate_fields(&Replace, Some("t"), None, None).is_err());
        assert!(validate_fields(&Replace, None, Some("r"), None).is_err());
        assert!(validate_fields(&Replace, Some("t"), Some("r"), None).is_ok());
        assert!(validate_fields(&Delete, None, None, None).is_err());
        assert!(validate_fields(&Delete, Some("t"), None, None).is_ok());
        assert!(validate_fields(&Insert, None, None, None).is_err());
        assert!(validate_fields(&Insert, None, Some("r"), None).is_ok());
        assert!(validate_fields(&Comment, None, None, None).is_err());
        assert!(validate_fields(&Comment, None, None, Some("c")).is_ok());
        assert!(validate_fields(&Highlight, None, None, None).is_err());
        assert!(validate_fields(&Highlight, Some("t"), None, None).is_ok());
    }

    #[test]
    fn an_unanchorable_annotation_is_not_written_to_the_sidecar() {
        let tmp = temp_dir("unanchored");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let file = tmp.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();

        let err = run(&file, "delete", "Hello ", Some("nowhere"), None, None, "me", "local")
            .unwrap_err();
        assert!(err.to_string().contains("cannot be anchored"));
        assert!(!crate::location::folio_path(&file).exists());
    }

    #[test]
    fn an_anchorable_annotation_is_saved() {
        let tmp = temp_dir("anchored");
        std::fs::create_dir_all(tmp.join(".git")).unwrap();
        let file = tmp.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();

        run(&file, "delete", "Hello ", Some("world"), None, None, "me", "agent").unwrap();
        let sidecar = Sidecar::load(&crate::location::folio_path(&file)).unwrap();
        assert_eq!(sidecar.annotations.len(), 1);
        assert_eq!(sidecar.annotations[0].target.as_deref(), Some("world"));
    }
}
