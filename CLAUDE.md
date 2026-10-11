## Guiding Principles

Apply these principles during every step execution to keep changes focused and side-effect-free.

1. **Think Before Coding** — Before editing any file, fully understand the current state and the intended change. Read the relevant code first; never edit speculatively.
2. **Simplicity First** — Implement the simplest change that satisfies the step. Do not over-engineer, add abstractions, or introduce patterns beyond what the step requires.
3. **Surgical Changes** — Touch only the code the step calls for. Do not refactor nearby code, add unrelated improvements, update comments/docs you weren't asked to change, or "clean up while you're here."
4. **Goal-Driven Execution** — Every edit must trace back to the plan's stated goal. If a change isn't required by the current step, don't make it.

## Project Overview

Folio is a local markdown editor and annotation review tool. A Rust/Axum binary serves a Vite + Tiptap 3 SPA embedded via rust-embed. Agents write annotations to a `.folio` sidecar file; humans review them in the browser, in the native macOS app (`macos/`, a Swift shell around the same editor), or via CLI.

**Core constraint:** The markdown source file is always clean. Annotations live exclusively in the `.folio` sidecar — never embedded in the `.md` file.

## Build

```bash
# Frontend
cd frontend && pnpm install && pnpm build

# Rust binary (skip frontend rebuild)
FOLIO_SKIP_FRONTEND_BUILD=1 cargo build

# After frontend-only changes (index.html, *.ts, *.css):
# MUST run pnpm build first — rust-embed embeds from dist/, not the source files.
# Skipping pnpm build causes the binary to re-embed stale dist/ output.
cd frontend && pnpm build && cd .. && touch src/main.rs && FOLIO_SKIP_FRONTEND_BUILD=1 cargo build

# Full build (build.rs runs pnpm install + build automatically)
cargo build

# macOS app: needs the frontend build and a *release* libfolio.a (the app links it).
# A stale libfolio.a shows up only as a bare "linker command failed" from swift build.
cargo build --release && swift build --package-path macos
macos/scripts/bundle.sh   # -> macos/build/Folio.app
```

## Tests

```bash
# Rust unit tests (sidecar anchoring, strip_markdown)
cargo test

# Frontend unit tests (findAnchor)
cd frontend && pnpm test

# Browser e2e (Playwright; starts its own servers against temp copies of e2e/fixture.md:
# :7391 single file, :7392 a two-file set for multi-file.spec.ts)
cd frontend && pnpm e2e

# macOS app: drives the real app against throwaway copies and the real CLI (needs a desktop session)
macos/.build/debug/Folio --self-test macos/selftest.md

# Everything: frontend build, cargo build/test, unit tests, e2e, and on macOS the app build + self-test
# (--skip-e2e / --skip-macos to leave a part out)
./scripts/verify.sh
```

Run `./scripts/verify.sh` after UI changes to confirm them in a real browser. Add a spec in `frontend/e2e/` for new UI behaviour instead of writing throwaway scripts. The browser boots in source (CM6) mode (the macOS app opens in preview); click `#view-toggle-btn` for preview. Floater/overlay ids exist in both modes, so scope selectors to `#editor-wrapper` or `#raw-editor-wrapper`.

Passing tests have not been enough here: source-mode typing "worked" while the editor was hidden, and a sidebar refresh bounced the page to the first file with every check green. For UI changes, assert what is visible, not just the DOM, and look at a picture of the result (the self-test saves window pictures with `FOLIO_SNAPSHOT=<base>`).

## Architecture

### Backend (`src/`)

- `main.rs` — CLI entry point (clap); the modules below live in the `folio` library (`lib.rs`), which the binary and the macOS app both use
- `ffi.rs` — C API over anchoring, accept, sidecar paths and sets (strings in, JSON out); the macOS app links it as a static library (`macos/Sources/CFolio/include/folio.h`)
- `sidecar.rs` — Annotation/Sidecar types + anchoring algorithm
- `server.rs` — Axum router, rust-embed asset serving, AppState
- `watcher.rs` — notify → tokio broadcast → WebSocket events
- `set.rs` — named multi-file sets (`~/.config/folio/sets/<name>.json`), git-root detection, per-root sidecar paths
- `commands/mod.rs` — `folio_path` / `lock_path`: the sidecar is `<git root, else the file's folder>/.folio/<path relative to root>.folio` wherever the command runs (same rule as sets and the app, via `set::detect_root`)
- `commands/set.rs` — `folio set add / rm / list`
- `commands/open.rs` — `folio open <file>` / `--set <name>`: launches the macOS app
- `commands/serve.rs` — lock file, port binding, graceful shutdown; serves one file or a set (`--set`)
- `commands/accept.rs` — anchoring + reverse-order patch application

### Frontend (`frontend/src/`)

