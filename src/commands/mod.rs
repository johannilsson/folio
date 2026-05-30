pub mod accept;
pub mod check;
pub mod init;
pub mod reject;
pub mod review;
pub mod serve;

use std::path::{Path, PathBuf};

pub fn folio_path(file: &Path) -> PathBuf {
    let name = file
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    file.with_file_name(format!("{}.folio", name))
}

pub fn lock_path(file: &Path) -> PathBuf {
    let name = file
        .file_name()
        .unwrap()
        .to_string_lossy()
        .to_string();
    file.with_file_name(format!("{}.folio.lock", name))
}
