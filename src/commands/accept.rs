use crate::accept::{apply_ops, compute_ops, mark_accepted};
use crate::sidecar::Sidecar;
use std::path::Path;
use std::process;

pub fn run(
    file: &Path,
    id: Option<&str>,
    all: bool,
    source_filter: Option<&str>,
    dry_run: bool,
) -> anyhow::Result<()> {
    let folio_path = crate::location::folio_path(file);
    let mut sidecar = Sidecar::load(&folio_path)?;
    let doc = std::fs::read_to_string(file)
        .map_err(|e| anyhow::anyhow!("cannot read {}: {}", file.display(), e))?;

    // Collect indices of annotations to accept
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

    let ops = match compute_ops(&doc, &sidecar, &indices) {
        Ok(ops) => ops,
        Err(msg) => {
            eprintln!("{msg}");
            process::exit(2);
        }
    };

    if dry_run {
        for (start, end, repl) in &ops {
            println!("  [{start}..{end}] → {:?}", repl);
        }
        return Ok(());
    }

    let new_doc = apply_ops(&doc, ops);

    std::fs::write(file, &new_doc)?;

    mark_accepted(&mut sidecar, &indices);
    sidecar.save(&folio_path)?;

    println!("accepted {} annotation(s)", indices.len());
    Ok(())
}