- `main.ts` — boot: fetches file + sidecar, wires WebSocket events
- `editor.ts` — Tiptap 3 editor (StarterKit + @tiptap/markdown)
- `annotations.ts` — ProseMirror plugin: inline decorations, scrollable gutter cards, floating comment adder
- `diagrams.ts` — Tiptap NodeView extension: renders `mermaid` and `plantuml` code blocks as diagrams
- `api.ts` — fetch wrappers + `Annotation`/`Sidecar` TypeScript types; file-scoped calls append `?file=<id>` from the page URL
- `file-menu.ts` — the title pill becomes a menu (floating card, annotation-card style) of the set's files with pending badges; only when the server serves more than one file
- File switching happens in `main.ts` (`switchFile`): in place, no reload. The preview editor is destroyed and recreated (`destroyEditor`), the CM6 state is replaced (`resetRawEditor`), and annotation state is reset (`resetAnnotationState`, `resetRawAnnotationState`) so undo history and anchors never leak between files. The URL is kept in sync with `history.pushState` / `popstate`.
- `websocket.ts` — WebSocket client with typed event subscriptions
- `bridge.ts` — detects the macOS app's script message handler; `api.ts` and `websocket.ts` use it instead of `fetch`/WebSocket when present (events arrive through `window.__folioEmit`)

## macOS app (`macos/`)

A SwiftPM package: AppKit windows hosting `frontend/dist` in a `WKWebView` at `folio://app/`, no server. `macos/README.md` has the run/build/test steps, `macos/BRIDGE.md` the page-to-Swift contract.

- `FolioDocument` is one `NSDocument` per file; `SetWindowController` is a window for a set (sidebar + editor; the sidebar switches files by calling `window.__folioSwitchFile(id)` in the page); both build on `EditorWindowController` (web view, toolbar, navigation). `Bridge` answers the page's ops per file id through a `Workspace`; `Document` does the file IO and polls for changes (polling, not FSEvents: atomic saves swap the inode).
- Anchoring and accept run in Rust through `Rust.swift` → `ffi.rs`; do not reimplement them in Swift.
- **A bridge op lives in three places**: `Bridge.swift`, the mock in `frontend/e2e/fixtures.ts` (the Playwright "bridge" project runs every spec through it), and `macos/BRIDGE.md`. Change all three together.
- **Native-only styling goes under `html.native-chrome`** (the scheme handler adds the class to `index.html`), so the browser look is unchanged. Chrome follows the system (accent color, system toolbar items, Finder-style sidebar selection); Folio's own purple is for content (annotations, selection, avatars).
- A set window has a full-height sidebar like Finder or Preview: `.fullSizeContentView`, an `NSSplitViewController`, and a toolbar installed *after* the split view exists, with `.toggleSidebar` and an `NSTrackingSeparatorToolbarItem`. Do not give that window an intermediate `contentView` first: the replacement ends up above the title bar and hides the traffic lights and toolbar, which no check notices (the self-test asserts the order).
- Toolbar glyphs are drawn at a fixed size whatever symbol configuration you give them; choose a symbol, not a size.
- The self-test (`SelfTest.swift`) is the regression suite for the app; add a check there for new app behaviour. Pictures for judging looks come from `FOLIO_SNAPSHOT`; the README screenshot from `scripts/readme-screenshot.sh`.
- Raw HTML in a markdown file makes the WYSIWYG preview read-only (it cannot round-trip the file). The README keeps its HTML to the centered header for that reason.

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

`findAnchor` concatenates text nodes with **no separator** (block boundaries are invisible). When creating annotations from user selections, always use `doc.textBetween(from, to, '')` with an empty separator to match this flat model — never `'\n'`.

`context_before` should be plain rendered text (not markdown syntax). Annotations written by agents must use rendered text too.

## Frontend UI Patterns

- **Gutter layout**: `#annotation-gutter` is a flex sibling of `#editor-tiptap` inside `#editor-wrapper` (the scroll container). Both scroll together.
- **Card positioning**: `position: absolute` within the gutter. `data-anchor-top` stores the natural anchor Y; `repositionCards()` re-stacks using `card.offsetHeight` (real heights, not a constant). Call after every build and after comment expand/collapse.
- **Focus indicator**: clicking annotated text (or Ctrl+J/K) sets `focusedAnnotationId`; the matching gutter card gets `ann-card-focused` class.
- **Annotation overlay**: when the comment pane is closed (`#app` lacks `gutter-open`), the focused annotation's full card is shown in `#annotation-overlay` next to the text (flips above the anchor near the bottom). Only the focused annotation is shown; Esc or clicking elsewhere dismisses it, and opening the pane hides it. The overlay is rebuilt only when the annotation's JSON changes so a focused reply box survives. Raw mode has its own copy in `raw-annotations.ts`.
- **Event handling**: use `mousedown + e.preventDefault()` on card buttons and the floating comment adder to preserve editor selection.
- **CSS `hidden` + `display: flex`**: explicit `display` values on elements override the UA stylesheet's `[hidden] { display: none }`. Always add `selector[hidden] { display: none }` for any element that uses both.

