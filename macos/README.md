# Folio for macOS

A native markdown editor and review tool: AppKit windows (one per markdown file, via `NSDocument`)
whose preview and source editor are `NSTextView`s. `frontend/dist` holds one page, which a hidden
`WKWebView` loads at `folio://app/` to draw mermaid diagrams and colour code.
The Rust core (anchoring, accept) is linked as `libfolio.a`.

## Run

```bash
(cd frontend && pnpm build)   # the bundle the app serves
cargo build --release         # libfolio.a
swift run --package-path macos Folio notes.md
```

## Build the .app

```bash
macos/scripts/bundle.sh        # -> macos/build/Folio.app (ad-hoc signed)
open macos/build/Folio.app
folio open notes.md            # from the CLI; FOLIO_APP=<path to .app> for an uninstalled build
```

`FOLIO_SIGN_IDENTITY` selects a signing identity other than ad hoc.

## PlantUML

Nothing is bundled to draw a `plantuml` block: without a setting it stays a code block. Choose one:

```bash
# A local PlantUML (brew install plantuml): the diagram stays on this Mac.
# Run as `<command> -pipe -tpng`; Homebrew's folders are on its PATH.
defaults write dev.folio.Folio PlantUMLCommand plantuml          # or: "java -jar /path/plantuml.jar"

# A server, which is sent the diagram's text.
defaults write dev.folio.Folio PlantUMLServer https://plantuml.example.com/plantuml
```

(or `-PlantUMLCommand …` / `-PlantUMLServer …` on the command line). The command wins when both are set;
`defaults delete dev.folio.Folio <key>` turns one off.

## Sets

A set is a named list of markdown files from any folders, kept in `~/.config/folio/sets`
and shared with `folio set add/rm/list`. In the app it opens in a window with a sidebar of
its files (grouped by repo, with a badge for unresolved annotations) beside the editor.

- **File > Open Set** lists the sets; **New Set…** asks for a name and the files to start with.
- **Add Files to Set…**, **Remove from Set** and **Delete Set…** (File menu; the + under the
  sidebar adds, a file's context menu removes) change the list. Only the list changes; files and their
  annotations are never deleted. A set keeps at least one file.
- Changes made with `folio set` in a terminal appear in an open window within a second.
- `folio open --set <name>` opens a set from the CLI (it sends `folio://set/<name>` to the app).

## MCP

Folio is also an MCP server, built into the app, for Claude Desktop, Codex and other MCP clients: the tool starts
`Folio.app/Contents/MacOS/Folio --mcp`, which has no windows and speaks MCP over stdin and stdout
(`src/mcp.rs`, the same engine as the CLI). Nothing else needs installing, and the `folio` CLI is not
involved.

**Folio ▸ Connect to MCP Clients…** connects tools to it, none ahead of the others: pick the tool (Claude
Code, Claude Desktop, Codex, Cursor and other MCP clients) and it shows what to run or paste, with this
app's path in it; Copy puts it on the pasteboard. For Claude Desktop
(`~/Library/Application Support/Claude/claude_desktop_config.json`) and Codex (`~/.codex/config.toml`, or
`$CODEX_HOME/config.toml`) **Add for Me** writes the same entry into the file named beside it, keeping
everything else in it, and says what it did; restart the tool afterwards. Do it again after moving the
app: it updates the path.

The tools: `render`, `list_annotations`, `annotate` (all or nothing, checked against the text before
anything is written), `reply`, `verify`, `set_list`, `set_add`, `set_remove` and `open` work on files
and need no running app. `current_document`, `focused_annotation` and `reveal` ask the running app,
over a socket (`<config>/app.sock`, mode 0600, `AppServer.swift`): `focused_annotation` is the
annotation (and its thread) the reader has open, by clicking its card or text or stepping to it, so
you can say "answer this one". Without the app they say that Folio is not running. Tools only take absolute paths to markdown files.

The link is one line of JSON each way: `{"op": "state"}` is answered by `{"ok": {"windows": [...]}}`
(per window: `front`, `file`, `sidecar`, `set`, `mode`, `pending`, `focused`), and
`{"op": "reveal", "file": ..., "id": ...}` by `{"ok": {"opened": bool}}`; a failure is `{"error": "..."}`.
Change `AppServer.swift` and `src/mcp.rs` together.

## Test

```bash
cargo build                                                  # the `folio` CLI the test drives
swift build --package-path macos
swift test --package-path macos                              # FolioKit's unit tests, no windows
macos/.build/debug/Folio --self-test macos/selftest.md       # exits 0 when every check passes
```

The self-test works on throwaway copies: it types in the source, undoes, copies and pastes through the
Edit menu, annotates with the CLI, accepts in both modes (the source editor
included: typing, formatting, marks, undo, Find, drag-scroll), replaces the file from
outside, and opens a second window. It also starts the app's binary with `--mcp` and talks to it over
its pipes, as Claude desktop does (`SelfTest+MCP.swift`). `FOLIO_SNAPSHOT=<base>` saves `<base>-cards.png`,
`-menu.png`, `-floater.png` and `-form.png`: pictures of the whole window with annotation
cards, the card menu, the Comment button and the comment form.
`FOLIO_CLI` points it at a different `folio` binary.

## README screenshot

`docs/screenshot.png` shows the `natural-wine` sample set (`demo-set/setup.sh` registers it).
`scripts/readme-screenshot.sh` retakes it from a clean copy of the set. The app photographs
itself: `Folio --set <name> --screenshot <png> [--appearance light|dark]`.
The README uses a plain markdown image, not a light/dark `<picture>`: raw HTML makes Folio's own
preview read-only, and the README should open editable.
