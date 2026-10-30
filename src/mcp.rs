//! The MCP server: the tools an assistant such as Claude desktop gets for reviewing markdown
//! with Folio. Claude starts the app's own binary with `--mcp` and speaks JSON-RPC to it over
//! stdin and stdout, one message per line. The file tools work on the markdown and its sidecar
//! on disk, with the same engine as the CLI and the app; the `current_document`, `focused_annotation`
//! and `reveal` tools ask the running app through `live`.

use crate::commands::annotate::{parse_kind, validate_fields};
use crate::edit::{self, Edit};
use crate::live::{self, LiveError};
use crate::set;
use crate::sidecar::{generate_id, now_iso8601, render_plain_text, Annotation, AnnotationSource, Sidecar};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

/// Newest first. A client asking for one of these gets it; any other gets the newest.
const PROTOCOL_VERSIONS: [&str; 3] = ["2025-06-18", "2025-03-26", "2024-11-05"];

/// Who annotations and replies are by when the assistant does not say.
const DEFAULT_AUTHOR: &str = "claude";

/// What the running app can be asked. A trait so the tools can be tested without one.
pub trait App {
    fn ask(&self, op: &str, args: Value) -> Result<Value, LiveError>;
}

/// The app that is running on this Mac, if any.
pub struct RunningApp;

impl App for RunningApp {
    fn ask(&self, op: &str, args: Value) -> Result<Value, LiveError> {
        live::request(op, args)
    }
}

/// Runs the server on stdin and stdout until the client closes them. The exit code.
pub fn serve_stdio() -> i32 {
    // `open` should launch the app this server belongs to, not whichever copy is registered.
    if std::env::var_os("FOLIO_APP").is_none() {
        if let Some(bundle) = own_app_bundle() {
            std::env::set_var("FOLIO_APP", bundle);
        }
    }
    let stdin = std::io::stdin();
    match serve(stdin.lock(), std::io::stdout().lock(), &RunningApp) {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("folio mcp: {e}");
            1
        }
    }
}

/// `Folio.app` when this binary is `Folio.app/Contents/MacOS/Folio`.
fn own_app_bundle() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(Path::to_path_buf)
}

pub fn serve(input: impl BufRead, mut output: impl Write, app: &dyn App) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let reply = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&message, app),
            Err(_) => Some(failure(Value::Null, -32700, "parse error")),
        };
        if let Some(reply) = reply {
            writeln!(output, "{reply}")?;
            output.flush()?;
        }
    }
    Ok(())
}

fn success(id: Value, result: Value) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "result": result })
}

fn failure(id: Value, code: i32, message: &str) -> Value {
    json!({ "jsonrpc": "2.0", "id": id, "error": { "code": code, "message": message } })
}

/// The response to one message, or None for a notification (and anything that is not a request).
fn handle(message: &Value, app: &dyn App) -> Option<Value> {
    let method = message.get("method")?.as_str()?;
    let id = message.get("id")?.clone();
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    Some(match method {
        "initialize" => {
            let asked = params.get("protocolVersion").and_then(Value::as_str);
            let version = PROTOCOL_VERSIONS.iter().find(|v| Some(**v) == asked).unwrap_or(&PROTOCOL_VERSIONS[0]);
            success(
                id,
                json!({
                    "protocolVersion": version,
                    "capabilities": { "tools": {} },
                    "serverInfo": { "name": "folio", "version": env!("CARGO_PKG_VERSION") },
                    "instructions": INSTRUCTIONS,
                }),
            )
        }
        "ping" => success(id, json!({})),
        "tools/list" => success(id, json!({ "tools": tools() })),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
            if !tools().as_array().is_some_and(|t| t.iter().any(|t| t["name"] == name)) {
                return Some(failure(id, -32602, &format!("unknown tool: {name}")));
            }
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            let (text, is_error) = match call(name, &args, app) {
                Ok(text) => (text, false),
                Err(text) => (text, true),
            };
            success(id, json!({ "content": [{ "type": "text", "text": text }], "isError": is_error }))
        }
        _ => failure(id, -32601, &format!("method not found: {method}")),
    })
}

const INSTRUCTIONS: &str = "Folio is a markdown review tool. You review a document by annotating it: \
replacements, deletions, insertions, highlights and comments, which the person accepts or rejects in \
the Folio app. You never edit the markdown file itself. Call `render` first and copy every \
`context_before` and `target` from its output, then `annotate`. The annotations and their threads are \
what the person works with: `list_annotations` shows them, `reply` answers one, and `focused_annotation` \
is the one they have open right now.";

fn tool(name: &str, description: &str, read_only: bool, properties: Value, required: &[&str]) -> Value {
    json!({
        "name": name,
        "description": description,
        "inputSchema": { "type": "object", "properties": properties, "required": required },
        "annotations": { "readOnlyHint": read_only, "destructiveHint": false, "openWorldHint": false },
    })
}

