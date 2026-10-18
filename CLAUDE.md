## Guiding Principles

Apply these principles during every step execution to keep changes focused and side-effect-free.

1. **Think Before Coding** — Before editing any file, fully understand the current state and the intended change. Read the relevant code first; never edit speculatively.
2. **Simplicity First** — Implement the simplest change that satisfies the step. Do not over-engineer, add abstractions, or introduce patterns beyond what the step requires.
3. **Surgical Changes** — Touch only the code the step calls for. Do not refactor nearby code, add unrelated improvements, update comments/docs you weren't asked to change, or "clean up while you're here."
4. **Goal-Driven Execution** — Every edit must trace back to the plan's stated goal. If a change isn't required by the current step, don't make it.

## Project Overview

Folio is a local markdown editor and annotation review tool for macOS. The app (`macos/`) is a Swift shell around a Vite + Tiptap 3 SPA; the Rust crate is the CLI and the engine (anchoring, accept, sets) the app links as a static library. Agents write annotations to a `.folio` sidecar file with the CLI; humans review them in the app. There is no browser or server mode.

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

# Frontend unit tests (findAnchor)
cd frontend && pnpm test

# macOS app: drives the real app against throwaway copies and the real CLI (needs a desktop session)
macos/.build/debug/Folio --self-test macos/selftest.md

# Everything: frontend build, cargo build/test, unit tests, and on macOS the app build + self-test
# (--skip-macos to leave that part out)
./scripts/verify.sh
```

Run `./scripts/verify.sh` after UI changes to confirm them in the real app. Add a check to the self-test for new UI behaviour instead of writing throwaway scripts. The app opens in preview; the View menu switches to the source (CM6) editor. Floater/overlay ids exist in both modes, so scope selectors to `#editor-wrapper` or `#raw-editor-wrapper`.

Passing tests have not been enough here: source-mode typing "worked" while the editor was hidden, and a sidebar refresh bounced the page to the first file with every check green. For UI changes, assert what is visible, not just the DOM, and look at a picture of the result (the self-test saves window pictures with `FOLIO_SNAPSHOT=<base>`).

## Architecture

### Backend (`src/`)

- `main.rs` — CLI entry point (clap); the modules below live in the `folio` library (`lib.rs`), which the binary and the macOS app both use. `cargo build` does not touch the frontend.
- `ffi.rs` — C API over anchoring, accept, sidecar paths and sets (strings in, JSON out); the macOS app links it as a static library (`macos/Sources/CFolio/include/folio.h`)
- `sidecar.rs` — Annotation/Sidecar types + anchoring algorithm
- `set.rs` — named multi-file sets (`~/.config/folio/sets/<name>.json`), git-root detection, per-root sidecar paths
- `commands/mod.rs` — `folio_path`: the sidecar is `<git root, else the file's folder>/.folio/<path relative to root>.folio` wherever the command runs (same rule as sets and the app, via `set::detect_root`)
- `commands/set.rs` — `folio set add / rm / list`
- `commands/open.rs` — `folio open <file>` / `--set <name>`: launches the macOS app
- `commands/accept.rs` — anchoring + reverse-order patch application

### Frontend (`frontend/src/`)

- `main.ts` — boot: fetches file + sidecar through the bridge, wires the file-changed events
- `editor.ts` — Tiptap 3 editor (StarterKit + @tiptap/markdown)
- `annotations.ts` — ProseMirror plugin: inline decorations, scrollable gutter cards, floating comment adder
- `diagrams.ts` — Tiptap NodeView extension: renders `mermaid` and `plantuml` code blocks as diagrams
- `api.ts` — bridge-call wrappers + `Annotation`/`Sidecar` TypeScript types; file-scoped calls carry the active file id (from `?file=<id>` on the page URL, then `setActiveFile`)
- File switching happens in `main.ts` (`switchFile`), called by the app's sidebar through `window.__folioSwitchFile`: in place, no reload. The preview editor is destroyed and recreated (`destroyEditor`), the CM6 state is replaced (`resetRawEditor`), and annotation state is reset (`resetAnnotationState`, `resetRawAnnotationState`) so undo history and anchors never leak between files.
- `layout.ts` — the page's half of native scrolling: reports its height (`layout`) and what must come into view (`reveal`), and redirects `scrollIntoView` to the app
- `websocket.ts` — typed event subscriptions (`md:changed`, `folio:changed`); events arrive through `window.__folioEmit`, called by Swift's file watchers (the name predates the removal of the server)
- `bridge.ts` — the macOS app's script message handler; `api.ts` sends every backend call through it

