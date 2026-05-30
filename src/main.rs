mod commands;
mod sidecar;
mod server;
mod watcher;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "folio", about = "Local markdown editor with annotation sidecar")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Start the editor server
    Serve {
        file: PathBuf,
        #[arg(short, long)]
        port: Option<u16>,
        #[arg(long, default_value = "127.0.0.1")]
        host: String,
        #[arg(long)]
        no_open: bool,
        #[arg(long)]
        no_watch: bool,
        #[arg(long)]
        read_only: bool,
        #[arg(long)]
        token: Option<String>,
        #[arg(long, default_value = "https://kroki.io")]
        kroki_url: String,
    },
    /// Print pending annotations
    Review {
        file: PathBuf,
        #[arg(long)]
        kind: Option<String>,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Accept and apply annotations
    Accept {
        file: PathBuf,
        id: Option<String>,
        #[arg(long)]
        all: bool,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        dry_run: bool,
    },
    /// Reject annotations
    Reject {
        file: PathBuf,
        id: Option<String>,
        #[arg(long)]
        all: bool,
        #[arg(long)]
        source: Option<String>,
        #[arg(long)]
        dry_run: bool,
    },
    /// Create an empty sidecar
    Init {
        file: PathBuf,
    },
    /// Validate sidecar schema
    Check {
        file: PathBuf,
        #[arg(long)]
        json: bool,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Serve {
            file,
            port,
            host,
            no_open,
            no_watch,
            read_only,
            token,
            kroki_url,
        } => {
            commands::serve::run(file, port, host, no_open, no_watch, read_only, token, kroki_url)
                .await
        }
        Commands::Review { file, kind, source, json } => {
            commands::review::run(&file, kind.as_deref(), source.as_deref(), json)
        }
        Commands::Accept { file, id, all, source, dry_run } => {
            commands::accept::run(&file, id.as_deref(), all, source.as_deref(), dry_run)
        }
        Commands::Reject { file, id, all, source, dry_run } => {
            commands::reject::run(&file, id.as_deref(), all, source.as_deref(), dry_run)
        }
        Commands::Init { file } => commands::init::run(&file),
        Commands::Check { file, json } => commands::check::run(&file, json),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}