fn tools() -> Value {
    let file = json!({ "type": "string", "description": "Absolute path of the markdown file." });
    let author = json!({ "type": "string", "description": "Who is writing; shown on the card. Defaults to \"claude\"." });
    json!([
        tool(
            "render",
            "The plain text of a markdown file as Folio anchors annotations against it: no heading marks, emphasis, \
             list markers or link syntax. Read this before annotating and copy `context_before` and `target` from it.",
            true,
            json!({ "file": file }),
            &["file"],
        ),
        tool(
            "list_annotations",
            "The annotations on a markdown file, with their replies. Each pending one says whether it still \
             `anchored` in the text. Resolved (accepted, rejected or dismissed) ones are left out unless asked for.",
            true,
            json!({ "file": file, "include_resolved": { "type": "boolean", "description": "Also list resolved annotations." } }),
            &["file"],
        ),
        tool(
            "annotate",
            "Add annotations to a markdown file for the person to review in Folio. Kinds: `replace` (needs target and \
             replacement), `delete` (target), `insert` (replacement, placed right after context_before), `highlight` \
             (target), `comment` (comment; with a target to attach it to a passage, without one to attach it after \
             context_before). `context_before` is the 30 to 60 characters of plain text just before the target and \
             `target` is the exact text, both as `render` shows them: no markdown syntax. All annotations are checked \
             against the document first; if any does not anchor, none is written and the error says which.",
            false,
            json!({
                "file": file,
                "author": author,
                "annotations": {
                    "type": "array",
                    "minItems": 1,
                    "items": {
                        "type": "object",
                        "properties": {
                            "kind": { "type": "string", "enum": ["replace", "delete", "insert", "highlight", "comment"] },
                            "context_before": { "type": "string" },
                            "target": { "type": "string" },
                            "replacement": { "type": "string" },
                            "comment": { "type": "string", "description": "A note for the person; markdown." },
                        },
                        "required": ["kind", "context_before"],
                    },
                },
            }),
            &["file", "annotations"],
        ),
        tool(
            "reply",
            "Reply on an annotation's thread, for instance to answer a comment the person wrote. Replies to resolved \
             annotations are not shown in Folio.",
            false,
            json!({
                "file": file,
                "author": author,
                "id": { "type": "string", "description": "The annotation's id, from list_annotations." },
                "body": { "type": "string", "description": "The reply; markdown." },
            }),
            &["file", "id", "body"],
        ),
        tool(
            "verify",
            "Check that every pending annotation of a markdown file still anchors in the text. Run it after annotating, \
             and after the document has changed.",
            true,
            json!({ "file": file }),
            &["file"],
        ),
        tool(
            "set_list",
            "Without a name, the names of the sets. With one, the files in that set. A set groups markdown files, from \
             any folders, to be reviewed together in one window.",
            true,
            json!({ "name": { "type": "string" } }),
            &[],
        ),
        tool(
            "set_add",
            "Add markdown files to a set, creating the set if needed.",
            false,
            json!({
                "name": { "type": "string", "description": "Letters, digits, \"-\", \"_\" and \".\"." },
                "files": { "type": "array", "items": { "type": "string" }, "description": "Absolute paths." },
            }),
            &["name", "files"],
        ),
        tool(
            "set_remove",
            "Remove files from a set. The files themselves are not touched.",
            false,
            json!({
                "name": { "type": "string" },
                "files": { "type": "array", "items": { "type": "string" }, "description": "Absolute paths." },
            }),
            &["name", "files"],
        ),
        tool(
            "open",
            "Open a markdown file, or a set, in the Folio app, starting it if needed.",
            false,
            json!({ "file": file, "set": { "type": "string", "description": "Open this set instead of a file." } }),
            &[],
        ),
        tool(
            "current_document",
            "The files the person has open in Folio, the one in front first: path, sidecar, set, whether it shows \
             the preview or the source, and how many annotations are pending.",
            true,
            json!({}),
            &[],
        ),
        tool(
            "focused_annotation",
            "The annotation the person has focused in the front Folio window (by clicking its card or its text, or \
             stepping to it), with its whole thread. Use it for requests like \"answer this one\" or \"fix this\".",
            true,
            json!({}),
            &[],
        ),
        tool(
            "reveal",
            "Bring a file into view in Folio, opening it if needed, and focus one of its annotations.",
            false,
            json!({ "file": file, "id": { "type": "string", "description": "An annotation to focus." } }),
            &["file"],
        ),
    ])
}

fn call(name: &str, args: &Value, app: &dyn App) -> Result<String, String> {
    let result = match name {
        "render" => render(args),
        "list_annotations" => list_annotations(args),
        "annotate" => annotate(args),
        "reply" => reply(args),
        "verify" => verify(args),
        "set_list" => set_list(args),
        "set_add" => set_add(args),
        "set_remove" => set_remove(args),
        "open" => open(args),
        "current_document" => current_document(app),
        "focused_annotation" => focused_annotation(app),
        "reveal" => reveal(args, app),
        _ => Err(format!("unknown tool: {name}")),
    }?;
    Ok(match result {
        Value::String(text) => text,
        other => serde_json::to_string_pretty(&other).unwrap_or_default(),
    })
}

// MARK: arguments

fn string_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str, String> {
    args.get(key).and_then(Value::as_str).ok_or_else(|| format!("`{key}` is required (a string)"))
}

fn author_arg(args: &Value) -> String {
    args.get("author").and_then(Value::as_str).filter(|a| !a.trim().is_empty()).unwrap_or(DEFAULT_AUTHOR).to_string()
}

/// An absolute path to a markdown file. Folio only works on those, and the tools write beside them.
fn path_value(raw: &str) -> Result<PathBuf, String> {
    let path = match raw.strip_prefix("~/") {
        Some(rest) => PathBuf::from(std::env::var_os("HOME").or_else(|| std::env::var_os("USERPROFILE")).unwrap_or_default()).join(rest),
        None => PathBuf::from(raw),
    };
    if !path.is_absolute() {
        return Err(format!("give an absolute path, not {raw}"));
    }
    let extension = path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase);
    if !matches!(extension.as_deref(), Some("md" | "markdown" | "mdown" | "mkd")) {
        return Err(format!("{raw} is not a markdown file (.md, .markdown, .mdown or .mkd)"));
    }
    Ok(path)
}

fn file_arg(args: &Value) -> Result<PathBuf, String> {
    path_value(string_arg(args, "file")?)
}

fn files_arg(args: &Value) -> Result<Vec<PathBuf>, String> {
    let files = args.get("files").and_then(Value::as_array).ok_or("`files` is required (an array of paths)")?;
    files.iter().map(|f| path_value(f.as_str().ok_or("`files` must hold strings")?)).collect()
}

fn read(file: &Path) -> Result<String, String> {
    std::fs::read_to_string(file).map_err(|e| format!("cannot read {}: {e}", file.display()))
}

fn load_sidecar(folio: &Path) -> Result<Sidecar, String> {
    if folio.exists() {
        Sidecar::load(folio).map_err(|e| e.to_string())
    } else {
        Ok(Sidecar::empty())
    }
}

fn text_list(paths: &[PathBuf]) -> Vec<String> {
    paths.iter().map(|p| p.to_string_lossy().into_owned()).collect()
}

// MARK: file tools

fn render(args: &Value) -> Result<Value, String> {
    Ok(Value::String(render_plain_text(&read(&file_arg(args)?)?)))
}

fn list_annotations(args: &Value) -> Result<Value, String> {
    let file = file_arg(args)?;
    let content = read(&file)?;
    let folio = crate::commands::folio_path(&file);
    let all = args.get("include_resolved").and_then(Value::as_bool).unwrap_or(false);
    let annotations: Vec<Value> = load_sidecar(&folio)?
        .annotations
        .iter()
        .filter(|a| all || !a.resolved)
        .map(|a| {
            let mut value = serde_json::to_value(a).unwrap_or_default();
            if !a.resolved {
                value["anchored"] = json!(a.anchor(&content).is_some());
            }
            value
        })
        .collect();
    Ok(json!({ "sidecar": folio, "annotations": annotations }))
}

