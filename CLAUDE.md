## Guiding Principles

Apply these principles during every step execution to keep changes focused and side-effect-free.

1. **Think Before Coding** — Before editing any file, fully understand the current state and the intended change. Read the relevant code first; never edit speculatively.
2. **Simplicity First** — Implement the simplest change that satisfies the step. Do not over-engineer, add abstractions, or introduce patterns beyond what the step requires.
3. **Surgical Changes** — Touch only the code the step calls for. Do not refactor nearby code, add unrelated improvements, update comments/docs you weren't asked to change, or "clean up while you're here."
4. **Goal-Driven Execution** — Every edit must trace back to the plan's stated goal. If a change isn't required by the current step, don't make it.

## Project Overview

Folio is a local markdown editor and annotation review tool. A Rust/Axum binary serves a Vite + Tiptap 3 SPA embedded via rust-embed. Agents write annotations to a `.folio` sidecar file; humans review them in the browser or via CLI.

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
```

## Tests

```bash
# Rust unit tests (sidecar anchoring, strip_markdown)
cargo test

# Frontend unit tests (findAnchor)
cd frontend && pnpm test

# Browser e2e (Playwright; starts its own server on :7391 against a temp copy of e2e/fixture.md)
cd frontend && pnpm e2e

# Everything: frontend build, cargo build/test, unit tests, e2e
./scripts/verify.sh
```

Run `./scripts/verify.sh` after UI changes to confirm them in a real browser. Add a spec in `frontend/e2e/` for new UI behaviour instead of writing throwaway scripts. The app boots in source (CM6) mode; click `#view-toggle-btn` for preview. Floater/overlay ids exist in both modes, so scope selectors to `#editor-wrapper` or `#raw-editor-wrapper`.

## Architecture

### Backend (`src/`)

- `main.rs` — CLI entry point (clap)
- `sidecar.rs` — Annotation/Sidecar types + anchoring algorithm
- `server.rs` — Axum router, rust-embed asset serving, AppState
- `watcher.rs` — notify → tokio broadcast → WebSocket events
- `commands/serve.rs` — lock file, port binding, graceful shutdown
- `commands/accept.rs` — anchoring + reverse-order patch application

### Frontend (`frontend/src/`)

- `main.ts` — boot: fetches file + sidecar, wires WebSocket events
- `editor.ts` — Tiptap 3 editor (StarterKit + @tiptap/markdown)
- `annotations.ts` — ProseMirror plugin: inline decorations, scrollable gutter cards, floating comment adder
- `diagrams.ts` — Tiptap NodeView extension: renders `mermaid` and `plantuml` code blocks as diagrams
- `api.ts` — fetch wrappers + `Annotation`/`Sidecar` TypeScript types
- `websocket.ts` — WebSocket client with typed event subscriptions

## Annotation Model

Sidecar: `{ version: 1, annotations: Annotation[] }` stored in `<file>.folio`.

| Kind | Inline decoration | Gutter card actions |
|---|---|---|
| `replace` | Red strikethrough + green replacement preview | Accept / Reject |
| `delete` | Red strikethrough + red bottom border | Accept / Reject |
| `insert` | Green inline preview widget + green bottom border | Accept / Reject |
| `highlight` | Amber background | Accept / Reject |
| `comment` | Yellow background + yellow bottom border | Dismiss |

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

