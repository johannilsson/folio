use crate::server::{build_router, AppState, DocEntry};
use crate::set;
use crate::watcher;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

#[derive(Serialize, Deserialize)]
struct LockFile {
    pid: u32,
    port: u16,
}

fn lock_path(file: &Path) -> PathBuf {
    super::lock_path(file)
}

fn pid_alive(pid: u32) -> bool {
    #[cfg(unix)]
    {
        std::process::Command::new("kill")
            .args(["-0", &pid.to_string()])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = pid;
        true
    }
}

/// What `folio serve` was asked to serve: the documents, the lock file that marks
/// the running server, and a label for the startup banner.
struct Target {
    docs: Vec<DocEntry>,
    set_name: Option<String>,
    lock: PathBuf,
    label: String,
}

fn single_target(file: PathBuf) -> Target {
    let file = file.canonicalize().unwrap_or(file);
    let label = file.file_name().unwrap().to_string_lossy().to_string();
    let group = file
        .parent()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    Target {
        set_name: None,
        lock: lock_path(&file),
        docs: vec![DocEntry {
            id: "main".to_string(),
            name: label.clone(),
            group,
            folio_path: super::folio_path(&file),
            doc_path: file,
            write_token: Arc::new(Mutex::new(None)),
        }],
        label,
    }
}

fn set_target(name: &str) -> anyhow::Result<Target> {
    let loaded = set::load(name)?;
    if loaded.files.is_empty() {
        anyhow::bail!("set '{}' has no files; add some with `folio set add {} <files>`", name, name);
    }
    let mut docs = Vec::new();
    for entry in &loaded.files {
        if !entry.path.is_file() {
            anyhow::bail!("{} (in set '{}') does not exist", entry.path.display(), name);
        }
        let described = set::describe(entry);
        docs.push(DocEntry {
            id: entry.id.clone(),
            name: described.name,
            group: described.group,
            folio_path: described.folio_path,
            doc_path: entry.path.clone(),
            write_token: Arc::new(Mutex::new(None)),
        });
    }
    Ok(Target {
        set_name: Some(name.to_string()),
        label: format!("set {} ({} files)", name, docs.len()),
        lock: set::lock_path(name)?,
        docs,
    })
}

#[allow(clippy::too_many_arguments)]
pub async fn run(
    file: Option<PathBuf>,
    set_name: Option<String>,
    port: Option<u16>,
    host: String,
    no_open: bool,
    no_watch: bool,
    read_only: bool,
    token: Option<String>,
    kroki_url: String,
    plantuml_url: String,
) -> anyhow::Result<()> {
    let target = match (file, set_name) {
        (_, Some(name)) => set_target(&name)?,
        (Some(file), None) => single_target(file),
        (None, None) => anyhow::bail!("provide a file or --set <name>"),
    };
    for doc in &target.docs {
        if let Some(parent) = doc.folio_path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
    }
    let lock = target.lock;
    let doc_name = target.label;
    if let Some(parent) = lock.parent() {
        std::fs::create_dir_all(parent).ok();
    }

    // Check for existing server via lock file
    if lock.exists() {
        if let Ok(content) = std::fs::read_to_string(&lock) {
            if let Ok(lf) = serde_json::from_str::<LockFile>(&content) {
                if pid_alive(lf.pid) {
                    let url = format!("http://{}:{}", host, lf.port);
                    println!("Folio  {}  already running", doc_name);
                    println!("       {}", url);
                    return Ok(());
                }
            }
        }
        // Stale lock — remove it
        let _ = std::fs::remove_file(&lock);
    }

    // Bind listener
    let listener = bind_listener(&host, port).await?;
    let addr = listener.local_addr()?;
    let actual_port = addr.port();

    // Write lock file
    let lock_content = serde_json::to_string(&LockFile {
        pid: std::process::id(),
        port: actual_port,
    })?;
    std::fs::write(&lock, &lock_content)?;

    let (tx, _) = broadcast::channel::<String>(64);
    let docs = Arc::new(target.docs);
    let set_name = target.set_name;

    // Start file watcher
    let _watcher = if !no_watch {
        Some(watcher::start(Arc::clone(&docs), tx.clone())?)
    } else {
        None
    };

    let state = AppState {
        docs,
        set_name,
        tx,
        read_only,
        token,
        kroki_url,
        plantuml_url,
    };

    let app = build_router(state);
    let url = format!("http://{}", addr);

    println!("Folio  {}", doc_name);
    println!("       {}", url);
    println!("       Ctrl-C to stop");

    if !no_open {
        let _ = open::that(&url);
    }

    // Graceful shutdown on Ctrl-C / SIGTERM
    let lock_clone = lock.clone();
    let shutdown = async move {
        #[cfg(unix)]
        {
            use tokio::signal::unix::{signal, SignalKind};
            let mut sigterm = signal(SignalKind::terminate()).unwrap();
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = sigterm.recv() => {}
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
        let _ = std::fs::remove_file(&lock_clone);
    };

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown)
        .await?;

    Ok(())
}

async fn bind_listener(host: &str, port: Option<u16>) -> anyhow::Result<TcpListener> {
    if let Some(p) = port {
        let addr: SocketAddr = format!("{}:{}", host, p).parse()?;
        return Ok(TcpListener::bind(addr).await?);
    }

    // Try 7070 first
    let addr7070: SocketAddr = format!("{}:7070", host).parse()?;
    if let Ok(l) = TcpListener::bind(addr7070).await {
        return Ok(l);
    }

    // Fall back to OS-assigned port
    let addr0: SocketAddr = format!("{}:0", host).parse()?;
    Ok(TcpListener::bind(addr0).await?)
}
