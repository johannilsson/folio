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
  the source the text's width after the line numbers. Tables and wide pictures do not widen it.
- Annotations not found in the document are parked after the text, dimmed, "Not found in
  document", as in the pane.

### The card

- The same `AnnotationCardView` as in the pane and the open card, with a 3 pt purple bar on its
  left. All kinds are inline: comments and highlights (Dismiss) and suggestions (Accept / Reject).
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

- The preference is read by `EditorWindowController` (`commentsInline`, beside `commentsOn`).
  `AppDelegate` owns the menu action: it writes the preference and calls `refreshMode()` on each
  window controller it holds (no `NotificationCenter` broadcast).
- `AnnotationController.collapsed: Set<String>`, the window's collapsed annotations. Not cleared
  by `fileChanged`.
- `AnnotationController` gets an `inlineShown` (`!paneShown && owner.commentsInline`) beside
  `paneShown`; `layout()` gets a third branch.

### Logic (FolioKit)

`CardLayout.inline(_ cards: [InlineCard], end: CGFloat) -> InlineLayout`, a pure function:

- `InlineCard`: the row it belongs to (a character location where the room goes, nil when not
  found), its order in the document, its measured height.
- Groups cards by row, orders them, stacks them 6 pt apart, and returns, per row, the room to
  leave after it (cards' heights + gaps + top/bottom padding) and each card's offset below its
  row; unanchored cards stacked from `end`.
- Unit tests in `macos/Tests/FolioKitTests/` for: one card; several in one row in document order;
  rows in any input order; not found parked at `end`; a collapsed height.

The rows themselves come from the surfaces, because only they know what a block or line is.

### Surfaces

`AnnotationSurface` gets two members, implemented by `PreviewView` and `SourceEditorView`:

- Each `AnchorRect` also reports its row: `rowEnd` (the display location of the last character of
  the row: the block's end in the preview, the line's end in the source) and `rowBottom` (the
  bottom of the row's last line, without any room added after it).
- `setInlineRoom(_ room: [Int: CGFloat])`: room to leave after the line fragment that ends at each
  location. Both text views are TextKit 1: an `NSLayoutManagerDelegate` answers
  `layoutManager(_:paragraphSpacingAfterGlyphAt:withProposedLineFragmentRect:)` from this table.
  Setting an equal table does nothing; a different one invalidates the layout of the affected
  rows only.

The loop: the surface reports anchors → the controller measures cards at the column width and
calls `CardLayout.inline` → it hands the room to the surface → the surface lays out and reports
anchors again. Card heights depend on the column width, not on where the cards are, so the second
report gives the same room and the loop stops (the equal-table check is what stops it).

Things to watch, from the rules in `CLAUDE.md`:

- `PreviewTextView.drawBackground` (code blocks, quote bars, the frontmatter box) must not paint
  into the room: a block's background ends at its last line's used rect, not its line fragment
  rect.
- Annotation marks are drawn line by line and never over a line break; the room after a line is
  not part of any line's mark.
- `LineNumberView` numbers each source line at its first fragment, so the room gets no number.
- The suggestion previews the preview puts into the text change locations; the room table is
  rebuilt from the anchors reported after each rebuild, never kept across it.

### UI

- Inline cards are placed in the scrolling canvas where the open card goes today
  (`host.floatingHost`), at `x` = the column's left and `y` = `rowBottom` + the offset from
  `CardLayout.inline`.
- `AnnotationCardView` gets an `isInline` look (left bar, column width) and an `isCollapsed` look
  (one line), each measured like the others, and a Collapse hover action reporting through
  `AnnotationCardHandlers`.
- `NewCommentView` placed the same way for the form.
- The View menu item validates against the key window's `commentsOn` (dimmed) and the preference
  (checkmark).

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

1. `CardLayout.inline` and its unit tests.
2. Surfaces: `rowEnd` / `rowBottom` and `setInlineRoom` with the layout manager delegates, checked
   with room but no cards (text moves, backgrounds and line numbers stay right).
3. The preference, the menu item and `layout()`'s inline branch: cards in place, focus.
4. Collapse.
5. The inline form.
6. Keeping the first visible line when switching layouts.
7. Self-test checks and pictures; `CLAUDE.md`'s "Annotation UI patterns" gets the inline layout.

## Not in this change

- A per-card float/inline choice.
- Remembering collapsed cards across windows or launches.
- Inline cards with the pane open.
