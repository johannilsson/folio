use crate::server::{build_router, AppState};
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

pub async fn run(
    file: PathBuf,
    port: Option<u16>,
    host: String,
    no_open: bool,
    no_watch: bool,
    read_only: bool,
    token: Option<String>,
    kroki_url: String,
) -> anyhow::Result<()> {
    let file = file.canonicalize().unwrap_or(file);
    let folio_path = super::folio_path(&file);
    let lock = lock_path(&file);
    let doc_name = file.file_name().unwrap().to_string_lossy().to_string();

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
    let write_token = Arc::new(Mutex::new(None));

    // Start file watcher
    let _watcher = if !no_watch {
        Some(watcher::start(
            file.clone(),
            folio_path.clone(),
            Arc::clone(&write_token),
            tx.clone(),
        )?)
    } else {
        None
    };

    let state = AppState {
        doc_path: file.clone(),
        folio_path,
        write_token,
        tx,
        read_only,
        token,
        kroki_url,
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
