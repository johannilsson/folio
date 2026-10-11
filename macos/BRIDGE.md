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
| `krokiUrl` | | string |
| `anchor` | `items: [{ id, context_before, target? }]` | `[{ id, char_from?, char_to? }]` |
| `anchorRaw` | same | same, offsets into the raw markdown |

- `putFolio.body` is already serialized (`JSON.stringify(sidecar, null, 2)`); Swift writes
  it verbatim so the bytes match what the server and CLI produce.
- `anchor`, `anchorRaw` and `accept` read the current files and call the Rust library
  (`folio_anchor`, `folio_accept`, `macos/include/folio.h`).
- `accept` patches the markdown and marks the annotation resolved. It must emit
  `md:changed` and then `folio:changed` (the order the server uses), and reject on failure
  (annotation not found, anchoring failed).

## Events (Swift to page)

`window.__folioEmit(type, file)` with `type` `"md:changed"` or `"folio:changed"`.
Defined by `websocket.ts` only when the bridge is present. `md:changed` must not fire for
the app's own `putFile` writes (the server suppresses these for 500 ms); `folio:changed`
always fires, the page recognises its own echo.
