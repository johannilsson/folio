# Architecture overview

Folio is a local markdown editor and annotation review tool for macOS. The app (`macos/`) is native Swift: the preview and the source editor are `NSTextView`s. `frontend/` is a small Vite page (mermaid and lowlight) that a hidden web view loads, where the native preview gets its diagrams and code colours. The Rust crate is the CLI and the engine (anchoring, accept, sets) that the app links as a static library. Agents write annotations to a `.folio` sidecar file with the CLI; humans review them in the app. There is no browser or server mode ([decisions](../decisions.md#no-browser-or-server-mode)).

**Core constraint:** the markdown source file is always clean. Annotations live only in the `.folio` sidecar ([format](../reference/sidecar-format.md)), never in the `.md` file.

The app's side is on its own pages: [the macOS app](macos-app.md), [where Swift code goes](app-layers.md), [the preview](preview.md), [the annotation UI](annotation-ui.md).

## Rust (`src/`)

`main.rs` is the CLI entry point (clap). The modules below live in the `folio` library (`lib.rs`), which the binary and the macOS app both use. `cargo build` does not touch the frontend.

### The engine

`sidecar.rs`, `edit.rs`, `accept.rs`, `changes.rs` and `location.rs` use only each other: no CLI, MCP, sets, config folder or launching processes, so the engine could serve another app (a mobile one, say). The build does not enforce this; keep it that way by convention.

- `sidecar.rs`: the Annotation and Sidecar types and the [anchoring](../reference/sidecar-format.md#anchoring) algorithm.
- `edit.rs`: the editor's actions on a sidecar (resolve, add comment, reply, edit comment, restore for undo). They are applied to what is on disk so an agent's concurrent writes survive. The app's `AnnotationStore` calls it through `folio_edit`.
- `accept.rs`: accepting: anchoring, reverse-order patch application, marking resolved (`folio accept` and `folio_accept`).
- `changes.rs`: what changed since a time (new annotations, replies, resolutions; optional `exclude_author`), from the timestamps the sidecar holds (`folio changes` and the MCP tool `annotations_since`).
- `location.rs`:
  - `folio_path`: the sidecar is `<git root, else the file's folder>/.folio/<path relative to root>.folio`, wherever the command runs (`detect_root`, `folio_path_in`). The CLI, sets, MCP and the app use the same rule.
  - `repo_identity`: the repo (origin's last path segment, else the main checkout's folder) and branch of a root, read from `.git` without running `git`. It names a worktree by its repo and branch, never by its folder.

### The desktop around it

- `ffi.rs`: the C API over anchoring, accept, editor actions, sidecar paths and sets (strings in, JSON out). The macOS app links it as a static library (`macos/Sources/CFolio/include/folio.h`).
- `set.rs`: named multi-file [sets](../guides/sets.md) (`~/.config/folio/sets/<name>.json`), explicit roots, and how a set file is shown.
  - The open-item tags a set lists, each with a label and a colour (`tags`, seeded with `wiki::default_tags` for a new set; `folio set tags`).
  - A set can also hold folders (the [wiki](../features/wiki-mode.md)), whose markdown files are listed again each time the set is loaded. A set with folders is version 2.
- `wiki.rs` (desktop side, not the engine):
  - open items: the task items tagged `#investigate`, `#waiting` or `#replied` (with their address, `folio://` link and nested answer), and ticking one;
  - the `folio://` links in a page (`references`) and whether one points at a file (`FolioLink::points_to`);
  - `resolve`, `dead_reason`, `moved_to`: why a link does not work among a set's files.

  `folio items`, `folio refs` (`--dead`), `folio relink` and the C API (`folio_open_items`, `folio_tick_item`) use it.
- `commands/`: the CLI subcommands, thin over the engine.
  - `set.rs`: `folio set add / rm / list` (`--folder` for a folder).
  - `link.rs`: `folio link`, as a `folio://` link naming repo, branch and path. It links an annotation, a passage (with `--passage`) or, with neither, the document.
  - `items.rs`: `folio items`.
  - `refs.rs`: `folio refs` and `folio relink`: the pages of a set that link to a file, the links that no longer work, and repairing a gone branch.
  - `open.rs`: `folio open <file>` / `--set <name>`, which launches the macOS app.
- `mcp.rs`: the MCP server (JSON-RPC over stdio) that the app's binary becomes with `Folio --mcp`. See [MCP](../mcp.md).
- `live.rs`: the Unix socket (`<config>/app.sock`) between the MCP server and the running app. libfolio serves it and calls back into Swift (`AppServer.swift`). See [the app socket](../mcp.md#the-app-socket).

## Frontend (`frontend/src/`)

Only the page a hidden web view loads (`diagram.html`). There is no editor in it.

- `diagram.ts`: `window.__folioMermaid` draws a diagram (the app photographs it), and `window.__folioHighlight` gives the highlight.js scopes of a block of code.
- `mermaid-config.ts`: how mermaid is drawn, in Folio's colours (`tokens.ts`, generated).

## Design tokens (`design/tokens.json`)

Folio's own colours (the text background, cards, avatars, diagrams) in the W3C design tokens format, which Figma and Claude Design can import. `node scripts/tokens.mjs` generates `macos/Sources/FolioKit/Tokens.swift` and `frontend/src/tokens.ts` from it.

- Edit the JSON, never the generated files. `verify.sh` fails when they are out of date.
- System colours are listed under `system` as samples for design tools only: the app uses them by name.
