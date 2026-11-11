# Folio Code Review — Optimizations & Improvements

Full review of the Rust backend (`src/`) and the frontend (`frontend/src/`), 2026-07-06.
Findings are ordered by severity within each section, with file/line references.

---

## 1. Correctness bugs

### 1.1 `decodeHtmlEntities` double-decodes (`frontend/src/editor.ts:13-21`)

The replacement chain decodes `&amp;` **first**:

```ts
.replace(/&amp;/g, '&')
.replace(/&lt;/g, '<')
...
```

A document containing the literal text `&amp;lt;` (i.e. the author wants the reader to
see `&lt;`) becomes `&lt;` after the first replace, and then `<` after the second — a
double decode that silently corrupts the saved markdown on every editor keystroke
(this function runs inside `onUpdate` before `putFile`). Fix: decode `&amp;` **last**,
or decode in a single pass with one regex + lookup table:

```ts
s.replace(/&(amp|lt|gt|quot|#39|apos);/g, (_, e) => ({ amp:'&', lt:'<', gt:'>', quot:'"', '#39':"'", apos:"'" }[e]!))
```

(the single-regex form is also immune to ordering because each entity is matched
against the original text exactly once).

### 1.2 `md:changed` doesn't re-anchor annotations (`frontend/src/main.ts:21-24`)

```ts
on('md:changed', async () => {
  const content = await getFile()
  setContent(content)
})
```

`setContent()` replaces the whole document in one transaction. The annotations
plugin then maps every stored anchor through that full-document-replacement step,
which collapses them to position 0 — exactly the failure mode described in the
docstring of `triggerContentReplaced` (`annotations.ts:82-86`). The source-view
toggle calls `triggerContentReplaced` after `setContent`; the `md:changed` handler
does not. After any external file edit (e.g. an agent editing the `.md`), all
inline decorations and gutter cards are mispositioned until the next sidecar event.

Fix: mirror the toggle path —

```ts
on('md:changed', async () => {
  const content = await getFile()
  setContent(content)
  const ed = getEditor()
  if (ed) { triggerContentReplaced(ed); scheduleGutterRebuild() }
})
```

(guarding for the `setContent` early-return case is fine — `content-replaced`
re-anchoring on an unchanged doc is harmless).

### 1.3 Byte offsets computed against lowercased text (`src/sidecar.rs:98-152`)

`anchor()` searches `doc.to_lowercase()` but returns byte offsets used to slice the
**original** doc (and ultimately drive `replace_range` in `accept.rs`). Rust
lowercasing is not length-preserving: `İ` (U+0130, 2 bytes) lowercases to `i̇`
(3 bytes), `ẞ` → `ß` etc. Any such character before the match shifts every offset,
producing wrong patch ranges or a panic in `replace_range` (non-char-boundary).
The same class of bug exists in Pass 3: `byte_to_char` counts chars in
`stripped_lower`, but that count is used to index `pos_map`, which is indexed by
chars of the *original* stripped text — the two can diverge for the same reason.

Options:
- Do a case-insensitive search that preserves offsets: compare char-by-char with
  `char::to_lowercase()` on both sides while walking the original string, or
- Build the lowercase haystack with its own position map (like `pos_map`), or
- Restrict to ASCII case-folding (`eq_ignore_ascii_case`-style scan), which is
  length-preserving and probably matches the actual intent.

### 1.4 `--token` mode breaks the frontend entirely (`src/server.rs:41-58`, `frontend/src/api.ts`)

`auth_middleware` requires `Authorization: Bearer <token>` on every route —
including `/`, `/assets/*` and `/ws` — but the frontend never sends an
Authorization header, and the browser `WebSocket` API *cannot* send one. With
`--token` set, the browser can't even load `index.html`. Either:
- exempt the static assets and accept a `?token=` query param for `/ws` and the
  API fetches (store it from the URL on boot), or
- document `--token` as API-only and skip auth for the HTML/asset routes.

### 1.5 `put_folio` skips the read-only check and doesn't validate (`src/server.rs:120-133`)

