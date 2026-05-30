use crate::sidecar::{now_iso8601, Sidecar};
use std::path::Path;
use std::process;

pub fn run(
    file: &Path,
    id: Option<&str>,
    all: bool,
    source_filter: Option<&str>,
    dry_run: bool,
) -> anyhow::Result<()> {
    let folio_path = super::folio_path(file);
    let mut sidecar = Sidecar::load(&folio_path)?;

    let indices: Vec<usize> = sidecar
        .annotations
        .iter()
        .enumerate()
        .filter(|(_, a)| !a.resolved)
        .filter(|(_, a)| {
            if all {
                source_filter
                    .map(|s| a.source.to_string() == s)
                    .unwrap_or(true)
            } else {
                id.map(|i| a.id == i).unwrap_or(false)
            }
        })
        .map(|(i, _)| i)
        .collect();

    if indices.is_empty() {
        eprintln!("no matching pending annotations");
        process::exit(1);
    }

    if dry_run {
        for &idx in &indices {
            println!("  would reject {}", sidecar.annotations[idx].id);
        }
        return Ok(());
    }

    let now = now_iso8601();
    for &idx in &indices {
        let ann = &mut sidecar.annotations[idx];
        ann.resolved = true;
        ann.resolved_as = Some("rejected".to_string());
        ann.resolved_at = Some(now.clone());
    }
    sidecar.save(&folio_path)?;

    println!("rejected {} annotation(s)", indices.len());
    Ok(())
}
