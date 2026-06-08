pub mod accept;
pub mod check;
pub mod init;
pub mod reject;
pub mod render;
pub mod review;
pub mod serve;

use std::path::{Path, PathBuf};

fn sidecar_relative(file: &Path) -> PathBuf {
    let cwd = std::env::current_dir().expect("cannot read cwd");
    let canonical = file
        .canonicalize()
        .unwrap_or_else(|_| if file.is_absolute() { file.to_path_buf() } else { cwd.join(file) });
    canonical
        .strip_prefix(&cwd)
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|_| canonical.strip_prefix("/").unwrap_or(&canonical).to_path_buf())
}

pub fn folio_path(file: &Path) -> PathBuf {
    let cwd = std::env::current_dir().expect("cannot read cwd");
    let relative = sidecar_relative(file);
    let dir = relative.parent().unwrap_or(Path::new(""));
    let name = relative.file_name().unwrap().to_string_lossy();
    cwd.join(".folio").join(dir).join(format!("{}.folio", name))
}

pub fn lock_path(file: &Path) -> PathBuf {
    let cwd = std::env::current_dir().expect("cannot read cwd");
    let relative = sidecar_relative(file);
    let dir = relative.parent().unwrap_or(Path::new(""));
    let name = relative.file_name().unwrap().to_string_lossy();
    cwd.join(".folio").join(dir).join(format!("{}.folio.lock", name))
}