fn annotate(args: &Value) -> Result<Value, String> {
    let file = file_arg(args)?;
    let items = args
        .get("annotations")
        .and_then(Value::as_array)
        .filter(|a| !a.is_empty())
        .ok_or("`annotations` is required (a list with at least one annotation)")?;
    let author = author_arg(args);
    let content = read(&file)?;
    let folio = crate::commands::folio_path(&file);
    let mut sidecar = load_sidecar(&folio)?;

    let optional = |item: &Value, key: &str| item.get(key).and_then(Value::as_str).map(str::to_string);
    let mut added = Vec::new();
    let mut problems = Vec::new();
    for (i, item) in items.iter().enumerate() {
        let built = (|| -> Result<Annotation, String> {
            let kind = parse_kind(item.get("kind").and_then(Value::as_str).unwrap_or_default()).map_err(|e| e.to_string())?;
            let context_before = optional(item, "context_before").ok_or("`context_before` is required")?;
            let (target, replacement, comment) = (optional(item, "target"), optional(item, "replacement"), optional(item, "comment"));
            validate_fields(&kind, target.as_deref(), replacement.as_deref(), comment.as_deref())
                .map_err(|e| e.to_string().replace("--", ""))?;
            let mut id = generate_id();
            while sidecar.annotations.iter().chain(&added).any(|a: &Annotation| a.id == id) {
                id = generate_id();
            }
            let annotation = Annotation {
                id,
                kind,
                source: AnnotationSource::Agent,
                author: author.clone(),
                context_before,
                target,
                replacement,
                comment,
                created: now_iso8601(),
                resolved: false,
                resolved_as: None,
                resolved_at: None,
                replies: vec![],
            };
            if annotation.anchor(&content).is_none() {
                return Err("does not anchor: `context_before` + `target` is not in the document's text. \
                            Copy both from `render`, without markdown syntax"
                    .to_string());
            }
            Ok(annotation)
        })();
        match built {
            Ok(annotation) => added.push(annotation),
            Err(problem) => problems.push(format!("annotations[{i}]: {problem}")),
        }
    }
    if !problems.is_empty() {
        return Err(format!("nothing was written.\n{}", problems.join("\n")));
    }

    let summary: Vec<Value> = added.iter().map(|a| json!({ "id": a.id, "kind": a.kind })).collect();
    sidecar.annotations.extend(added);
    if let Some(parent) = folio.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    sidecar.save(&folio).map_err(|e| e.to_string())?;
    Ok(json!({ "sidecar": folio, "added": summary }))
}

fn reply(args: &Value) -> Result<Value, String> {
    let file = file_arg(args)?;
    let folio = crate::commands::folio_path(&file);
    if !folio.exists() {
        return Err(format!("{} has no annotations yet", file.display()));
    }
    let edit = Edit::Reply {
        id: string_arg(args, "id")?.to_string(),
        body: string_arg(args, "body")?.to_string(),
        author: author_arg(args),
        source: AnnotationSource::Agent,
    };
    // Applied to what is on disk now, so the person's own changes in the app are kept.
    let edited = edit::apply(load_sidecar(&folio)?, edit)?;
    edited.sidecar.save(&folio).map_err(|e| e.to_string())?;
    Ok(json!({ "reply_id": edited.id }))
}

fn verify(args: &Value) -> Result<Value, String> {
    let file = file_arg(args)?;
    let content = read(&file)?;
    let folio = crate::commands::folio_path(&file);
    let sidecar = load_sidecar(&folio)?;
    let pending: Vec<&Annotation> = sidecar.annotations.iter().filter(|a| !a.resolved).collect();
    let unanchored: Vec<&str> = pending.iter().filter(|a| a.anchor(&content).is_none()).map(|a| a.id.as_str()).collect();
    Ok(json!({ "valid": unanchored.is_empty(), "pending": pending.len(), "unanchored": unanchored, "sidecar": folio }))
}

// MARK: sets

fn set_list(args: &Value) -> Result<Value, String> {
    match args.get("name").and_then(Value::as_str) {
        None => Ok(json!({ "sets": set::list_names().map_err(|e| e.to_string())? })),
        Some(name) => {
            let loaded = set::load(name).map_err(|e| e.to_string())?;
            let files: Vec<Value> = loaded
                .files
                .iter()
                .map(|entry| {
                    let described = set::describe(entry);
                    json!({ "path": entry.path, "name": described.name, "group": described.group, "sidecar": described.folio_path })
                })
                .collect();
            Ok(json!({ "name": name, "files": files }))
        }
    }
}

fn set_add(args: &Value) -> Result<Value, String> {
    let outcome = set::add_files(string_arg(args, "name")?, &files_arg(args)?, None).map_err(|e| e.to_string())?;
    Ok(json!({ "added": text_list(&outcome.added), "already_in_set": text_list(&outcome.already) }))
}

fn set_remove(args: &Value) -> Result<Value, String> {
    let removed = set::remove_files(string_arg(args, "name")?, &files_arg(args)?).map_err(|e| e.to_string())?;
    Ok(json!({ "removed": text_list(&removed) }))
}

fn open(args: &Value) -> Result<Value, String> {
    let set_name = args.get("set").and_then(Value::as_str);
    let file = match args.get("file").and_then(Value::as_str) {
        Some(raw) if set_name.is_none() => Some(path_value(raw)?),
        _ => None,
    };
    crate::commands::open::run(file.as_deref(), set_name).map_err(|e| e.to_string())?;
    Ok(Value::String("Opened in Folio.".to_string()))
}

// MARK: what the person is looking at

fn ask(app: &dyn App, op: &str, args: Value) -> Result<Value, String> {
    app.ask(op, args).map_err(|e| e.to_string())
}

/// The windows the app reports, the front one marked `"front": true`.
fn windows(app: &dyn App) -> Result<Vec<Value>, String> {
    let state = ask(app, "state", json!({}))?;
    Ok(state.get("windows").and_then(Value::as_array).cloned().unwrap_or_default())
}

fn front_window(app: &dyn App) -> Result<Value, String> {
    windows(app)?
        .into_iter()
        .find(|w| w["front"] == true)
        .ok_or_else(|| "No document is open in Folio.".to_string())
}

fn current_document(app: &dyn App) -> Result<Value, String> {
    let windows = windows(app)?;
    if windows.is_empty() {
        return Err("No document is open in Folio.".to_string());
    }
    Ok(json!({ "windows": windows }))
}

fn focused_annotation(app: &dyn App) -> Result<Value, String> {
    let window = front_window(app)?;
    let file = window["file"].as_str().unwrap_or_default();
    let Some(id) = window.get("focused").and_then(Value::as_str) else {
        return Ok(Value::String(format!("No annotation is focused in {file}.")));
    };
    let folio = PathBuf::from(window["sidecar"].as_str().unwrap_or_default());
    let found = load_sidecar(&folio)?.annotations.into_iter().find(|a| a.id == id);
    match found {
        Some(annotation) => Ok(json!({ "file": file, "annotation": annotation })),
        None => Err(format!("annotation {id} is no longer in {}", folio.display())),
    }
}

