## Guiding Principles

Apply these principles during every step execution to keep changes focused and side-effect-free.

1. **Think Before Coding** — Before editing any file, fully understand the current state and the intended change. Read the relevant code first; never edit speculatively.
2. **Simplicity First** — Implement the simplest change that satisfies the step. Do not over-engineer, add abstractions, or introduce patterns beyond what the step requires.
3. **Surgical Changes** — Touch only the code the step calls for. Do not refactor nearby code, add unrelated improvements, update comments/docs you weren't asked to change, or "clean up while you're here."
4. **Goal-Driven Execution** — Every edit must trace back to the plan's stated goal. If a change isn't required by the current step, don't make it.

## Project Overview

Folio is a local markdown editor and annotation review tool for macOS. The app (`macos/`) is native Swift: the preview and the source editor are `NSTextView`s. `frontend/` is a small Vite page (mermaid and lowlight) that a hidden web view loads, where the native preview gets its diagrams and code colours; the Rust crate is the CLI and the engine (anchoring, accept, sets) the app links as a static library. Agents write annotations to a `.folio` sidecar file with the CLI; humans review them in the app. There is no browser or server mode.

**Core constraint:** The markdown source file is always clean. Annotations live exclusively in the `.folio` sidecar — never embedded in the `.md` file.

## Build

```bash
# Frontend
cd frontend && pnpm install && pnpm build

# Rust CLI
cargo build

# macOS app: needs the frontend build (the app reads frontend/dist) and a *release* libfolio.a (the app links it).
# A stale libfolio.a shows up only as a bare "linker command failed" from swift build.
cargo build --release && swift build --package-path macos
macos/scripts/bundle.sh   # -> macos/build/Folio.app
```

## Tests

```bash
# Rust unit tests (sidecar anchoring, strip_markdown)
cargo test

# macOS app: drives the real app against throwaway copies and the real CLI (needs a desktop session)
macos/.build/debug/Folio --self-test macos/selftest.md

# Everything: frontend build, cargo build/test, and on macOS the app build + self-test
# (--skip-macos to leave that part out)
./scripts/verify.sh
```

Run `./scripts/verify.sh` after UI changes to confirm them in the real app. Add a check to the self-test for new UI behaviour instead of writing throwaway scripts. The app opens in the native preview; the View menu switches to the native source editor. Both are text views, so there is no DOM to assert on: check the text view's state and look at the pictures.

Passing tests have not been enough here: source-mode typing "worked" while the editor was hidden, and a sidebar refresh bounced the page to the first file with every check green. For UI changes, assert what is visible, not just the DOM, and look at a picture of the result (the self-test saves window pictures with `FOLIO_SNAPSHOT=<base>`).

CI takes the pictures only for a pull request labeled `pictures` and shows them on the PR. When you open a PR for a change that touches what the app looks like, add the `pictures` label.

## Architecture

### Backend (`src/`)

- `main.rs` — CLI entry point (clap); the modules below live in the `folio` library (`lib.rs`), which the binary and the macOS app both use. `cargo build` does not touch the frontend.
- `ffi.rs` — C API over anchoring, accept, editor actions, sidecar paths and sets (strings in, JSON out); the macOS app links it as a static library (`macos/Sources/CFolio/include/folio.h`)
- `sidecar.rs` — Annotation/Sidecar types + anchoring algorithm
- `edit.rs` — the editor's actions on a sidecar (resolve, add comment, reply, edit comment, restore for undo), applied to what is on disk so an agent's concurrent writes survive; the app's `AnnotationStore` calls it through `folio_edit`
- `set.rs` — named multi-file sets (`~/.config/folio/sets/<name>.json`), git-root detection, per-root sidecar paths
- `commands/mod.rs` — `folio_path`: the sidecar is `<git root, else the file's folder>/.folio/<path relative to root>.folio` wherever the command runs (same rule as sets and the app, via `set::detect_root`)
- `commands/set.rs` — `folio set add / rm / list`
- `commands/open.rs` — `folio open <file>` / `--set <name>`: launches the macOS app
- `commands/accept.rs` — anchoring + reverse-order patch application
- `mcp.rs` — the MCP server (JSON-RPC over stdio) the app's binary becomes with `Folio --mcp`, for Claude desktop: file tools on the markdown and sidecar (the same code as the CLI), `current_document` / `focused_annotation` / `reveal` that ask the running app, `client_snippets` (Folio ▸ Connect to MCP Clients…, what each tool needs) and `connect_claude` / `connect_codex` (that window's Add for Me, edit Claude Desktop's or Codex's config)
- `live.rs` — the Unix socket (`<config>/app.sock`) between the MCP server and the running app; libfolio serves it and calls back into Swift (`AppServer.swift`)

