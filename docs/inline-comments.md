# Inline comments

When the comments pane is closed, a card today floats next to the text only while its annotation
has focus. This adds a second way to show cards with the pane closed: every card sits in the text,
under the row its annotation ends on, the way a comment sits under a line in a code review. It
makes it easy to see where each annotation is anchored without opening them one by one.

Mockups (option A was chosen): https://claude.ai/artifact/VgWe6RKLH4vdDF1xzrgtLu

## Behaviour

### When it applies

- Only while the comments pane is closed. With the pane open, the pane is used as today.
- With the pane closed, cards are either all **floating** (today's open card) or all **inline**.
  There is no per-card choice.
- It works the same in the preview and in the source editor.

### Switching

- View ▸ **Comments Inline** (⌥⌘I), a checkmark item below Toggle Comments.
- It is dimmed while the pane is open. Its checkmark still shows the setting.
- It is one app-wide preference (`UserDefaults`, key `CommentsInline`), kept across launches,
  and off by default. Changing it updates every open window.
- The toolbar does not change: its comments button still opens and closes the pane.

### Where a card goes (its row)

- **Preview**: after the block that holds the end of the annotation's text: a paragraph, a list
  item, a block quote's paragraph, a heading, a code block (after the whole block), a table (after
  its last row), a picture or diagram.
- **Source**: after the source line that holds the end of the annotation's text. A wrapped line
  gets the card after its last wrapped fragment.
- The text below the row moves down to make room. Nothing is put into the text: the room is
  layout only (see "How it is built"), so the file and the preview's map are untouched.
- Several annotations ending in the same row: one card each, stacked under it in document order
  (the order the pane uses), 6 pt apart.
- The card is the column's width: in the preview the text column (`column`, inset by `side`), in
  the source the text's width after the line numbers, up to the preview's column (760 pt). Tables and wide pictures do not widen it.
- Annotations not found in the document are parked after the text, dimmed, "Not found in
  document", as in the pane.

### The card

- The same `AnnotationCardView` as in the pane and the open card, with the same look. All kinds are inline: comments and highlights (Dismiss) and suggestions (Accept / Reject).
- Cards start expanded. Each can be **collapsed** to one line: avatar, author, the first words of
  the comment (for a suggestion, `old → new`) and the reply count. Collapse is one of the card's
  hover actions; clicking a collapsed line expands it.
- What is collapsed is kept per window, by annotation id, until the window closes. It survives
  switching files in a set, switching preview/source, and opening and closing the pane. It is
  never written to the sidecar or to the config.

### Focus and keys

- Clicking annotated text, or ⌃J/⌃K, focuses its card: accent border, reply field, and expanded
  if it was collapsed (it stays expanded). The window scrolls only if the card is not visible.
- Clicking plain text drops the focus. The cards stay; unlike the floating card, nothing closes.
- Esc drops the focus, as today. ⌃↩ / ⌃⌫ act on the focused card, as today.
- The MCP `reveal` tool focuses the card and scrolls it into view.

### New comments

- Select text, press Comment: the form opens inline under the selection's row, where the card
  will be once it is posted. Cancelling removes it and its room.

### Switching layouts

- Turning inline on or off, or opening or closing the pane, keeps the first visible line of text
  where it is on screen (the room under rows changes the text's height, so the scroll fraction is
  not enough here).

## How it is built

Follows "How the app is built" in `CLAUDE.md`. No Rust or sidecar changes.

### State

- The preference is `AppConfig.commentsInline` (`UserDefaults`, `CommentsInline`), read by
  `EditorWindowController.commentsInline` beside `commentsOn`. The menu action
  (`toggleCommentsInline`) is the window controller's, reached through the responder chain; it
  writes the preference and calls `annotations.refreshMode()` on every editor window. The window
  controller validates the item (`NSMenuItemValidation`): dimmed while its pane is open, ticked
  from the preference.
- `AnnotationController.collapsed: Set<String>`, the window's collapsed annotations. Not cleared
  by `fileChanged`. Focusing a card removes it; the card's Collapse button adds it (and drops the
  focus if it had it).
- `AnnotationController.inlineShown` (`!commentsOn && owner.commentsInline`) beside `paneShown`;
  `layout()` has a third branch, `placeInline()`.

### Logic (FolioKit)

- `CardLayout.inline(_ cards: [InlineCard], end:) -> (placed, room, extent)`. A card's row is a
  `CardLayout.Row`: `end` (the row's last character, which names it), `bottom` (where its text
  ends) and `next` (where the text after it starts without room). Cards go 8 below `bottom`,
  6 apart in document order, and the room makes the text after the row start 14 below the last
  one (none when the row already has that much). Not found: stacked from `end`.
