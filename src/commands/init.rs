use crate::sidecar::Sidecar;
use std::path::Path;

pub fn run(file: &Path) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    if folio_path.exists() {
        return Ok(());
    }
    if let Some(parent) = folio_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    Sidecar::empty().save(&folio_path)?;
    println!("Created {}", folio_path.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_file(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-init-{}-{}-{}",
            tag,
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let dir = dir.canonicalize().unwrap();
        let file = dir.join("a.md");
        std::fs::write(&file, "Hello.\n").unwrap();
        file
    }

    #[test]
    fn creates_an_empty_sidecar() {
        let file = temp_file("create");
        run(&file).unwrap();
        let s = Sidecar::load(&crate::location::folio_path(&file)).unwrap();
        assert!(s.annotations.is_empty());
    }

    #[test]
    fn leaves_an_existing_sidecar_alone() {
        let file = temp_file("existing");
        super::super::annotate::run(&file, "highlight", "", Some("Hello"), None, None, "me", "local").unwrap();
        run(&file).unwrap();
        let s = Sidecar::load(&crate::location::folio_path(&file)).unwrap();
        assert_eq!(s.annotations.len(), 1);
    }
}