`put_file` refuses writes in `--read-only` mode; `put_folio` doesn't, so a
"read-only" session can still resolve/reject/add annotations. It also writes the
raw request body to disk without parsing it, so one malformed PUT corrupts the
sidecar for every other consumer (`Sidecar::load` will then fail in the CLI).
Deserialize the body as `Sidecar` first (which also enforces `version == 1`) and
honor `read_only`.

### 1.6 Lost-update race on the sidecar (`frontend/src/annotations.ts` + agents)

Every frontend mutation PUTs the **entire in-memory sidecar**
(`resolveAnnotation`, `addCommentAnnotation`, `submitReply`, the undo paths). If an
agent appends an annotation between the frontend's last read and its next PUT, the
agent's annotation is silently deleted (last-writer-wins on the whole file). The
watcher/WS round-trip narrows the window but can't close it. Cheap fix: add a
monotonically increasing `rev` to the sidecar; the server rejects a PUT whose `rev`
doesn't match the file's current one (HTTP 409), and the frontend refetches, replays
its mutation, and retries. That also replaces the fragile echo detection (see 3.4).

### 1.7 `charIndexToRange` returns `NaN` for an empty document (`frontend/src/annotations.ts:125-145`)

In the `toIdx > fromIdx` branch, when `charPos` is empty,
`charPos[charPos.length - 1] + 1` is `undefined + 1 = NaN`. The `fromIdx === toIdx`
branch guards against this (`charPos.length > 0 ? … : 0`); the ranged branch
doesn't. An annotation with a target arriving while the doc is empty produces NaN
positions and a decoration throw. Add the same guard.

### 1.8 `accept --all` doesn't detect overlapping ranges (`src/commands/accept.rs:78-84`)

All annotations are anchored against the original doc, then patched in reverse
order — correct **only if ranges don't overlap**. Two annotations targeting
overlapping text (easy for an agent to produce) silently generate garbled output:
the later-applied patch splices into text the earlier patch already rewrote.
After collecting `ops`, sort ascending and check `start >= prev_end`; abort with a
clear error naming the two annotation IDs if not.

### 1.9 Stale lock never cleared on Windows (`src/commands/serve.rs:20-33`)

`pid_alive` returns `true` unconditionally on non-Unix, so after a crash the lock
file makes every subsequent `folio serve` print "already running" and exit —
forever, until the user manually deletes `.folio/<file>.folio.lock`. Windows can
check a PID via `OpenProcess`, or more simply: verify the port in the lock file is
actually listening (`TcpStream::connect` with a short timeout) — that works on all
platforms and also catches PID reuse.

### 1.10 Entity tables have drifted apart (`src/sidecar.rs:646-689`)

`ends_at_partial_entity` recognizes `&#34;`, but `decode_html_entity` doesn't decode
it; the frontend's `decodeHtmlEntities` (editor.ts) handles a third, again different
set. Extract one shared list on the Rust side (a `const` array of
`(entity, char)` pairs used by both functions) and keep the TS list consistent with
it — otherwise anchoring behaves differently depending on which entity an agent
happened to copy.

### 1.11 `generate_id` uses only 32 of its 36-char alphabet (`src/sidecar.rs:910-923`)

`(hash >> (i * 4)) & 0x1f` yields 0–31, so `6789` can never appear, and only the
low 32 bits of the hash are consumed. The "entropy" mixed in is the address of a
stack local, which is effectively constant. Collisions are survivable (the
`annotate` command retries against existing IDs), but two annotations created in
the same nanosecond by concurrent processes can collide across files. Simplest
robust fix: `format!("ann_{:x}{:04x}", unix_nanos, process::id() as u16)` or pull
in `rand`/`uuid`. Also: the `#[allow(dead_code)]` on it is stale — it *is* used by
`annotate.rs`.

---

## 2. Security

### 2.1 `CorsLayer::permissive()` exposes the doc to any website (`src/server.rs:227`)

