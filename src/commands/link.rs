use crate::sidecar::Sidecar;
use std::path::Path;

/// Percent-encode everything but unreserved characters and `/`.
fn encode(path: &str) -> String {
    let mut out = String::new();
    for b in path.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' | b'/' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

/// The link that opens `file` in Folio with the annotation `id` in view.
pub fn url(file: &Path, id: &str) -> String {
    let file = super::absolute(file);
    format!("folio://annotation/{}?file={}", encode(id), encode(&file.to_string_lossy()))
}

/// Print the link to an annotation, for pasting into another document.
pub fn run(file: &Path, id: &str) -> anyhow::Result<()> {
    let sidecar = Sidecar::load(&super::folio_path(file))?;
    if !sidecar.annotations.iter().any(|a| a.id == id) {
        anyhow::bail!("no annotation {} in {}", id, file.display());
    }
    println!("{}", url(file, id));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_path_is_percent_encoded() {
        if cfg!(windows) {
            let link = url(Path::new(r"C:\definitely\not here\a&b.md"), "ann_k7mxpq2r");
            assert_eq!(link, "folio://annotation/ann_k7mxpq2r?file=C%3A%5Cdefinitely%5Cnot%20here%5Ca%26b.md");
        } else {
            let link = url(Path::new("/definitely/not here/a&b.md"), "ann_k7mxpq2r");
            assert_eq!(link, "folio://annotation/ann_k7mxpq2r?file=/definitely/not%20here/a%26b.md");
        }
    }

    #[test]
    fn run_rejects_an_unknown_annotation_id() {
        let dir = std::env::temp_dir().join(format!("folio-link-{}", std::process::id()));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.canonicalize().unwrap().join("a.md");
        std::fs::write(&file, "Hello.\n").unwrap();
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        let id = Sidecar::load(&super::super::folio_path(&file)).unwrap().annotations[0].id.clone();
        assert!(run(&file, &id).is_ok());
        let err = run(&file, "ann_nope").unwrap_err().to_string();
        assert!(err.contains("no annotation ann_nope"), "{err}");
    }
}