## macOS app (`macos/`)

A SwiftPM package: AppKit windows hosting `frontend/dist` in a `WKWebView` at `folio://app/`, no server. `macos/README.md` has the run/build/test steps, `macos/BRIDGE.md` the page-to-Swift contract.

- `FolioDocument` is one `NSDocument` per file; `SetWindowController` is a window for a set (sidebar + editor; the sidebar switches files by calling `window.__folioSwitchFile(id)` in the page); both build on `EditorWindowController` (web view, toolbar, navigation). `Bridge` answers the page's ops per file id through a `Workspace`; `Document` does the file IO and polls for changes (polling, not FSEvents: atomic saves swap the inode).
- **Scrolling**: the page lays itself out at its full height and `EditorScrollView` (a `NSScrollView` around the web view, which is exactly as tall as the page) scrolls it. Do not make a box in the page scroll (`overflow: auto`) or rely on the page's own `scrollTop`, `scrollIntoView` (redirected by `layout.ts`) or viewport units: the app would not see them. Nothing may widen the page either: the panes are `min-width: 0` with `overflow-x: clip`, and a wide table scrolls inside its own `.tableWrapper`, otherwise it pushes the comments pane off screen. Scroll positions are kept natively as a fraction, per file and across the source/preview toggle. Details in `macos/BRIDGE.md`.
- Anchoring and accept run in Rust through `Rust.swift` → `ffi.rs`; do not reimplement them in Swift.
- **A bridge op lives in two places**: `Bridge.swift` and `macos/BRIDGE.md`. Change both together.
- **App-chrome styling goes under `html.native-chrome`** (the scheme handler adds the class to `index.html`). Chrome follows the system (accent color, system toolbar items, Finder-style sidebar selection); Folio's own purple is for content (annotations, selection, avatars).
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

- **Gutter layout**: `#annotation-gutter` is a flex sibling of `#editor-tiptap` inside `#editor-wrapper`. Both scroll together, because nothing in the page scrolls: the window's scroll view scrolls the whole page (see "Scrolling" below), so `scrollTop` on the wrappers is always 0.
- **Card positioning**: `position: absolute` within the gutter. `data-anchor-top` stores the natural anchor Y; `repositionCards()` re-stacks using `card.offsetHeight` (real heights, not a constant). Call after every build and after comment expand/collapse.
- **Focus indicator**: clicking annotated text (or Ctrl+J/K) sets `focusedAnnotationId`; the matching gutter card gets `ann-card-focused` class.
- **Annotation overlay**: when the comment pane is closed (`#app` lacks `gutter-open`), the focused annotation's full card is shown in `#annotation-overlay` next to the text (flips above the anchor near the bottom). Only the focused annotation is shown; Esc or clicking elsewhere dismisses it, and opening the pane hides it. The overlay is rebuilt only when the annotation's JSON changes so a focused reply box survives. Raw mode has its own copy in `raw-annotations.ts`.
- **Event handling**: use `mousedown + e.preventDefault()` on card buttons and the floating comment adder to preserve editor selection.
- **CSS `hidden` + `display: flex`**: explicit `display` values on elements override the UA stylesheet's `[hidden] { display: none }`. Always add `selector[hidden] { display: none }` for any element that uses both.