### Frontend (`frontend/src/`)

Only the page a hidden web view loads (`diagram.html`); there is no editor in it.

- `diagram.ts` — `window.__folioMermaid` draws a diagram (the app photographs it) and `window.__folioHighlight` gives the highlight.js scopes of a block of code
- `mermaid-config.ts` — how mermaid is drawn, in Folio's colours

## macOS app (`macos/`)

A SwiftPM package: AppKit windows, no server. The preview (`PreviewView`) and the source editor are native; `frontend/dist` is served at `folio://app/` to the hidden diagram page, the only web view. `macos/README.md` has the run/build/test steps.

- `FolioDocument` is one `NSDocument` per file; `SetWindowController` is a window for a set (sidebar + editor; the sidebar switches files by loading them into the preview); both build on `EditorWindowController` (toolbar, the two modes, Find). A `Workspace` holds the window's files by id; `Document` does the file IO and polls for changes (polling, not FSEvents: atomic saves swap the inode).
- **Native preview** (`macos/Sources/Folio/Preview/`, read-only; hand edits go through the source): `PreviewBuilder` turns the markdown into an attributed string and `PreviewText` keeps the map between displayed and file characters (anchors and selections go through it to `Rust.anchor(raw: true)` / `Rust.renderedSelection`, like the source). `PreviewView` owns the `PreviewTextView` (TextKit 1, laid out at full height inside `EditorScrollView`), the text column (`column` 760 pt; paragraphs are indented by `side`, only tables and `folioWide` pictures may be wider), pictures and code colours. `DiagramPage` is the hidden web view (in a transparent off-screen window that must never show) that draws mermaid and highlights code. Rules learned the hard way:
  - Blocks painted behind the text (`PreviewTextView.drawBackground`: code, frontmatter box, quote bars, rules) are placed from the text column (`columnInset`), never from a block's bounding rect, which can reach outside the column.
  - Annotation marks are temporary attributes (`TextSurface.applyMarks`) drawn line by line and never over a line break: the background of a break runs to the edge of the line, outside the column.
  - Anything floating (the open card, the form, the Comment button) is kept inside `visibleDocumentRect` and the text column (`AnnotationController.floatingOrigin`), also with the text at the bottom of the window.
  - `PreviewText.text` is a reference: copy it before inserting suggestion previews.