fn reveal(args: &Value, app: &dyn App) -> Result<Value, String> {
    let file = file_arg(args)?;
    let mut request = json!({ "file": file });
    if let Some(id) = args.get("id").and_then(Value::as_str) {
        request["id"] = json!(id);
    }
    ask(app, "reveal", request)?;
    Ok(Value::String("Shown in Folio.".to_string()))
}

// MARK: connecting Claude desktop and Codex

/// A tool whose config Folio can write itself (the Add button in Folio ▸ Connect to MCP Clients…).
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Client {
    ClaudeDesktop,
    Codex,
}

impl Client {
    /// As the app names it to `folio_mcp_connect`.
    pub fn from_id(id: &str) -> Option<Client> {
        match id {
            "claude" => Some(Client::ClaudeDesktop),
            "codex" => Some(Client::Codex),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Client::ClaudeDesktop => "claude",
            Client::Codex => "codex",
        }
    }

    pub fn config_path(self) -> anyhow::Result<PathBuf> {
        match self {
            Client::ClaudeDesktop => claude_config_path(),
            Client::Codex => codex_config_path(),
        }
    }

    pub fn connect(self, exe: &Path, config: &Path) -> anyhow::Result<Connected> {
        match self {
            Client::ClaudeDesktop => connect_claude(exe, config),
            Client::Codex => connect_codex(exe, config),
        }
    }
}

/// Claude desktop's config file.
pub fn claude_config_path() -> anyhow::Result<PathBuf> {
    if let Some(path) = std::env::var_os("FOLIO_CLAUDE_CONFIG").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    #[cfg(windows)]
    if let Some(appdata) = std::env::var_os("APPDATA").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(appdata).join("Claude").join("claude_desktop_config.json"));
    }
    let home = std::env::var_os("HOME").ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join("Library/Application Support/Claude/claude_desktop_config.json"))
}

/// Codex's config file (the CLI's and the app's): `$CODEX_HOME/config.toml`, by default in `~/.codex`.
pub fn codex_config_path() -> anyhow::Result<PathBuf> {
    if let Some(dir) = std::env::var_os("CODEX_HOME").filter(|p| !p.is_empty()) {
        return Ok(PathBuf::from(dir).join("config.toml"));
    }
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .ok_or_else(|| anyhow::anyhow!("HOME is not set"))?;
    Ok(PathBuf::from(home).join(".codex").join("config.toml"))
}

/// What connecting did to a config.
#[derive(Debug, PartialEq)]
pub enum Connected {
    Added,
    Updated,
    Unchanged,
}

/// Registers `exe --mcp` as the `folio` MCP server in Claude desktop's config, keeping everything
/// else in the file. Claude reads the file at startup, so it has to be restarted after.
pub fn connect_claude(exe: &Path, config: &Path) -> anyhow::Result<Connected> {
    let dir = config.parent().unwrap_or(Path::new("."));
    if !dir.is_dir() {
        anyhow::bail!("Claude does not seem to be installed: {} does not exist", dir.display());
    }
    let mut root: Value = match std::fs::read_to_string(config) {
        Ok(text) if !text.trim().is_empty() => serde_json::from_str(&text).map_err(|e| {
            anyhow::anyhow!("{} is not valid JSON ({e}). Fix or remove it, then try again.", config.display())
        })?,
        _ => json!({}),
    };
    let servers = root
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("{} does not hold a JSON object", config.display()))?
        .entry("mcpServers")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| anyhow::anyhow!("\"mcpServers\" in {} is not an object", config.display()))?;

    let command = json!(exe.to_string_lossy());
    let args = json!(["--mcp"]);
    let outcome = match servers.get("folio") {
        None => Connected::Added,
        Some(entry) if entry["command"] == command && entry["args"] == args => return Ok(Connected::Unchanged),
        Some(_) => Connected::Updated,
    };
    // Other keys of an existing entry (an `env`, say) stay.
    let entry = servers.entry("folio").or_insert_with(|| json!({}));
    if !entry.is_object() {
        *entry = json!({});
    }
    entry["command"] = command;
    entry["args"] = args;

    replace_file(config, &(serde_json::to_string_pretty(&root)? + "\n"))?;
    Ok(outcome)
}

/// Registers `exe --mcp` as the `folio` MCP server in Codex's config (`[mcp_servers.folio]`), keeping
/// everything else in the file, comments and layout included. Codex reads it when it starts.
pub fn connect_codex(exe: &Path, config: &Path) -> anyhow::Result<Connected> {
    use toml_edit::{value, Array, DocumentMut, Item, Table};

    let dir = config.parent().unwrap_or(Path::new("."));
    if !dir.is_dir() {
        anyhow::bail!("Codex does not seem to be installed: {} does not exist", dir.display());
    }
    let text = std::fs::read_to_string(config).unwrap_or_default();
    let mut doc: DocumentMut = text.parse().map_err(|e| {
        anyhow::anyhow!("{} is not valid TOML ({e}). Fix or remove it, then try again.", config.display())
    })?;
    let servers = doc.entry("mcp_servers").or_insert_with(|| {
        let mut table = Table::new();
        table.set_implicit(true);
        Item::Table(table)
    });
    let servers = servers
        .as_table_like_mut()
        .ok_or_else(|| anyhow::anyhow!("\"mcp_servers\" in {} is not a table", config.display()))?;

    let command = exe.to_string_lossy();
    let outcome = match servers.get("folio") {
        None => Connected::Added,
        Some(entry)
            if entry.get("command").and_then(Item::as_str) == Some(&*command)
                && entry.get("args").and_then(Item::as_array).is_some_and(|a| {
                    a.len() == 1 && a.get(0).and_then(|v| v.as_str()) == Some("--mcp")
                }) =>
        {
            return Ok(Connected::Unchanged)
        }
        Some(_) => Connected::Updated,
    };
    // Other keys of an existing entry (an `env`, say) stay.
    let entry = servers.entry("folio").or_insert(Item::Table(Table::new()));
    if !entry.is_table_like() {
        *entry = Item::Table(Table::new());
    }
    let entry = entry.as_table_like_mut().expect("a table");
    entry.insert("command", value(&*command));
    entry.insert("args", value(Array::from_iter(["--mcp"])));

    replace_file(config, &doc.to_string())?;
    Ok(outcome)
}

/// Writes `text` to `path` through a temporary file beside it, so a failed write leaves the old file.
fn replace_file(path: &Path, text: &str) -> anyhow::Result<()> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = PathBuf::from(tmp);
    std::fs::write(&tmp, text)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })?;
    Ok(())
}

