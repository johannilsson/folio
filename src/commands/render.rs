use std::path::Path;

pub fn run(file: &Path) -> anyhow::Result<()> {
    let doc = std::fs::read_to_string(file)?;
    print!("{}", crate::sidecar::render_plain_text(&doc));
    Ok(())
}
