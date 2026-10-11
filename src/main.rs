mod commands;
mod sidecar;
mod server;
mod set;
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
        #[arg(required_unless_present = "set", conflicts_with = "set")]
        file: Option<PathBuf>,
        /// Serve a named set of files (see `folio set`)
        #[arg(long)]
        set: Option<String>,
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
        #[arg(long, default_value = "https://www.plantuml.com/plantuml")]
        plantuml_url: String,
    },
    /// Manage named sets of files served together
    Set {
        #[command(subcommand)]
        command: SetCommands,
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
    /// Append a single annotation to the sidecar
    Annotate {
        file: PathBuf,
        #[arg(long)]
        kind: String,
        #[arg(long)]
        context_before: String,
        #[arg(long)]
        target: Option<String>,
        #[arg(long)]
        replacement: Option<String>,
        #[arg(long)]
        comment: Option<String>,
        #[arg(long, default_value = "cli")]
        author: String,
        #[arg(long, default_value = "local")]
        source: String,
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
    /// Print the plain-text view used by the anchoring engine
    Render {
        file: PathBuf,
    },
}

#[derive(Subcommand)]
enum SetCommands {
    /// Add files to a set, creating it if needed
    Add {
        name: String,
        #[arg(required = true)]
        files: Vec<PathBuf>,
        /// Directory that holds the `.folio/` sidecars (default: the file's git root)
        #[arg(long)]
        root: Option<PathBuf>,
    },
    /// Remove files from a set, or delete the set when no files are given
    Rm {
        name: String,
        files: Vec<PathBuf>,
    },
    /// List sets, or the files in one set
    List {
        name: Option<String>,
    },
}

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Serve {
            file,
            set,
            port,
            host,
            no_open,
            no_watch,
            read_only,
            token,
            kroki_url,
            plantuml_url,
        } => {
            commands::serve::run(file, set, port, host, no_open, no_watch, read_only, token, kroki_url, plantuml_url)
                .await
        }
        Commands::Set { command } => match command {
            SetCommands::Add { name, files, root } => commands::set::add(&name, &files, root.as_ref()),
            SetCommands::Rm { name, files } => commands::set::rm(&name, &files),
            SetCommands::List { name } => commands::set::list(name.as_deref()),
        },
        Commands::Review { file, kind, source, json } => {
            commands::review::run(&file, kind.as_deref(), source.as_deref(), json)
        }
        Commands::Accept { file, id, all, source, dry_run } => {
            commands::accept::run(&file, id.as_deref(), all, source.as_deref(), dry_run)
        }
        Commands::Reject { file, id, all, source, dry_run } => {
            commands::reject::run(&file, id.as_deref(), all, source.as_deref(), dry_run)
        }
        Commands::Annotate { file, kind, context_before, target, replacement, comment, author, source } => {
            commands::annotate::run(
                &file,
                &kind,
                &context_before,
                target.as_deref(),
                replacement.as_deref(),
                comment.as_deref(),
                &author,
                &source,
            )
        }
        Commands::Init { file } => commands::init::run(&file),
        Commands::Check { file, json } => commands::check::run(&file, json),
        Commands::Render { file } => commands::render::run(&file),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}