- **Scrolling**: the preview and the source are not in a scroll view of their own, each is laid out at its full height (`layoutContent`) and `EditorScrollView` scrolls it together with the comments pane. Scroll positions are kept as a fraction, per file and across the source/preview toggle.
- **Annotation UI** (`macos/Sources/Folio/Annotations/`): the cards, the comments pane, the card that opens next to the text, the Comment button, the new-comment form, the toast and the shortcuts are native. `AnnotationStore` is one file's annotations and every action on them (through libfolio, with undo); `AnnotationController` is a window's glue (the surface reports in, cards and overlays out, keyboard); `AnnotationCardView` and friends are the views, laid out by hand (heights are measured, not Auto Layout). The cards live in `EditorScrollView`'s canvas beside the text, so an anchor's `top` is the card's `y`. Both modes use it through the `AnnotationSurface` protocol (`PreviewView` for the preview, `SourceEditorView` for the source). Undo: the document has no undo manager on purpose (see `FolioDocument`), so in the preview ⌘Z and Edit ▸ Undo go to the annotation actions (`AppDelegate.undoEdit`); in the source, typing and annotation actions share the text view's one history.
- **Recent files** are kept in `<config>/recents.json` beside the sets (`RecentFiles`; `FOLIO_CONFIG_DIR` moves it), not only in AppKit's list, which does not survive a rebuild of an ad-hoc signed app. File ▸ Open Recent and the welcome window read ours; Clear Menu and the welcome list's Clear All Recents empty it (`welcomeChecks` runs last in the self-test).
- **Source editor** (`macos/Sources/Folio/Source/`): `SourceEditorView` is a TextKit 1 `NSTextView` laid out at full height inside `EditorScrollView` (it does not scroll itself), with `MarkdownHighlighter` (line-based), `LineNumberView` and annotation marks drawn as temporary attributes. It writes the file itself (debounced, `Document.writeFile`), reloads on outside changes unless there are unsaved edits (the save then asks whether to keep the typing or the file), and anchors with `Rust.anchor(raw: true)` against its own text. The mode (preview/source) and the comments pane are the window's state (`EditorWindowController.mode`, `commentsOn`).
- **Claude (MCP)**: `main.swift` turns `--mcp` into the MCP server before AppKit starts (nothing may print on stdout but the protocol). `AppServer` answers the server's questions about windows and the focused annotation on the main thread; a tool lives in `src/mcp.rs`, a question to the app in both `mcp.rs` and `AppServer.swift` (and `macos/README.md`). `SelfTest+MCP.swift` runs the app's binary with `--mcp` over pipes.
- Anchoring and accept run in Rust through `Rust.swift` → `ffi.rs`; do not reimplement them in Swift.
- Chrome follows the system (accent color, system toolbar items, Finder-style sidebar selection); Folio's own purple is for content (annotations, selection, avatars).
- A set window has a full-height sidebar like Finder or Preview: `.fullSizeContentView`, an `NSSplitViewController`, and a toolbar installed *after* the split view exists, with `.toggleSidebar` and an `NSTrackingSeparatorToolbarItem`. Do not give that window an intermediate `contentView` first: the replacement ends up above the title bar and hides the traffic lights and toolbar, which no check notices (the self-test asserts the order).
- Toolbar glyphs are drawn at a fixed size whatever symbol configuration you give them; choose a symbol, not a size.
- The self-test (`macos/Sources/Folio/SelfTest/`: `SelfTest.swift` has the run order and helpers, the `SelfTest+<area>.swift` extensions the checks) is the regression suite for the app; add a check there for new app behaviour. Pictures for judging looks come from `FOLIO_SNAPSHOT`; the README screenshot from `scripts/readme-screenshot.sh`.
- The preview is read-only; hand edits go through the source.

## Annotation Model

Sidecar: `{ version: 1, annotations: Annotation[] }` stored in `<root>/.folio/<path relative to root>.folio` (root = the file's git root, else its folder).

| Kind | Inline decoration | Gutter card actions |
|---|---|---|
| `replace` | Red strikethrough + green replacement preview | Accept / Reject |
| `delete` | Red strikethrough + red bottom border | Accept / Reject |
| `insert` | Green inline preview widget + green bottom border | Accept / Reject |
| `highlight` | Purple background | Accept / Reject |
| `comment` | Purple background (same as highlight) | Dismiss |

Each annotation optionally carries a `replies: ThreadReply[]` array (empty = omitted from JSON). Replies have `id`, `author`, `source`, `body`, `created`. The local user posts replies with `source: local`, `author: me`.

### Anchoring

The preview and the source anchor with `Rust.anchor(raw: true)` against the markdown. The anchoring text is flat: block boundaries are invisible, with **no separator** between blocks, so `context_before` is plain rendered text (not markdown syntax) and never has a newline for a block break. Annotations written by agents must use rendered text too.

## Annotation UI patterns

How the cards behave, in both modes (native):

- **Pane layout**: the cards sit beside the text and scroll with it: the window's scroll view scrolls the text and the pane together (see "Scrolling" above). The pane takes 304 points (280 plus a 24 margin) of the width when open, and the text reflows.
- **Card positioning**: a card sits at its anchor's top minus 4, in document order, and is pushed down by 6 points when it would overlap the one above (real heights, measured). Not found in the document: parked after the text, dimmed, "Not found in document".
- **Focus indicator**: clicking annotated text (or ⌃J/⌃K) focuses an annotation; its card gets the accent border and its reply field. Clicking plain text clears it.
- **Open card**: when the comments pane is closed, the focused annotation's full card is shown next to the text (flips above the anchor near the bottom of the visible area). Only the focused annotation is shown; Esc or clicking elsewhere dismisses it, and opening the pane puts it back in the pane. It is the same card view as in the pane, so a half-typed reply survives.
- **Event handling**: the Comment button does not take the keyboard, so the selection in the text view stays selected.

