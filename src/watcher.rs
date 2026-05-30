use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::broadcast;

pub fn start(
    doc_path: PathBuf,
    folio_path: PathBuf,
    write_token: Arc<Mutex<Option<Instant>>>,
    tx: broadcast::Sender<String>,
) -> anyhow::Result<RecommendedWatcher> {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel::<notify::Result<Event>>();

    let doc_path_clone = doc_path.clone();
    let folio_path_clone = folio_path.clone();

    let mut watcher = notify::recommended_watcher(move |res| {
        let _ = event_tx.send(res);
    })?;

    watcher.watch(&doc_path, RecursiveMode::NonRecursive)?;
    // folio file may not exist yet; watch its parent dir for create events
    if let Some(parent) = folio_path.parent() {
        watcher.watch(parent, RecursiveMode::NonRecursive)?;
    }

    tokio::spawn(async move {
        const DEBOUNCE: Duration = Duration::from_millis(500);

        while let Some(Ok(event)) = event_rx.recv().await {
            if !matches!(
                event.kind,
                EventKind::Modify(_) | EventKind::Create(_)
            ) {
                continue;
            }

            for path in &event.paths {
                if path == &doc_path_clone {
                    let skip = {
                        let token = write_token.lock().unwrap();
                        token
                            .map(|t| t.elapsed() < DEBOUNCE)
                            .unwrap_or(false)
                    };
                    if !skip {
                        let _ = tx.send(r#"{"type":"md:changed"}"#.to_string());
                    }
                } else if path == &folio_path_clone {
                    let _ = tx.send(r#"{"type":"folio:changed"}"#.to_string());
                }
            }
        }
    });

    Ok(watcher)
}
