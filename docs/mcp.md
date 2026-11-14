# MCP

Folio is also an MCP server, built into the app, for Claude Desktop, Codex and other MCP clients. The client starts `Folio.app/Contents/MacOS/Folio --mcp`, which has no windows and speaks MCP over stdin and stdout. It uses `src/mcp.rs`, the same engine as the CLI. Nothing else needs installing, and the `folio` CLI is not involved.

## Allowing access

**MCP clients get in only once you allow it.** **Folio ▸ Allow MCP Clients** (or the box at the top of Connect to MCP Clients…) is off until you turn it on, and you can turn it off again at any time.

- The choice is kept in `<config>/mcp.json` (`allowed`).
- While it is off, a client that was set up still starts the server, but:
  - every tool answers that access is off;
  - nothing is read or written;
  - the app does not answer the server's questions about its windows.
- The server reads the choice at every call, so turning it on or off needs no restart of the client.
- In the app, both switches are `AppServer.allow`.

## Connecting a client

**Folio ▸ Connect to MCP Clients…** connects clients, none ahead of the others.

1. Pick the client: Claude Code, Claude Desktop, Codex, Cursor, or another MCP client.
2. Folio shows what to run or paste, with this app's path in it. Copy puts it on the pasteboard.

**Add for Me**, once MCP clients are allowed, writes the same entry into the client's config file for you:

- It works for Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) and Codex (`~/.codex/config.toml`, or `$CODEX_HOME/config.toml`).
- It keeps everything else in the file and says what it did.
- Restart the client afterwards.
- Do it again after moving the app: it updates the path.

Behind this window are functions in `src/mcp.rs` that the app calls through libfolio: `client_snippets` (what each client needs) and `connect_claude` / `connect_codex` (Add for Me). They are not MCP tools.

## Tools

Tools only take absolute paths to markdown files.

**Tools that work on files.** They need no running app.

| Tool | What it does |
|---|---|
| `render` | The plain text that annotations are anchored against. Read it before annotating. |
| `list_annotations` | A file's annotations with their replies, and whether each pending one still anchors. |
| `annotations_since` | What is new since the `cursor` of the last call: annotations, replies, resolutions. `exclude_author` is optional. |
| `annotate` | Adds annotations, all or nothing, checked against the text before anything is written. |
| `reply` | Replies to an annotation. |
| `verify` | Checks that every pending annotation still anchors in the text. |
| `set_list` | The names of the sets, or the files in one. |
| `set_add` | Adds files, and wiki folders with `folders`, to a set, creating it if needed. |
| `set_remove` | Removes files from a set. The files themselves are not touched. |
| `items` | The open `#investigate` / `#waiting` / `#replied` items of a set. |
| `refs` | The pages that link to a file. With `dead`, the links that cannot be followed. |
| `relink` | Repairs links whose branch is gone (`dry_run` to preview). |
| `link` | The `folio://` link to an annotation, a passage or the document. |
| `open` | Opens a file or a set in the app, starting it if needed. |

**Tools that ask the running app.** Without the app, they say that Folio is not running.

| Tool | What it does |
|---|---|
| `current_document` | The files open in Folio, the front one first. |
| `focused_annotation` | The annotation (and its thread) the reader has open: by clicking its card or its text, or by stepping to it. So you can say "answer this one". |
| `reveal` | Brings a file into view, opening it if needed, and focuses one of its annotations. |

## Adding a tool

- A tool lives in `src/mcp.rs`.
- A question to the app lives in `src/mcp.rs`, `AppServer.swift` and this page.
- `SelfTest+MCP.swift` runs the app's binary with `--mcp` over pipes, as Claude Desktop does.

## The app socket

The tools that ask the running app use a socket: `<config>/app.sock`, mode 0600, served by libfolio (`src/live.rs`) and answered on the main thread by `AppServer.swift`.

The link is one line of JSON each way:

| Request | Answer |
|---|---|
| `{"op": "state"}` | `{"ok": {"windows": [...]}}`. Per window: `front`, `file`, `sidecar`, `set`, `mode`, `pending`, `focused`. |
| `{"op": "reveal", "file": ..., "id": ...}` | `{"ok": {"opened": bool}}` |

A failure is `{"error": "..."}`. Change `AppServer.swift` and `src/mcp.rs` together.
