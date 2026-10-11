use crate::server::DocEntry;
use notify::{Config, Event, EventKind, PollWatcher, RecursiveMode, Watcher};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::broadcast;

pub fn start(
    docs: Arc<Vec<DocEntry>>,
    tx: broadcast::Sender<String>,
) -> anyhow::Result<PollWatcher> {
    let (event_tx, mut event_rx) = tokio::sync::mpsc::unbounded_channel::<notify::Result<Event>>();

    // Polling rather than native events: FSEvents/kqueue watches are bound to the
    // file's inode and go silent after an atomic save (write temp + rename), which
    // is how agents and most editors write files.
    let mut watcher = PollWatcher::new(
        move |res| {
            let _ = event_tx.send(res);
        },
        Config::default().with_poll_interval(Duration::from_millis(300)),
    )?;

    let mut watched_dirs = HashSet::new();
    for doc in docs.iter() {
        watcher.watch(&doc.doc_path, RecursiveMode::NonRecursive)?;
        // folio file may not exist yet; watch its parent dir for create events
        if let Some(parent) = doc.folio_path.parent() {
            if watched_dirs.insert(parent.to_path_buf()) {
                watcher.watch(parent, RecursiveMode::NonRecursive)?;
            }
        }
    }

    tokio::spawn(async move {
        const DEBOUNCE: Duration = Duration::from_millis(500);

        let send = |kind: &str, id: &str| {
            let _ = tx.send(json!({ "type": kind, "file": id }).to_string());
        };

        while let Some(Ok(event)) = event_rx.recv().await {
            if !matches!(
                event.kind,
                EventKind::Modify(_) | EventKind::Create(_)
            ) {
                continue;
            }

            for path in &event.paths {
                for doc in docs.iter() {
                    if path == &doc.doc_path {
                        let skip = {
                            let token = doc.write_token.lock().unwrap();
                            token
                                .map(|t| t.elapsed() < DEBOUNCE)
                                .unwrap_or(false)
                        };
                        if !skip {
                            send("md:changed", &doc.id);
                        }
                    } else if path == &doc.folio_path
                        || doc.folio_path.parent().map_or(false, |p| path == p)
                    {
                        send("folio:changed", &doc.id);
                    }
                }
            }
        }
    });

    Ok(watcher)
}