The SPA is served same-origin, so it needs **no** CORS at all — yet the router
attaches a permissive CORS layer. Consequence: while `folio serve` is running
(no token by default, bound to 127.0.0.1), *any web page open in the same browser*
can `fetch('http://127.0.0.1:7070/api/file')` to read the document, PUT to rewrite
it, and PUT `/api/folio` to tamper with annotations — a classic drive-by localhost
attack, and port 7070 is a fixed, guessable default. Remove the CORS layer (the
biggest single win in this review for the smallest diff). If cross-origin access
is ever genuinely needed, gate it behind an explicit flag.

### 2.2 Non-constant-time token comparison (`src/server.rs:53`)

`auth != bearer` short-circuits on the first differing byte. For a localhost tool
the practical risk is low, but a constant-time compare (e.g. `subtle`) is one line.

### 2.3 PlantUML default leaks document content off-machine (`frontend/src/diagrams.ts:26`)

PlantUML blocks are rendered by encoding the diagram source into a URL against
`https://www.plantuml.com/plantuml` by default — the diagram content leaves the
machine for a "local markdown editor". It's configurable via `--plantuml-url`, but
consider warning once in the UI (or README) when the default remote renderer is in
use, and note the same applies to the `--kroki-url` default (see 4.1 — currently
dead code anyway).

---

## 3. Performance

### 3.1 Anchoring strips the document once per annotation (backend, biggest win)

`anchor_chars` (`src/sidecar.rs:726-737`) calls `strip_markdown(doc)` — a full
char-indices collection + rebuild of the entire document — **inside** the function.
`post_anchor` (`src/server.rs:202-212`) then calls it once per request item, so a
100-annotation sidecar against a 100 KB doc re-strips ~10 MB per anchor request,
on every keystroke-triggered re-anchor. The same pattern repeats in
`Annotation::anchor` for `accept.rs` (per annotation), `check.rs` (per annotation),
and the doc is additionally `to_lowercase()`d per annotation.

Fix: introduce a `StrippedDoc { stripped, stripped_lower, pos_map, raw_spans }`
computed once, and make `anchor_chars`/`anchor` take `&StrippedDoc`. This is a
mechanical refactor and turns O(annotations × doc) into O(doc + annotations × search).
Similarly, `byte_to_char` (`sidecar.rs:145`, `740`) is an O(n) scan per call; if it
shows up after the above, precompute a byte→char table or use the match byte offset
directly against a byte-indexed pos_map.

### 3.2 Full gutter rebuild on every scroll event (`frontend/src/annotations.ts:1030-1031`)

```ts
const onScroll = () => buildGutterCards(pmView, gutterEl, editor)
scrollContainer?.addEventListener('scroll', onScroll)
```

`buildGutterCards` destroys and recreates **every card's DOM** (including markdown
re-parsing for comments/replies via `renderMarkdownContent`), calls
`coordsAtPos` per annotation, and forces layout in `repositionCards` — on *every
scroll tick*. Two problems:

1. Card `top` is computed content-relative (`coords.top - wrapperRect.top +
   wrapper.scrollTop`), so scrolling doesn't change the result — the rebuild is a
   no-op that burns a full layout + DOM churn per frame.
2. The rebuild destroys a reply `<textarea>` mid-typing if anything scrolls the
   container (the draft survives via `replyDrafts`, but focus and cursor are lost).

