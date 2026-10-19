# Native bridge contract

Inside the macOS app the page finds `window.webkit.messageHandlers.folio` (a
`WKScriptMessageHandlerWithReply`) and `frontend/src/api.ts` sends every backend call
through it. The app's self-test (`macos/Sources/Folio/SelfTest/`) drives the page
through this contract.

A message is `{ op, file?, ...payload }`. `file` is the active document id (absent for
single-file windows). Replies are JSON-compatible values; a Swift error rejects the
promise on the JS side.

| op | payload | reply |
|---|---|---|
| `info` | | `{ id, filename, set: string\|null, plantumlUrl }` |
| `getFile` | | the markdown, as a string |
| `putFile` | `content: string` | `null` |
| `getFolio` | | the sidecar object; `{ version: 1, annotations: [] }` if none exists |
| `layout` | `height: number` | `null`; the page's full height in points, sent whenever it changes (see Scrolling) |
| `reveal` | `top: number, bottom: number` | `null`; a rectangle of the page, in page coordinates, to bring into view (see Scrolling) |
| `anchors` | `anchors: [{ id, from, top, bottom, left }]` | `null`; where each pending annotation starts in the preview (page coordinates; `from` is its place in the document), sent once anchoring has answered and whenever it changes |
| `selection` | `selection: { from, to, top, bottom, endBottom, left, right, target, contextBefore } \| null` | `null`; the text selected in the preview, and the words an annotation on it is anchored by (see Annotations) |
| `focus` | `id: string \| null` | `null`; the annotation clicked in the text, or null for a click on plain text |
| `pointer` | | `null`; the reader pressed the mouse somewhere in the page, before the page acted on it |
| `typing` | | `null`; the reader typed in the page |
| `krokiUrl` | | string |
| `anchor` | `text: string, items: [{ id, context_before, target? }]` | `[{ id, char_from?, char_to? }]`, UTF-16 offsets into `text` |

- `anchor` passes the preview's rendered `text` to the Rust library (`folio_anchor`,
  `macos/Sources/CFolio/include/folio.h`). The source editor anchors against its own text
  natively, and every edit to a sidecar is made by the app (`folio_edit`, `folio_accept`), so
  the page has no ops for writing one.

## Sets

A set window answers every op for the file named by `file` (a set file's id); no `file` means
the first. `info` returns the set's name in `set`. The page opens on `?file=<id>`. The window's sidebar switches files by calling
`window.__folioSwitchFile(id)`, which resolves once the page has saved the file it left
and shows the new one (the source editor, when it is the visible mode, loads the new file itself). Events carry the id of the file they are about.

## Native chrome

The scheme handler serves `index.html` with `class="native-chrome"` on `<html>`, which hides
the in-page title pill (the window title and toolbar replace it). The mode (preview or source)
and the comments pane are the app's state, not the page's: the toolbar and View menu switch
them natively, the pane slides by animating its width, and the unresolved count on the comments
icon comes from the annotation store. The page is the WYSIWYG preview only; the source is the
native `SourceEditorView`. Switching to the source has the page save first (`__folioFlush`);
switching back calls `window.__folioReload()`, which reloads the content from the file.

## Scrolling

No box in the page scrolls. The page lays itself out at its full height and the window's
`EditorScrollView` scrolls it: the web view inside is exactly as tall as the page, so page
coordinates are the scroll view's document coordinates. `frontend/src/layout.ts` is the page's
half:

- `layout` reports `document.body`'s height (a `ResizeObserver`), so growth from diagrams or
  typing resizes the web view.
- `reveal` asks the scroll view to show a rectangle: the caret or selection after typing or
  keyboard navigation (not after the page changes the selection by itself), and anything that
  calls `scrollIntoView`, which `layout.ts` redirects here.
- The web view hands wheel events to the scroll view, and a drag past the window's edge
  autoscrolls it.

Swift's half of the page API: `window.__folioViewport(height)` (the visible height; a short
preview fills it), and `window.__folioRevealSelection()`, which Find calls after selecting a
match. Scroll positions are kept natively as a fraction of the scrollable height, per file of a
window and across the source/preview toggle; both layouts are re-measured as the page settles.

## Annotations

The page draws only the preview's highlights and inline suggestions. The cards, the pane,
the card that opens next to the text, the Comment button, the new-comment form, the toast and
the shortcuts (⌃J/⌃K, ⌃↩, ⌃⌫, Esc, ⌘Z) are the app's (`macos/Sources/Folio/Annotations/`), and
everything the reader does to an annotation is applied by `AnnotationStore` through libfolio
(`folio_edit`, `folio_accept`) to the sidecar as it is on disk. The page tells the app what it
needs with `anchors`, `selection`, `focus` and `pointer`; the cards sit in the same scrolling
canvas as the text, so an anchor's `top` is where its card goes. The source editor is a second
`AnnotationSurface` (the preview's is `PreviewSurface`), so the same controller and cards serve
both; it marks annotations with text attributes and reports anchors and the selection itself.

The page API the app calls:

- `window.__folioSetPending({from, to} | null)`: keep the text being commented on highlighted
  while the form is open.
- `window.__folioSelectAnnotation(id)`: put the caret at the start of an annotation.
- `window.__folioFlush()`: save pending edits, so accepting patches the text on screen.
- `window.__folioFlashAfterReload(text)`: flash `text` once the document reloads with it.

Undo: the window has no undo manager. In the preview the page has its own undo for typing, so
⌘Z and Edit ▸ Undo/Redo go to the annotation actions while one of them is the latest thing the
reader did in the page (`typing` marks the page's side), and to the page otherwise. In the
source, typing and annotation actions share the text view's one history, in the order they
happened.

## Events (Swift to page)

`window.__folioEmit(type, file)` with `type` `"md:changed"` or `"folio:changed"`.
Defined by `websocket.ts`. `md:changed` must not fire for the app's own `putFile` writes;
`folio:changed` always fires, the page recognises its own echo.
