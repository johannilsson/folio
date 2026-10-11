use std::path::Path;
use std::process::Command;

/// Bundle identifier of Folio.app (macos/Info.plist).
const BUNDLE_ID: &str = "dev.folio.Folio";

/// Open `file` in the Folio macOS app. `FOLIO_APP` names an app bundle to use instead of
/// the registered one, e.g. a build that is not installed.
pub fn run(file: &Path) -> anyhow::Result<()> {
    if !cfg!(target_os = "macos") {
        anyhow::bail!("`folio open` launches the macOS app; use `folio serve` here");
    }
    let path = file
        .canonicalize()
        .map_err(|e| anyhow::anyhow!("cannot open {}: {}", file.display(), e))?;

    let mut open = Command::new("open");
    match std::env::var_os("FOLIO_APP").filter(|a| !a.is_empty()) {
        Some(app) => open.arg("-a").arg(app),
        None => open.args(["-b", BUNDLE_ID]),
    };
    let status = open.arg(&path).status()?;
    if !status.success() {
        anyhow::bail!("could not launch Folio.app (is it installed?); `folio serve` opens it in a browser instead");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_file_is_reported_before_anything_launches() {
        let err = run(Path::new("/definitely/not/here.md")).unwrap_err().to_string();
        if cfg!(target_os = "macos") {
            assert!(err.contains("cannot open"), "{err}");
        }
    }
}