Fix: drop the scroll listener (positions don't depend on scroll), or if it exists
to catch late layout (images/diagrams loading), replace it with a
`requestAnimationFrame`-throttled *reposition-only* pass (`repositionCards`
recomputing `anchorTop` from `coordsAtPos`) that never rebuilds card DOM. Also
consider keying cards by annotation id and diffing instead of rebuild-all in
`buildGutterCards` generally — it currently also runs on every editor transaction
via `update()`.

### 3.3 Bundle size: `lowlight(all)` and eager mermaid (`frontend/src/diagrams.ts:2-7`)

- `createLowlight(all)` registers *every* highlight.js grammar (~190 languages,
  roughly 1 MB of JS). `common` (~37 languages) covers virtually all real docs:
  `import { common, createLowlight } from 'lowlight'`.
- `mermaid` is a ~1.5 MB dependency imported statically, so every user pays for it
  on first paint even for documents with no diagrams. Load it on demand:
  `const { default: mermaid } = await import('mermaid')` inside `renderMermaid`,
  memoized. Same for `plantuml-encoder` (small, but free to defer).

Together these should cut the initial JS payload by well over half.

### 3.4 Echo detection via full JSON serialization (`frontend/src/annotations.ts:56`)

`updateSidecar` runs `JSON.stringify(sidecar) === JSON.stringify(currentSidecar)`
on every `folio:changed` event — O(sidecar size), allocating two full strings, and
correct only because the frontend itself wrote the file (key order matches). A
`rev` counter (see 1.6) or a "last written body" string captured at PUT time makes
this exact and O(1)/O(compare).

### 3.5 Embedded assets copied per request; no cache headers (`src/server.rs:60-86`)

`content.data.into_owned()` clones the embedded byte slice on every request.
`rust-embed` returns `Cow<'static, [u8]>`; in release builds it's `Borrowed`, and
`Body::from(&'static [u8])` (or `Bytes::from_static`) serves it zero-copy. Vite
emits content-hashed asset filenames, so also add
`cache-control: public, max-age=31536000, immutable` on `/assets/*` — the browser
then skips re-fetching ~2 MB of JS on every page load.

### 3.6 Table-UI mousemove does layout work per event (`frontend/src/table-ui.ts:331-352`)

`onMouseMove` calls `getBoundingClientRect` on the container, cell, and table and
rewrites handle styles on every mousemove, even when the hovered cell hasn't
changed. Early-return when `cell === hoveredCell` (positions only change on scroll,
which is already handled by `onScroll`).

---

## 4. Dead code & duplication

### 4.1 The kroki pathway is dead end-to-end

`--kroki-url` (main.rs), `AppState.kroki_url`, `GET /api/kroki-url` (server.rs:143-145),
and `getKrokiUrl` (api.ts:20-21) — nothing ever calls the endpoint or the client
function; diagrams use PlantUML + mermaid only. Either wire kroki up as intended or
delete all four pieces.

### 4.2 `Annotation::anchor` and `anchor_chars` duplicate the search engine (`src/sidecar.rs:89-215` vs `726-809`)

Both implement the same exact→spaced→fuzzy pipeline (~80 lines each) with subtle
differences (e.g. `anchor_chars` tries the fuzzy pass with both separators,
`anchor` only with `""`; `anchor` warns on fuzzy, `anchor_chars` doesn't). Since
`anchor_chars` already returns char indices into the stripped text and
`strip_markdown` returns `pos_map`/`raw_spans`, `anchor()` can be reduced to:
run the raw Pass 1/2 fast path, then delegate to `anchor_chars` and convert char
indices to raw bytes via `pos_map`/`raw_end_from`. One engine, one set of tests,
divergence impossible. This pairs naturally with the `StrippedDoc` refactor (3.1).

### 4.3 `process::exit` inside command functions (`accept.rs`, `reject.rs`, `check.rs`)

Commands both return `anyhow::Result` *and* call `process::exit(1|2|3)` mid-function.
Exit skips destructors, and makes the functions untestable. Return a typed error
(or `anyhow` with a stored exit code) and let `main` map it to the process exit
code — `main` already has the error funnel.

### 4.4 Duplicated `folio_path` boilerplate

`commands/mod.rs::folio_path` and `lock_path` are copy-paste except the suffix —
one `fn sidecar_file(file: &Path, ext: &str) -> PathBuf` suffices. Similarly
`serve.rs::lock_path` is a pure pass-through wrapper that can be dropped.

---

## 5. Robustness & UX

### 5.1 Editors that save via rename can kill the file watch (`src/watcher.rs:24`)

`watcher.watch(&doc_path, NonRecursive)` watches the inode. Vim, and many editors
in "safe write" mode, write a temp file and rename it over the original — the
watch then points at a deleted inode and `md:changed` never fires again. Watch the
document's **parent directory** and filter events by path (the code already does
exactly this dance for the sidecar file; apply the same treatment to the doc).

### 5.2 No event coalescing in the watcher (`src/watcher.rs:37-62`)

A single editor save typically emits several Modify events; each one triggers a
broadcast → frontend refetch of the whole file. The `DEBOUNCE` constant only
suppresses self-echo. Coalesce genuine events too (e.g. don't rebroadcast the same
event type within ~100 ms).

### 5.3 Save debounce loses the last 300 ms of edits on tab close (`frontend/src/editor.ts:34-37`)

If the user edits and closes the tab within the debounce window, the PUT never
fires. Add `window.addEventListener('beforeunload'/'pagehide', flushSave)` — with
`navigator.sendBeacon` or `fetch(..., { keepalive: true })` so the request survives
unload.

### 5.4 No resync after WebSocket reconnect (`frontend/src/websocket.ts:36-38`)

Reconnect after 2 s is fine, but events emitted while disconnected are gone —
the UI silently shows stale content until the *next* change. On `ws.onopen` after
a drop, refetch file + sidecar once (reuse the `md:changed`/`folio:changed`
handlers). Optionally add jittered backoff, but the resync matters more.

### 5.5 API layer never checks `response.ok` (`frontend/src/api.ts`)

Every wrapper resolves happily on 4xx/5xx: `getFolio` will try to `JSON.parse` an
error string, `putFile`/`putFolio` failures (e.g. the 403 from read-only mode!)
are silently discarded by every caller. Add a small `ensureOk(r)` helper, and
surface persistent save failures in the UI (even a transient toast) — right now
read-only mode looks like it's working in the editor while nothing persists.

### 5.6 Frontend annotation IDs are weaker than the CLI's (`frontend/src/annotations.ts:168`, `537`)

`ann-${Date.now()}` / `reply-${Date.now()}` collide for two creations in the same
millisecond and don't match the backend's `ann_xxxxxxxx` shape.
`crypto.randomUUID()` is available in every supported browser and free.

### 5.7 Mixed Tiptap versions (`frontend/package.json`)

All Tiptap packages are pinned to `3.23.6` except
`@tiptap/extension-code-block-lowlight` at `^3.25.0`. Two Tiptap minor versions in
one tree is a known source of "instanceof mismatch" bugs in ProseMirror plugins.
Align them (pin all to the same version, ideally via a single `pnpm.overrides` or
catalog entry).

---

## 6. Testing gaps

The anchoring engine is well tested (30+ cases in `sidecar.rs`, plus
`annotations.test.ts` for the char-index mapping). Missing:

- **`accept.rs`**: no tests at all — reverse-order patching, insert-vs-replace,
  the overlapping-range case (1.8), and multi-annotation accept ordering are
  exactly the kind of logic that regresses silently.
- **`decodeHtmlEntities` (editor.ts)**: the double-decode bug (1.1) would have been
  caught by a one-line test (`&amp;lt;` → `&lt;`).
- **Server endpoints**: `put_folio` validation/read-only behavior (1.5) and
  `post_anchor` are easy to cover with `tower::ServiceExt::oneshot`.
- **Unicode/case-fold anchoring** (1.3): add a test with `İ`/`ẞ` in the document
  before the target once the fix lands.

---

## Suggested priority

| Priority | Items | Rationale |
|---|---|---|
| P0 | 1.1, 1.2, 2.1 | Silent data corruption on save; broken annotations after external edits; drive-by read/write of the doc. All are small diffs. |
| P1 | 1.5, 1.6, 1.8, 3.1, 3.2 | Sidecar integrity + the two large performance wins. |
| P2 | 1.3, 1.4, 3.3, 5.1, 5.3, 5.5 | Real but narrower: Unicode edge cases, token mode, bundle size, watcher/save robustness. |
| P3 | Everything else | Cleanups, dead code, hygiene. |