- `PreviewText.row(at:in:)`: which row of the rendered text holds a character. A paragraph,
  heading or list item; a block of code (or the frontmatter box) as a whole, flagged as painted;
  a table as a whole, ending with the line after it, which is outside the table's text blocks.
- Unit tests: `CardLayoutTests` (one card, several in a row, rows in any order, enough room
  already, not found, none) and `PreviewTextTests` (paragraph, code block, table).

### Surfaces

`AnnotationSurface` gets three members, implemented by `PreviewView` and `SourceEditorView`:

- `row(at:)`: the row holding a character of the file. Each `AnchorRect` carries its row too.
  The preview uses `PreviewText.row` and puts `bottom` 10 lower below a painted block (its paint
  reaches 10 below the text); the source uses the line (`paragraphRange`).
- `setInlineRoom(_:)`: room after rows, by `Row.end`. Laid out again, then the surface reports
  its anchors, so the cards follow.
- `inlineColumn`: the left of the text column and its width.

The room is `InlineRoom` (`TextSurface.swift`), each text view's `NSLayoutManagerDelegate`. In
`layoutManager(_:shouldSetLineFragmentRect:…)` it makes the line fragment that ends a row taller.
The used rect and the glyphs stay where they were, so nothing goes into the text, and the paint
behind blocks (which follows the glyphs' bounding rects) does not grow into the room. Line numbers
are drawn at a fragment's top, so the room gets none. The table is reset whenever the text is
replaced (a load, a suggestion's preview put in), and in the source it moves with typing, as the
annotation ranges do.

The loop: the surface reports anchors → the controller measures the cards at the column width and
calls `CardLayout.inline` → it places them and hands the room to the surface last → the surface
lays out and reports again → the cards are placed from there. The room does not depend on where a
row is, only on its own text and cards, so the second pass gives the same room, `InlineRoom.set`
finds nothing changed, and it stops.

Still to look at: a quote's bar runs past a card under one of its paragraphs (the bar spans the
quote), and a selection that ends on a row paints over the room.

### UI

- Inline cards are placed in the scrolling canvas where the open card goes (`host.floatingHost`),
  at the column's left. The canvas is made tall enough for parked cards (`setGutterExtent`).
- `AnnotationCardView` has an `isInline` state (the pane's look, plus a Collapse hover action) and an `isCollapsed` one (36 pt: a small avatar, the name, the first line of what
  it says and the reply count).
- `NewCommentView` is placed the same way for the form, under the selection's row.

## Tests

- **Unit** (FolioKit): `CardLayout.inline` as above.
- **Self-test** (`SelfTest+Annotations.swift`, new checks, in both modes):
  - Comments Inline on with the pane closed: each card's top is below its row's last line and
    above the next block's text; turning it off puts the text back where it was.
  - The menu item is dimmed while the pane is open; opening the pane moves the cards into it.
  - Two annotations in one paragraph: two cards under it, in document order.
  - Source: typing a line above an annotation moves its card down with the line; typing in the
    annotated line keeps the card under it.
  - Collapse a card, switch file in a set and back, switch to source and back: still collapsed.
  - Clicking annotated text focuses and expands a collapsed card; clicking plain text keeps the
    cards.
  - An annotation not found is parked after the text.
  - `reveal` over MCP focuses and scrolls to an inline card.
- **Pictures** (`FOLIO_SNAPSHOT`): preview and source with inline cards, one collapsed, light and
  dark. The PR gets the `pictures` label.

## Steps

Done in the first pass (built and checked by CI only, on the pull request):

1. `CardLayout.inline`, `PreviewText.row` and their unit tests.
2. The surfaces: rows, `InlineRoom`, `setInlineRoom`, `inlineColumn`.
3. The preference, the menu item and `layout()`'s inline branch: cards in place, focus.
4. Collapse.
5. The inline form.
6. Self-test checks (`SelfTest+Inline.swift`) and pictures (`<base>-inline-preview.png`,
   `<base>-inline-source.png`).

Still to do:

7. Keeping the first visible line when switching layouts (the scroll fraction is used now).
8. Self-test checks still missing from the list above: two windows following the preference,
   collapse surviving a file switch in a set, the form under its row, `reveal` over MCP.
9. `CLAUDE.md`'s "Annotation UI patterns" gets the inline layout once it settles.

## Not in this change

- A per-card float/inline choice.
- Remembering collapsed cards across windows or launches.
- Inline cards with the pane open.
