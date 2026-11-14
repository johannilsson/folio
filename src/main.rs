use clap::{Parser, Subcommand};
use folio::commands;
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "folio", about = "Local markdown editor with annotation sidecar")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Open a file, or a set of files, in the Folio macOS app
    Open {
        #[arg(required_unless_present = "set", conflicts_with = "set")]
        file: Option<PathBuf>,
        /// Open a named set of files (see `folio set`)
        #[arg(long)]
        set: Option<String>,
    },
    /// Manage named sets of files reviewed together
    Set {
        #[command(subcommand)]
        command: SetCommands,
    },
    /// Print the open items (#investigate, #waiting, #replied) of markdown files, or of a set
    Items {
        #[arg(required_unless_present = "set")]
        files: Vec<PathBuf>,
        /// Read every file of a named set (see `folio set`), its folders as they are on disk
        #[arg(long)]
        set: Option<String>,
        /// Only items with this tag (one of the set's, see `folio set tags`)
        #[arg(long)]
        tag: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Print the wiki pages of a set that link to a file: to the file, its passages or its annotations
    Refs {
        #[arg(required_unless_present = "dead")]
        file: Option<PathBuf>,
        /// The set whose files and folders are read for links
        #[arg(long)]
        set: String,
        /// Instead, print the links in the set's pages that cannot be followed, and why (a branch no
        /// longer checked out, a file moved, text edited away or an annotation resolved)
        #[arg(long, conflicts_with = "file")]
        dead: bool,
        #[arg(long)]
        json: bool,
    },
    /// Repair links in a set's pages whose branch is gone, when exactly one checkout in the set has the file
    Relink {
        /// The set whose files and folders are read for links
        #[arg(long)]
        set: String,
        /// Print what would change without writing
        #[arg(long)]
        dry_run: bool,
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
    /// Print what changed on the annotations since a time (new annotations, replies, resolutions), as JSON
    Changes {
        file: PathBuf,
        /// A `cursor` from the last call, inclusive; omit for everything
        #[arg(long)]
        since: Option<String>,
        /// Leave out annotations and replies written by this author
        #[arg(long)]
        exclude_author: Option<String>,
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
    /// Print the folio:// link to an annotation, to a passage of the text, or (with neither) to the file
    Link {
        file: PathBuf,
        #[arg(conflicts_with = "passage")]
        id: Option<String>,
        /// Link to this passage (rendered text, as `folio render` shows it) instead of an annotation
        #[arg(long)]
        passage: Option<String>,
        /// With --passage: the rendered words just before it, when it appears more than once
        #[arg(long, requires = "passage")]
        before: Option<String>,
        /// Print a whole markdown link, its text saying what it points at
        #[arg(long)]
        markdown: bool,
    },
    /// Print the plain-text view used by the anchoring engine
    Render {
        file: PathBuf,
    },
}

#[derive(Subcommand)]
enum SetCommands {
    /// Add files or folders to a set, creating it if needed
    Add {
        name: String,
        #[arg(required_unless_present = "folders")]
        files: Vec<PathBuf>,
        /// Add a folder: its markdown files are in the set as they are on disk (repeatable)
        #[arg(long = "folder", value_name = "FOLDER")]
        folders: Vec<PathBuf>,
        /// Directory that holds the `.folio/` sidecars (default: the file's git root)
        #[arg(long)]
        root: Option<PathBuf>,
    },
    /// Remove files or folders from a set, or delete the set when none are given
    Rm {
        name: String,
        files: Vec<PathBuf>,
    },
    /// List sets, or the files in one set
    List {
        name: Option<String>,
    },
    /// Show, add (--add) or remove (--rm) the tags that make a set's task items open ones, with their colours
    Tags {
        name: String,
        /// A tag, or tag:colour (red, orange, yellow, green, blue, purple, pink, gray); repeatable
        #[arg(long = "add", value_name = "TAG[:COLOR]")]
        add: Vec<String>,
        #[arg(long = "rm", value_name = "TAG")]
        remove: Vec<String>,
    },
}

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Open { file, set } => commands::open::run(file.as_deref(), set.as_deref()),
        Commands::Set { command } => match command {
            SetCommands::Add { name, files, folders, root } => commands::set::add(&name, &files, &folders, root.as_ref()),
            SetCommands::Rm { name, files } => commands::set::rm(&name, &files),
            SetCommands::List { name } => commands::set::list(name.as_deref()),
            SetCommands::Tags { name, add, remove } => commands::set::tags(&name, &add, &remove),
        },
        Commands::Items { files, set, tag, json } => commands::items::run(&files, set.as_deref(), tag.as_deref(), json),
        Commands::Refs { file, set, dead, json } => commands::refs::run(file.as_deref(), &set, dead, json),
        Commands::Relink { set, dry_run } => commands::refs::relink(&set, dry_run),
        Commands::Review { file, kind, source, json } => {
            commands::review::run(&file, kind.as_deref(), source.as_deref(), json)
        }
        Commands::Changes { file, since, exclude_author } => {
            commands::changes::run(&file, since.as_deref(), exclude_author.as_deref())
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
        Commands::Link { file, id, passage, before, markdown } => {
            commands::link::run(&file, id.as_deref(), passage.as_deref(), before.as_deref(), markdown)
        }
        Commands::Render { file } => commands::render::run(&file),
    };

    if let Err(e) = result {
        eprintln!("error: {}", e);
        std::process::exit(1);
    }
}
