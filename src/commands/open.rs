use crate::set;
use std::ffi::OsString;
use std::path::Path;
use std::process::Command;

/// Bundle identifier of Folio.app (macos/Info.plist).
const BUNDLE_ID: &str = "dev.folio.Folio";

/// Open a file, or a named set (see `folio set`), in the Folio macOS app. `FOLIO_APP` names
/// an app bundle to use instead of the registered one, e.g. a build that is not installed.
pub fn run(file: Option<&Path>, set_name: Option<&str>) -> anyhow::Result<()> {
    if !cfg!(target_os = "macos") {
        anyhow::bail!("`folio open` launches the macOS app; use `folio serve` here");
    }
    // What the app is asked to open: a file path, or folio://set/<name> for a set.
    let target: OsString = match (file, set_name) {
        (_, Some(name)) => {
            set::load(name)?;
            format!("folio://set/{}", name).into()
        }
        (Some(file), None) => file
            .canonicalize()
            .map_err(|e| anyhow::anyhow!("cannot open {}: {}", file.display(), e))?
            .into_os_string(),
        (None, None) => anyhow::bail!("provide a file or --set <name>"),
    };

    let mut open = Command::new("open");
    match std::env::var_os("FOLIO_APP").filter(|a| !a.is_empty()) {
        Some(app) => open.arg("-a").arg(app),
        None => open.args(["-b", BUNDLE_ID]),
    };
    let status = open.arg(&target).status()?;
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
        let err = run(Some(Path::new("/definitely/not/here.md")), None).unwrap_err().to_string();
        if cfg!(target_os = "macos") {
            assert!(err.contains("cannot open"), "{err}");
        }
    }

    #[test]
    fn an_unknown_set_is_reported_before_anything_launches() {
        let _guard = crate::set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = std::env::temp_dir().join(format!("folio-open-{}", std::process::id()));
        std::env::set_var("FOLIO_CONFIG_DIR", &tmp);
        let err = run(None, Some("nope")).unwrap_err().to_string();
        std::env::remove_var("FOLIO_CONFIG_DIR");
        if cfg!(target_os = "macos") {
            assert!(err.contains("cannot read set"), "{err}");
        }
    }
}