// MARK: connecting other tools

/// What to run or paste to register `exe --mcp` as the `folio` server in a tool.
#[derive(Debug, PartialEq)]
pub struct Snippet {
    pub name: &'static str,
    /// Where it goes.
    pub hint: &'static str,
    pub text: String,
    /// Set when Folio can also write it into the tool's config itself.
    pub client: Option<Client>,
}

/// A path as one word of a shell command.
fn shell_word(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// A string as TOML and JSON both write it: quoted, with quotes, backslashes and control characters escaped.
fn quoted(text: &str) -> String {
    serde_json::to_string(text).unwrap_or_default()
}

pub fn client_snippets(exe: &Path) -> Vec<Snippet> {
    let exe = exe.to_string_lossy();
    let json = serde_json::to_string_pretty(&json!({ "mcpServers": { "folio": { "command": exe, "args": ["--mcp"] } } }))
        .unwrap_or_default();
    vec![
        Snippet {
            name: "Claude Code",
            hint: "Run it in a terminal.",
            text: format!("claude mcp add folio -- {} --mcp\n", shell_word(&exe)),
            client: None,
        },
        Snippet {
            name: "Claude Desktop",
            hint: "Goes in Claude's config, merged into its \"mcpServers\". Restart Claude after.",
            text: format!("{json}\n"),
            client: Some(Client::ClaudeDesktop),
        },
        Snippet {
            name: "Codex",
            hint: "Run it in a terminal, or put the lines in Codex's config. Restart Codex after.",
            text: format!(
                "codex mcp add folio -- {word} --mcp\n\n[mcp_servers.folio]\ncommand = {path}\nargs = [\"--mcp\"]\n",
                word = shell_word(&exe),
                path = quoted(&exe)
            ),
            client: Some(Client::Codex),
        },
        Snippet {
            name: "Other tools (JSON)",
            hint: "Cursor (~/.cursor/mcp.json), Gemini CLI, Windsurf and most others take this in their MCP settings.",
            text: format!("{json}\n"),
            client: None,
        },
        Snippet {
            name: "Any MCP client",
            hint: "For a tool that asks for a command and its arguments. The server speaks MCP over stdio.",
            text: format!("command:    {exe}\narguments: --mcp\n"),
            client: None,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    struct NoApp;
    impl App for NoApp {
        fn ask(&self, _op: &str, _args: Value) -> Result<Value, LiveError> {
            Err(LiveError::NotRunning)
        }
    }

    /// An app with canned answers; it remembers what it was asked.
    struct FakeApp {
        windows: Value,
        asked: std::sync::Mutex<Vec<(String, Value)>>,
    }
    impl App for FakeApp {
        fn ask(&self, op: &str, args: Value) -> Result<Value, LiveError> {
            self.asked.lock().unwrap().push((op.to_string(), args));
            Ok(if op == "state" { json!({ "windows": self.windows }) } else { json!({}) })
        }
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "folio-mcp-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dunce::canonicalize(dir).unwrap()
    }

    /// An absolute path on this system: `/etc/hosts`, or `C:/etc/hosts` on Windows.
    fn absolute(path: &str) -> String {
        if cfg!(windows) { format!("C:{path}") } else { path.to_string() }
    }

    /// A markdown file in a throwaway repo.
    fn document(tag: &str, text: &str) -> PathBuf {
        let dir = temp_dir(tag);
        std::fs::create_dir_all(dir.join(".git")).unwrap();
        let file = dir.join("doc.md");
        std::fs::write(&file, text).unwrap();
        file
    }

    const DOC: &str = "# Title\n\nThe quick **brown** fox jumps over the lazy dog.\n";

    /// Sends the messages and returns the responses.
    fn exchange(app: &dyn App, messages: &[Value]) -> Vec<Value> {
        let input: String = messages.iter().map(|m| format!("{m}\n")).collect();
        let mut output = Vec::new();
        serve(Cursor::new(input), &mut output, app).unwrap();
        String::from_utf8(output).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect()
    }

    fn tool_call(app: &dyn App, name: &str, args: Value) -> (bool, String) {
        let reply = &exchange(app, &[json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": { "name": name, "arguments": args } })])[0];
        (reply["result"]["isError"] == true, reply["result"]["content"][0]["text"].as_str().unwrap().to_string())
    }

    fn ok(app: &dyn App, name: &str, args: Value) -> Value {
        let (is_error, text) = tool_call(app, name, args);
        assert!(!is_error, "{name}: {text}");
        serde_json::from_str(&text).unwrap_or(Value::String(text))
    }

    fn err(app: &dyn App, name: &str, args: Value) -> String {
        let (is_error, text) = tool_call(app, name, args);
        assert!(is_error, "{name} should have failed: {text}");
        text
    }

    #[test]
    fn the_handshake_lists_the_tools_and_ignores_notifications() {
        let replies = exchange(
            &NoApp,
            &[
                json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": { "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": { "name": "t", "version": "1" } } }),
                json!({ "jsonrpc": "2.0", "method": "notifications/initialized" }),
                json!({ "jsonrpc": "2.0", "id": 2, "method": "ping" }),
                json!({ "jsonrpc": "2.0", "id": 3, "method": "tools/list" }),
                json!({ "jsonrpc": "2.0", "id": 4, "method": "nope" }),
                json!({ "jsonrpc": "2.0", "id": 5, "method": "initialize", "params": { "protocolVersion": "1999-01-01" } }),
            ],
        );
        // The notification got no reply.
        assert_eq!(replies.len(), 5);
        assert_eq!(replies[0]["id"], 1);
        assert_eq!(replies[0]["result"]["protocolVersion"], "2024-11-05");
        assert_eq!(replies[0]["result"]["serverInfo"]["name"], "folio");
        assert!(replies[0]["result"]["capabilities"]["tools"].is_object());
        assert_eq!(replies[1]["result"], json!({}));
        let names: Vec<&str> = replies[2]["result"]["tools"].as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            ["render", "list_annotations", "annotate", "reply", "verify", "set_list", "set_add", "set_remove", "open",
             "current_document", "focused_annotation", "reveal"]
        );
        for tool in replies[2]["result"]["tools"].as_array().unwrap() {
            assert_eq!(tool["inputSchema"]["type"], "object");
            assert!(tool["description"].as_str().unwrap().len() > 20);
        }
        assert_eq!(replies[3]["error"]["code"], -32601);
        // An unknown version gets the newest.
        assert_eq!(replies[4]["result"]["protocolVersion"], PROTOCOL_VERSIONS[0]);
    }

    #[test]
    fn garbage_and_unknown_tools_are_errors_not_crashes() {
        let mut output = Vec::new();
        serve(Cursor::new("not json\n\n{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\"}}\n"), &mut output, &NoApp).unwrap();
        let lines: Vec<Value> = String::from_utf8(output).unwrap().lines().map(|l| serde_json::from_str(l).unwrap()).collect();
        assert_eq!(lines[0]["error"]["code"], -32700);
        assert_eq!(lines[1]["id"], 7);
        assert_eq!(lines[1]["error"]["code"], -32602);
    }

    #[test]
    fn paths_must_be_absolute_markdown_files() {
        assert!(err(&NoApp, "render", json!({ "file": "doc.md" })).contains("absolute"));
        assert!(err(&NoApp, "render", json!({ "file": absolute("/etc/passwd") })).contains("not a markdown file"));
        assert!(err(&NoApp, "render", json!({})).contains("`file` is required"));
        assert!(err(&NoApp, "render", json!({ "file": absolute("/definitely/not/here.md") })).contains("cannot read"));
    }

    #[test]
    fn render_gives_the_text_annotations_anchor_against() {
        let file = document("render", DOC);
        let text = ok(&NoApp, "render", json!({ "file": file }));
        assert!(text.as_str().unwrap().contains("The quick brown fox"), "{text}");
        assert!(!text.as_str().unwrap().contains("**"));
    }

    #[test]
    fn annotate_writes_the_sidecar_the_cli_and_app_read() {
        let file = document("annotate", DOC);
        let out = ok(
            &NoApp,
            "annotate",
            json!({ "file": file, "annotations": [
                { "kind": "replace", "context_before": "The quick brown ", "target": "fox", "replacement": "cat", "comment": "tone" },
                { "kind": "comment", "context_before": "jumps over the lazy ", "target": "dog", "comment": "which dog?" },
            ] }),
        );
        assert_eq!(out["added"].as_array().unwrap().len(), 2);
        let folio = crate::commands::folio_path(&file);
        assert_eq!(out["sidecar"], json!(folio));
        let sidecar = Sidecar::load(&folio).unwrap();
        assert_eq!(sidecar.annotations.len(), 2);
        let first = &sidecar.annotations[0];
        assert_eq!((first.author.as_str(), first.source.clone(), first.resolved), ("claude", AnnotationSource::Agent, false));
        assert_eq!(first.replacement.as_deref(), Some("cat"));
        assert_ne!(first.id, sidecar.annotations[1].id);
        // The markdown is never touched.
        assert_eq!(std::fs::read_to_string(&file).unwrap(), DOC);

        // A later call adds to the file rather than replacing it.
        ok(&NoApp, "annotate", json!({ "file": file, "author": "reviewer", "annotations": [{ "kind": "highlight", "context_before": "The quick ", "target": "brown" }] }));
        let sidecar = Sidecar::load(&folio).unwrap();
        assert_eq!(sidecar.annotations.len(), 3);
        assert_eq!(sidecar.annotations[2].author, "reviewer");
    }

    #[test]
    fn annotate_writes_nothing_unless_every_annotation_anchors_and_says_which_does_not() {
        let file = document("allornothing", DOC);
        let message = err(
            &NoApp,
            "annotate",
            json!({ "file": file, "annotations": [
                { "kind": "delete", "context_before": "The quick brown ", "target": "fox" },
                { "kind": "delete", "context_before": "nowhere ", "target": "to be found" },
                { "kind": "replace", "context_before": "The ", "target": "quick" },
                { "kind": "bogus", "context_before": "x" },
            ] }),
        );
        assert!(message.contains("nothing was written"), "{message}");
        assert!(!message.contains("annotations[0]"), "{message}");
        assert!(message.contains("annotations[1]: does not anchor"), "{message}");
        assert!(message.contains("annotations[2]") && message.contains("replacement"), "{message}");
        assert!(message.contains("annotations[3]") && message.contains("unknown kind"), "{message}");
        assert!(!crate::commands::folio_path(&file).exists());
        assert!(err(&NoApp, "annotate", json!({ "file": file, "annotations": [] })).contains("`annotations` is required"));
    }

    #[test]
    fn list_annotations_hides_resolved_ones_and_flags_those_that_no_longer_anchor() {
        let file = document("list", DOC);
        ok(&NoApp, "annotate", json!({ "file": file, "annotations": [
            { "kind": "delete", "context_before": "The quick brown ", "target": "fox" },
            { "kind": "delete", "context_before": "jumps over the lazy ", "target": "dog" },
        ] }));
        let empty = ok(&NoApp, "list_annotations", json!({ "file": document("list-empty", DOC) }));
        assert_eq!(empty["annotations"], json!([]));

        // The text changes underneath one of them, and the person rejects the other.
        let folio = crate::commands::folio_path(&file);
        let mut sidecar = Sidecar::load(&folio).unwrap();
        let rejected = edit::apply(sidecar.clone(), Edit::Resolve { id: sidecar.annotations[1].id.clone() }).unwrap();
        sidecar = rejected.sidecar;
        sidecar.save(&folio).unwrap();
        std::fs::write(&file, DOC.replace("fox", "cat")).unwrap();

        let listed = ok(&NoApp, "list_annotations", json!({ "file": file }));
        let pending = listed["annotations"].as_array().unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0]["anchored"], false);
        let all = ok(&NoApp, "list_annotations", json!({ "file": file, "include_resolved": true }));
        assert_eq!(all["annotations"].as_array().unwrap().len(), 2);
        assert!(all["annotations"][1].get("anchored").is_none());

        let checked = ok(&NoApp, "verify", json!({ "file": file }));
        assert_eq!((checked["valid"].clone(), checked["pending"].clone()), (json!(false), json!(1)));
        assert_eq!(checked["unanchored"], json!([pending[0]["id"]]));
        std::fs::write(&file, DOC).unwrap();
        assert_eq!(ok(&NoApp, "verify", json!({ "file": file }))["valid"], true);
    }

    #[test]
    fn a_reply_joins_the_thread_and_keeps_what_else_is_on_disk() {
        let file = document("reply", DOC);
        assert!(err(&NoApp, "reply", json!({ "file": file, "id": "x", "body": "hi" })).contains("no annotations yet"));
        let added = ok(&NoApp, "annotate", json!({ "file": file, "annotations": [{ "kind": "comment", "context_before": "The quick brown ", "target": "fox", "comment": "why a fox?" }] }));
        let id = added["added"][0]["id"].as_str().unwrap();

        let replied = ok(&NoApp, "reply", json!({ "file": file, "id": id, "body": "Because.", "author": "claude-2" }));
        assert!(replied["reply_id"].as_str().unwrap().starts_with("reply_"));
        let sidecar = Sidecar::load(&crate::commands::folio_path(&file)).unwrap();
        let thread = &sidecar.annotations[0].replies;
        assert_eq!((thread[0].body.as_str(), thread[0].author.as_str(), thread[0].source.clone()), ("Because.", "claude-2", AnnotationSource::Agent));
        assert!(err(&NoApp, "reply", json!({ "file": file, "id": "nope", "body": "x" })).contains("no annotation with id"));
    }

    #[test]
    fn sets_are_listed_added_to_and_removed_from() {
        let _guard = set::TEST_ENV.lock().unwrap_or_else(|e| e.into_inner());
        let config = temp_dir("sets-config");
        std::env::set_var("FOLIO_CONFIG_DIR", &config);
        let (a, b) = (document("set-a", DOC), document("set-b", DOC));

        assert_eq!(ok(&NoApp, "set_list", json!({})), json!({ "sets": [] }));
        let added = ok(&NoApp, "set_add", json!({ "name": "review", "files": [a, b] }));
        assert_eq!(added["added"].as_array().unwrap().len(), 2);
        let again = ok(&NoApp, "set_add", json!({ "name": "review", "files": [a] }));
        assert_eq!(again["already_in_set"].as_array().unwrap().len(), 1);
        assert_eq!(ok(&NoApp, "set_list", json!({})), json!({ "sets": ["review"] }));
        let files = ok(&NoApp, "set_list", json!({ "name": "review" }));
        assert_eq!(files["files"].as_array().unwrap().len(), 2);
        assert_eq!(files["files"][0]["name"], "doc.md");
        assert_eq!(ok(&NoApp, "set_remove", json!({ "name": "review", "files": [a] }))["removed"].as_array().unwrap().len(), 1);
        assert_eq!(ok(&NoApp, "set_list", json!({ "name": "review" }))["files"].as_array().unwrap().len(), 1);
        assert!(err(&NoApp, "set_list", json!({ "name": "../evil" })).contains("invalid set name"));
        assert!(err(&NoApp, "set_add", json!({ "name": "review", "files": [absolute("/etc/hosts")] })).contains("not a markdown file"));

        std::env::remove_var("FOLIO_CONFIG_DIR");
    }

    fn window(file: &Path, front: bool, focused: Value) -> Value {
        json!({
            "front": front,
            "file": file,
            "sidecar": crate::commands::folio_path(file),
            "mode": "preview",
            "pending": 1,
            "focused": focused,
        })
    }

    #[test]
    fn the_tools_for_the_running_app_report_what_the_person_is_looking_at() {
        let file = document("live", DOC);
        let added = ok(&NoApp, "annotate", json!({ "file": file, "annotations": [{ "kind": "comment", "context_before": "The quick brown ", "target": "fox", "comment": "why?" }] }));
        let id = added["added"][0]["id"].clone();
        let other = document("live-other", DOC);

        let app = FakeApp {
            windows: json!([window(&other, false, Value::Null), window(&file, true, id.clone())]),
            asked: Default::default(),
        };
        let current = ok(&app, "current_document", json!({}));
        assert_eq!(current["windows"].as_array().unwrap().len(), 2);
        assert_eq!(current["windows"][1]["front"], true);

        let focused = ok(&app, "focused_annotation", json!({}));
        assert_eq!(focused["annotation"]["id"], id);
        assert_eq!(focused["annotation"]["comment"], "why?");

        // The thread comes with it, so an answer can build on what was said.
        ok(&NoApp, "reply", json!({ "file": file, "id": id, "body": "Because." }));
        assert_eq!(ok(&app, "focused_annotation", json!({}))["annotation"]["replies"][0]["body"], "Because.");

        ok(&app, "reveal", json!({ "file": file, "id": "ann_1" }));
        assert_eq!(app.asked.lock().unwrap().last().unwrap(), &("reveal".to_string(), json!({ "file": file, "id": "ann_1" })));

        // Nothing focused is an answer, not an error.
        let idle = FakeApp { windows: json!([window(&file, true, Value::Null)]), asked: Default::default() };
        assert!(ok(&idle, "focused_annotation", json!({})).as_str().unwrap().starts_with("No annotation is focused"));
        let none = FakeApp { windows: json!([]), asked: Default::default() };
        assert!(err(&none, "focused_annotation", json!({})).contains("No document is open"));
    }

    #[test]
    fn the_app_tools_say_so_when_folio_is_not_running() {
        for name in ["current_document", "focused_annotation"] {
            assert!(err(&NoApp, name, json!({})).contains("Folio is not running"), "{name}");
        }
        assert!(err(&NoApp, "reveal", json!({ "file": absolute("/a.md") })).contains("Folio is not running"));
    }

    #[test]
    fn open_reports_what_it_cannot_do_before_launching_anything() {
        // Off a Mac there is no app to launch, which it says first; on one, what is missing.
        let expected = if cfg!(target_os = "macos") { "provide a file" } else { "macOS app" };
        assert!(err(&NoApp, "open", json!({})).contains(expected));
        assert!(err(&NoApp, "open", json!({ "file": "relative.md" })).contains("absolute"));
    }

    #[test]
    fn other_tools_get_snippets_that_quote_the_path() {
        let exe = Path::new("/Users/me/My \"Apps\"/it's/Folio.app/Contents/MacOS/Folio");
        let snippets = client_snippets(exe);
        let names: Vec<_> = snippets.iter().map(|s| s.name).collect();
        assert_eq!(names, ["Claude Code", "Claude Desktop", "Codex", "Other tools (JSON)", "Any MCP client"]);
        let clients: Vec<_> = snippets.iter().map(|s| s.client).collect();
        assert_eq!(clients, [None, Some(Client::ClaudeDesktop), Some(Client::Codex), None, None]);

        assert!(snippets[0].text.starts_with("claude mcp add folio -- '/Users"));
        let json: Value = serde_json::from_str(&snippets[1].text).unwrap();
        assert_eq!(json["mcpServers"]["folio"], json!({ "command": exe, "args": ["--mcp"] }));

        let codex = &snippets[2].text;
        assert!(codex.starts_with("codex mcp add folio -- '/Users/me/My \"Apps\"/it'\\''s/Folio.app/Contents/MacOS/Folio' --mcp"), "{codex}");
        // The TOML half parses as a basic string holding the same path.
        let command = codex.lines().find_map(|l| l.strip_prefix("command = ")).unwrap();
        assert_eq!(serde_json::from_str::<String>(command).unwrap(), exe.to_string_lossy());
        assert!(codex.contains("[mcp_servers.folio]") && codex.contains("args = [\"--mcp\"]"));

        let json: Value = serde_json::from_str(&snippets[3].text).unwrap();
        assert_eq!(json["mcpServers"]["folio"], json!({ "command": exe, "args": ["--mcp"] }));
        assert!(snippets[4].text.contains(&*exe.to_string_lossy()) && snippets[4].text.contains("--mcp"));
        assert!(snippets.iter().all(|s| !s.hint.is_empty()));
    }

    // MARK: connecting Claude

    fn claude_dir(tag: &str) -> (PathBuf, PathBuf) {
        let dir = temp_dir(tag);
        let config = dir.join("claude_desktop_config.json");
        (dir, config)
    }

    #[test]
    fn connecting_creates_the_entry_and_keeps_everything_else() {
        let exe = Path::new("/Applications/Folio.app/Contents/MacOS/Folio");
        let (_dir, config) = claude_dir("connect");

        assert_eq!(connect_claude(exe, &config).unwrap(), Connected::Added);
        let written: Value = serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
        assert_eq!(written["mcpServers"]["folio"], json!({ "command": exe, "args": ["--mcp"] }));

        // Another server, an unrelated setting, and an `env` on our entry survive; the order is kept.
        std::fs::write(
            &config,
            r#"{ "theme": "dark", "mcpServers": { "other": { "command": "x" }, "folio": { "command": "/old/Folio", "args": ["--mcp"], "env": { "A": "1" } } }, "zeta": 1 }"#,
        )
        .unwrap();
        assert_eq!(connect_claude(exe, &config).unwrap(), Connected::Updated);
        let text = std::fs::read_to_string(&config).unwrap();
        let written: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(written["theme"], "dark");
        assert_eq!(written["mcpServers"]["other"], json!({ "command": "x" }));
        assert_eq!(written["mcpServers"]["folio"], json!({ "command": exe, "args": ["--mcp"], "env": { "A": "1" } }));
        assert!(text.find("theme").unwrap() < text.find("mcpServers").unwrap() && text.find("mcpServers").unwrap() < text.find("zeta").unwrap());

        // Doing it again changes nothing.
        let before = std::fs::read_to_string(&config).unwrap();
        assert_eq!(connect_claude(exe, &config).unwrap(), Connected::Unchanged);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), before);
        assert!(!config.with_extension("json.tmp").exists());
    }

    #[test]
    fn connecting_does_not_overwrite_a_config_it_cannot_read() {
        let exe = Path::new("/Applications/Folio.app/Contents/MacOS/Folio");
        let (dir, config) = claude_dir("connect-bad");
        std::fs::write(&config, "{ not json").unwrap();
        let message = connect_claude(exe, &config).unwrap_err().to_string();
        assert!(message.contains("not valid JSON"), "{message}");
        assert_eq!(std::fs::read_to_string(&config).unwrap(), "{ not json");

        std::fs::write(&config, r#"{ "mcpServers": [] }"#).unwrap();
        assert!(connect_claude(exe, &config).unwrap_err().to_string().contains("not an object"));
        std::fs::write(&config, "[]").unwrap();
        assert!(connect_claude(exe, &config).unwrap_err().to_string().contains("JSON object"));

        // An empty file is as good as none; a missing Claude folder is reported.
        std::fs::write(&config, "").unwrap();
        assert_eq!(connect_claude(exe, &config).unwrap(), Connected::Added);
        let missing = connect_claude(exe, &dir.join("no-such-folder/claude_desktop_config.json")).unwrap_err().to_string();
        assert!(missing.contains("does not seem to be installed"), "{missing}");
    }

    // MARK: connecting Codex

    #[test]
    fn connecting_codex_adds_the_table_and_keeps_everything_else() {
        let exe = Path::new("/Applications/My \"Apps\"/Folio.app/Contents/MacOS/Folio");
        let dir = temp_dir("codex");
        let config = dir.join("config.toml");

        assert_eq!(connect_codex(exe, &config).unwrap(), Connected::Added);
        let written: toml_edit::DocumentMut = std::fs::read_to_string(&config).unwrap().parse().unwrap();
        assert_eq!(written["mcp_servers"]["folio"]["command"].as_str(), Some(&*exe.to_string_lossy()));

        // Comments, other servers, other settings and an `env` on our entry survive.
        std::fs::write(
            &config,
            "# mine\nmodel = \"o3\"\n\n[mcp_servers.other]\ncommand = \"x\"\n\n[mcp_servers.folio]\ncommand = \"/old/Folio\"\nargs = [\"--mcp\"]\nenv = { A = \"1\" }\n",
        )
        .unwrap();
        assert_eq!(connect_codex(exe, &config).unwrap(), Connected::Updated);
        let text = std::fs::read_to_string(&config).unwrap();
        assert!(text.starts_with("# mine\nmodel = \"o3\"\n"), "{text}");
        let written: toml_edit::DocumentMut = text.parse().unwrap();
        assert_eq!(written["mcp_servers"]["other"]["command"].as_str(), Some("x"));
        let folio = &written["mcp_servers"]["folio"];
        assert_eq!(folio["command"].as_str(), Some(&*exe.to_string_lossy()));
        assert_eq!(folio["args"].as_array().unwrap().iter().map(|v| v.as_str()).collect::<Vec<_>>(), [Some("--mcp")]);
        assert_eq!(folio["env"]["A"].as_str(), Some("1"));

        // Doing it again changes nothing.
        assert_eq!(connect_codex(exe, &config).unwrap(), Connected::Unchanged);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), text);
        assert!(!config.with_extension("toml.tmp").exists());
    }

    #[test]
    fn connecting_codex_does_not_overwrite_a_config_it_cannot_read() {
        let exe = Path::new("/Applications/Folio.app/Contents/MacOS/Folio");
        let dir = temp_dir("codex-bad");
        let config = dir.join("config.toml");
        std::fs::write(&config, "[not toml").unwrap();
        let message = connect_codex(exe, &config).unwrap_err().to_string();
        assert!(message.contains("not valid TOML"), "{message}");
        assert_eq!(std::fs::read_to_string(&config).unwrap(), "[not toml");

        std::fs::write(&config, "mcp_servers = 1\n").unwrap();
        assert!(connect_codex(exe, &config).unwrap_err().to_string().contains("not a table"));

        let missing = connect_codex(exe, &dir.join("no-such-folder/config.toml")).unwrap_err().to_string();
        assert!(missing.contains("does not seem to be installed"), "{missing}");
        assert_eq!(Client::from_id(Client::Codex.id()), Some(Client::Codex));
        assert_eq!(Client::from_id("chatgpt"), None);
    }
}
