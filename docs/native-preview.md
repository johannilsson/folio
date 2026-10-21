# Native preview: handoff and plan

A plan for replacing the WebView preview (Vite + Tiptap in a `WKWebView`) with a native one, the way
the source mode was rewritten as a native `NSTextView`. It is written to be passed to a fresh
session: it holds the decisions, what the code already offers, a phased plan, and how to verify
changes using CI (the work does not need a Mac, but you can only judge looks from CI's pictures).

> **Status:** phases 1–4 are in (PR #45). The new preview is `PreviewView` (`macos/Sources/Folio/Preview/`); the web
> one is what the `Web`-prefixed names (`WebPreviewSurface`, `AnnotationController.webPreview`, `AppConfig.webPreview`)
> and `frontend/` stand for. `PreviewView` is the default; `-WebPreview YES` shows the web one. Phase 5 deletes the `Web` names and the flag.

To start: read this file, `CLAUDE.md`, `macos/README.md` and `macos/BRIDGE.md`, then begin at
"Phase 1".

## Decisions (made with the owner)

- **The preview is the main surface.** The owner reads, comments, interacts with annotations and
  accepts them there. They rarely edit text by hand.
- **Commenting and accepting must work in the preview.** Selecting text and commenting, focusing,
  replying, resolving, accepting and rejecting all have to work. Typing into the rendered text does not.
- **So the native preview is read-only**, permanently unless the owner says otherwise. Hand edits go
  through source mode (already native). That lets Tiptap, `frontend/src/source-sync.ts` (block-level
  source sync, 188 lines) and `table-ui.ts` go in the end, and the "raw HTML makes the preview
  read-only" caveat in `CLAUDE.md` with them.
- **Keep the WebView preview until the native one has parity**, selected by a flag (for example an
  environment variable or a `UserDefaults` key), then flip the default, then delete. Do not delete first.
- The repository is public, so GitHub-hosted runners (macOS too) are free.

## What the code already gives you

- `AnnotationSurface` (`macos/Sources/Folio/Annotations/AnnotationSurface.swift`) is the seam. The
  cards, pane, open card, Comment button, form, toast and shortcuts are the same for every surface.
  `PreviewSurface` (the page) and `SourceEditorView` implement it. A native preview is a third
  implementation and replaces `PreviewSurface`.
- **Source mode already does what the native preview needs**, in `Source/SourceEditorView.swift`:
  - `reanchor()` anchors with `Rust.anchor(doc:itemsJSON:raw: true)` against the markdown and gets
    UTF-16 ranges back.
  - `applyMarks()` draws annotations as temporary attributes on the layout manager. Comments and
    highlights get a purple background, `replace` and `delete` get red and strikethrough, `insert` is a point.
  - `reportAnchors()` and `reportSelection()` turn ranges into page coordinates for the cards and the Comment button.
  - Selections become words through `Rust.renderedSelection(doc:range:)` (the target and up to 30
    characters before it, without markdown syntax), which is what agents and the CLI anchor by.
  - It is a TextKit 1 `NSTextView` laid out at full height inside `EditorScrollView`, which does the scrolling.
- Accept and every sidecar edit go through libfolio (`folio_accept`, `folio_edit`) against the
  files on disk, then the document reloads. They do not depend on the surface.
  `flashAfterReload` shows the accepted text.
- `EditorWindowController` (`FolioWindowController.swift`) owns `mode` (preview or source), the comments pane
  and the web view. `PreviewSurface(webView:bridge:)` is created there.

## Recommended design

**Build the attributed string from a markdown block tree, and keep a map from displayed characters to
source offsets.** Then the native preview reuses the source view's anchoring unchanged:

- Anchors: `Rust.anchor(raw: true)` on the markdown gives source ranges. The map turns them into
  displayed ranges for the marks and for the card positions.
- Selection: the map turns the displayed selection into a source range. `Rust.renderedSelection` then gives
  the target and `contextBefore`. No rendering rules are reimplemented in Swift.
- This avoids the old way (anchoring against the page's text with `raw: false`) and its "no separator
  between blocks" flat-text rule.
- Characters that exist only in the rendering (bullets, list numbers, table padding) have no source
  offset. The map has to say so, so a selection that ends on one is trimmed.

**`replace` and `insert` previews** (the green replacement text drawn today in `annotations.ts`
`previewWidget`): the builder takes the pending annotations and their anchored ranges, and inserts a
display-only "ghost" run, tagged with an attribute, after the target (replace) or at the point (insert).
Ghost runs have no source offset, so the map skips them. The view is rebuilt whenever the file or the
sidecar changes. Open question: ghost runs versus overlay views. Try ghost runs first, since the text
then reflows and the card positions follow.

**Parser:** `swift-markdown` (cmark-gfm) gives block and inline nodes with source ranges, tables and
task lists. Adding a SwiftPM dependency means `swift build` needs network in CI (it has it). Check
that the checkout and the app bundle script (`macos/scripts/bundle.sh`) still work.

**Open questions to settle in the spike:**
- Diagrams (`mermaid` and `plantuml` code blocks, `frontend/src/diagrams.ts`): mermaid needs JavaScript. Likely a small hidden `WKWebView` that renders to an image used as a text attachment. PlantUML is an image from the server URL the bridge calls `plantumlUrl` (`info` op).
- Tables: `NSTextTable` (TextKit 1) or an attachment view with a grid. Wide tables must not widen the page (the existing self-test checks that).
- Images and links; task-list checkboxes (display only).
- Find: source mode has `scrollHost.source.find`; the web view uses `WKFindConfiguration`. The native preview needs the same behaviour.

## Phases

Each phase ends with self-test checks and pictures (see "How to verify").

1. **Spike, read-only.** Block tree, attributed string and map for paragraphs, headings, emphasis, inline code, links, lists,
   code blocks, blockquotes, rules. A `NativePreviewView` (TextKit 1, non-editable, selectable, full height in
   `EditorScrollView`) behind the flag. Implements `AnnotationSurface`: marks for `comment`/`highlight`/`delete`,
   selection and the Comment button, focus on click, `select(annotation:)` for ⌃J/⌃K, `setPending`.
2. **Accept and suggestions.** Ghost runs for `replace` and `insert`. Accept through the existing path, keep the place
   after the reload, `flashAfterReload`.
3. **Blocks.** Tables, images, task lists, mermaid and PlantUML.
4. **Parity.** Find, scroll position kept per file and across the source/preview toggle, set windows (the sidebar currently
   calls `window.__folioSwitchFile`; the native view loads the file itself, as the source editor does), the toolbar and
   View menu, the open card, undo (the preview currently has its own page undo for typing; with no typing, ⌘Z goes
   to the annotation actions, see `AppDelegate.undoEdit`).
5. **Flip and delete.** Make native the default. Remove `frontend/` editor code the page no longer needs, the bridge ops it
   used (`anchors`, `selection`, `focus`, `pointer`, `typing`, `layout`, `reveal`, `anchor`, ...), `PreviewSurface`, and the
   bridge's page calls. Also: the TypeScript halves of what `PreviewView` ports
   (`frontend/src/frontmatter.ts`, the `plantuml-encoder` use in `diagrams.ts`, the highlight CSS) go with the editor, so the
   Swift copies (`PreviewFrontmatter`, `PlantUML`, `SyntaxColors`) become the only ones; and `continue-on-error` stays only on
   the pictures steps (the self-test itself gates the job through `scripts/verify.sh`).
   Remove every `if let preview` / `scrollHost.preview` / `AppConfig.webPreview` branch, not only the ones noticed first: `AnnotationController`
   (4 places), `EditorScrollView`, `FolioWindowController` (the find, the mode switch and `textResponder`), `SetWindowController`
   and `SelfTest`.
   Update `macos/BRIDGE.md` and `CLAUDE.md` together with the code (CLAUDE.md says a bridge op
   lives in both `Bridge.swift` and `BRIDGE.md`).

Follow the project principles in `CLAUDE.md`: simplest change, surgical edits, a self-test check for each new
behaviour, and look at a picture of the result. Do not reimplement anchoring or accept in Swift.

## How to verify (CI does it for you)

You can write Swift anywhere, but only CI's macOS runner builds and runs the app when you are on Linux.

- Push a branch and open a **draft PR**. CI runs a `verify` matrix on `ubuntu-24.04` and `macos-15`, and a `test`
  job that needs both (that is the required check). On macOS, `scripts/verify.sh` builds the app and runs the
  self-test, which gates the job.
- **Pictures:** a separate non-gating step runs the self-test again with `FOLIO_SNAPSHOT`, which also runs the
  pictures tour (`tour()` in `macos/Sources/Folio/SelfTest/SelfTest+Pictures.swift`). The tour restores the fixture
  (`macos/selftest.md`) and annotates it, so the pictures show real annotations. `scripts/ci-pictures.sh` puts
  them on a `ci-pictures` branch and in one PR comment, updated in place.
  - To look at them yourself: take the commit sha from the image URLs in that comment, then
    `curl -o x.png https://raw.githubusercontent.com/johannilsson/folio/<sha>/pr-<number>/<name>.png` and open the PNG.
  - To add a picture, add a `snapshot(...)` to the tour or to a check, and it shows up in the comment.
- **Logs:** `get_job_logs` with `return_content: true` on the macOS job. It is big, so the result is saved to a file
  as JSON (`logs_content`); parse it with Python and search for `FAIL`. The signed blob URL for logs is blocked by the
  network proxy in the cloud session, so do not use it. Self-test lines are `PASS`/`FAIL`, and a failing check can print a
  detail line before it.
- A change to the workflow does not run until a PR exists (it runs on `pull_request` and pushes to `main`).
- Known flaky checks are tracked as issues #43 (pane animation timing; no recurrence in the last five runs) and #44
  (Remove from Recents; fixed in #42, left open for a few more runs). If one fails, compare with those before debugging
  the change; re-run a failed job once, and a second failure is real. Never skip or loosen a check to get green.

## Starting prompt for a fresh session

> Read `docs/native-preview.md`, `CLAUDE.md`, `macos/README.md` and `macos/BRIDGE.md`. Implement Phase 1 of the native
> preview (read-only, behind a flag) as described, using swift-markdown if the dependency builds in CI. Open a draft PR,
> verify with CI and the pictures it produces, and report what you see before moving to Phase 2.
