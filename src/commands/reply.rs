use crate::edit::{self, Edit};
use crate::sidecar::Sidecar;
use std::path::Path;

pub fn run(file: &Path, id: &str, body: &str, author: &str, source: &str) -> anyhow::Result<()> {
    let source = super::annotate::parse_source(source)?;
    let folio_path = crate::location::folio_path(file);
    let sidecar = Sidecar::load(&folio_path)?;
    let edit = Edit::Reply { id: id.to_string(), body: body.to_string(), author: author.to_string(), source };
    let edited = edit::apply(sidecar, edit).map_err(anyhow::Error::msg)?;
    edited.sidecar.save(&folio_path)?;
    println!("{}", edited.id.unwrap_or_default());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document(tag: &str) -> (std::path::PathBuf, String) {
        let dir = std::env::temp_dir().join(format!("folio-reply-{}-{}", tag, std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.join("a.md");
        std::fs::write(&file, "Hello world.\n").unwrap();
        let _ = std::fs::remove_file(crate::location::folio_path(&file));
        super::super::annotate::run(&file, "comment", "Hello ", None, None, Some("why"), "bot", "agent").unwrap();
        let id = Sidecar::load(&crate::location::folio_path(&file)).unwrap().annotations[0].id.clone();
        (file, id)
    }

    #[test]
    fn a_reply_joins_the_thread() {
        let (file, id) = document("joins");
        run(&file, &id, "Because.", "me", "local").unwrap();
        let sidecar = Sidecar::load(&crate::location::folio_path(&file)).unwrap();
        let replies = &sidecar.annotations[0].replies;
        assert_eq!((replies.len(), replies[0].body.as_str(), replies[0].author.as_str()), (1, "Because.", "me"));
        assert!(replies[0].id.starts_with("reply_"));
        assert!(!sidecar.annotations[0].resolved);
    }

    #[test]
    fn replying_to_an_unknown_annotation_fails_and_writes_nothing() {
        let (file, _) = document("unknown");
        let err = run(&file, "nope", "x", "me", "local").unwrap_err();
        assert!(err.to_string().contains("no annotation with id nope"));
        assert!(Sidecar::load(&crate::location::folio_path(&file)).unwrap().annotations[0].replies.is_empty());
    }

    #[test]
    fn an_unknown_source_is_refused() {
        let (file, id) = document("source");
        assert!(run(&file, &id, "x", "me", "bogus").is_err());
    }
}
