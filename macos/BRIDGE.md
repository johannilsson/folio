# Native bridge contract

Inside the macOS app the page finds `window.webkit.messageHandlers.folio` (a
`WKScriptMessageHandlerWithReply`) and `frontend/src/api.ts` sends every backend call
through it instead of HTTP. `frontend/e2e/fixtures.ts` implements the same contract
against a real `folio serve`, and the whole Playwright suite runs through it.

A message is `{ op, file?, ...payload }`. `file` is the active document id (absent for
single-file windows). Replies are JSON-compatible values; a Swift error rejects the
promise on the JS side.

| op | payload | reply |
|---|---|---|
| `info` | | `{ id, filename, set: string\|null, plantumlUrl }` |
| `files` | | `[{ id, name, group, pending }]` |
| `getFile` | | the markdown, as a string |
| `putFile` | `content: string` | `null` |
| `getFolio` | | the sidecar object; `{ version: 1, annotations: [] }` if none exists |
| `putFolio` | `body: string` | `null` |
| `accept` | `id: string` | `null`; see below |
| `uiState` | `source: bool, comments: bool, pending: int` | `null`; the page's view toggles and its unresolved annotation count, mirrored by the native toolbar (the count is the comments icon's badge) |
| `krokiUrl` | | string |
| `anchor` | `text: string, items: [{ id, context_before, target? }]` | `[{ id, char_from?, char_to? }]`, UTF-16 offsets into `text` |
| `anchorRaw` | `items` as for `anchor` | same, offsets into the raw markdown |

- `putFolio.body` is already serialized (`JSON.stringify(sidecar, null, 2)`); Swift writes
  it verbatim so the bytes match what the server and CLI produce.
- `anchor` passes the preview's rendered `text` to the Rust library; `anchorRaw` and
  `accept` read the current files. All call it (`folio_anchor`, `folio_accept`,
  `macos/Sources/CFolio/include/folio.h`).
- `accept` patches the markdown and marks the annotation resolved. It must emit
  `md:changed` and then `folio:changed` (the order the server uses), and reject on failure
  (annotation not found, anchoring failed).

## Sets

A set window answers every op for the file named by `file` (a set file's id); no `file` means
the first. `info` returns the set's name in `set`, and `files` lists all of its files. The
page opens on `?file=<id>`. The window's sidebar switches files by calling
`window.__folioSwitchFile(id)`, which resolves once the page has saved the file it left
and shows the new one. Events carry the id of the file they are about.

## Native chrome

The scheme handler serves `index.html` with `class="native-chrome"` on `<html>`, which hides
the in-page title pill and toggle buttons (the window title and toolbar replace them). The
toolbar and View menu act on the page by clicking `#view-toggle-btn` and `#toggle-gutter-btn`.
The same class makes the page open in the WYSIWYG preview (the browser opens in source), trims
the space above the text, and slides the comments pane in and out by animating its width.

## Events (Swift to page)

`window.__folioEmit(type, file)` with `type` `"md:changed"` or `"folio:changed"`.
Defined by `websocket.ts` only when the bridge is present. `md:changed` must not fire for
the app's own `putFile` writes (the server suppresses these for 500 ms); `folio:changed`
always fires, the page recognises its own echo.
