# The annotation UI

`macos/Sources/Folio/Annotations/`: the cards, the comments pane, the card that opens next to the text, the Comment button, the new-comment form, the toast and the shortcuts. All native, the same in both modes.

## Pieces

- `AnnotationStore` is one file's annotations and every action on them, through libfolio, with undo.
- `AnnotationController` is a window's glue: the surface reports in, cards and overlays go out, and it handles the keyboard.
- `AnnotationCardView` and friends are the views, laid out by hand (heights are measured, not Auto Layout).
- The cards live in `EditorScrollView`'s canvas beside the text, so an anchor's `top` is the card's `y`.
- Both modes use it through the `AnnotationSurface` protocol: `PreviewView` for the preview, `SourceEditorView` for the source.
- **Undo.** The document has no undo manager on purpose ([decisions](../decisions.md#the-document-has-no-undo-manager)).
  - In the preview, ⌘Z and Edit ▸ Undo go to the annotation actions (`AppDelegate.undoEdit`).
  - In the source, typing and annotation actions share the text view's one history.

## What each kind looks like

| Kind | Inline decoration | Card actions |
|---|---|---|
| `replace` | Red strikethrough and a green replacement preview | Accept / Reject |
| `delete` | Red strikethrough and a red bottom border | Accept / Reject |
| `insert` | Green inline preview and a green bottom border | Accept / Reject |
| `highlight` | Purple background | Accept / Reject |
| `comment` | Purple background (same as highlight) | Dismiss |

Each annotation can carry a `replies` array. The local user posts replies with `source: local`, `author: me`. The fields are in the [sidecar format](../reference/sidecar-format.md).

## Anchoring

The preview and the source anchor with `Rust.anchor(raw: true)` against the markdown.

- The anchoring text is flat: block boundaries are invisible, with **no separator** between blocks.
- So `context_before` is plain rendered text (not markdown syntax), and it never has a newline for a block break.
- Annotations written by agents must use rendered text too.

## How the cards behave

- **Pane layout.** The cards sit beside the text and scroll with it: the window's scroll view scrolls the text and the pane together ([scrolling](macos-app.md#scrolling)). When open, the pane takes 304 points of the width (280 plus a 24 margin), and the text reflows.
- **Card positioning.** A card sits at its anchor's top minus 4, in document order. It is pushed down 6 points when it would overlap the one above (real heights, measured). An annotation not found in the document is parked after the text, dimmed, with "Not found in document".
- **Focus.** Clicking annotated text (or ⌃J/⌃K) focuses an annotation: its card gets the accent border and its reply field. Clicking plain text clears it.
- **Open card.** When the comments pane is closed, the focused annotation's full card is shown next to the text.
  - It flips above the anchor near the bottom of the visible area.
  - Only the focused annotation is shown. Esc or clicking elsewhere dismisses it, and opening the pane puts it back in the pane.
  - It is the same card view as in the pane, so a half-typed reply survives.
- **Inline cards.** With the pane closed, View ▸ Comments Inline puts every card in the text, under the row its annotation ends on. See [inline comments](../features/inline-comments.md).
- **The Comment button** does not take the keyboard, so the selection in the text view stays selected.
