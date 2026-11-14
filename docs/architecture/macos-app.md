# The macOS app

`macos/` is a SwiftPM package: AppKit windows, no server. The preview (`PreviewView`) and the source editor are native. `frontend/dist` is served at `folio://app/` to the hidden diagram page, the only web view. How to build and run it is in [development](../development.md).

Where a new piece of Swift goes, and how it is tested: [where Swift code goes](app-layers.md).

## Windows and documents

- `FolioDocument` is one `NSDocument` per file.
- `SetWindowController` is a window for a [set](../guides/sets.md): a sidebar and the editor. The sidebar switches files by loading them into the preview.
- Both build on `EditorWindowController`: the toolbar, the two modes, Find.
- A `Workspace` holds the window's files by id.
- `Document` does the file IO and polls for changes ([why polling](../decisions.md#poll-files-instead-of-watching-them)).
- The mode (preview or source) and the comments pane are the window's state (`EditorWindowController.mode`, `commentsOn`).

## FolioKit

`macos/Sources/FolioKit/`, with tests in `macos/Tests/FolioKitTests/` (run with `swift test`). It is the logic the app is built on:

- the bridge to libfolio (`Rust.swift`; FolioKit is the target that links it);
- the sidecar model, the preview's builder and map, the source highlighter, and the card layout (`CardLayout`).

What it may and may not hold:

- It has no views, windows or app state.
- It may use AppKit types and produce styled attributed strings (fonts, system colours, the `folio…` attribute keys).
- What is loaded or drawn (pictures, diagrams, code colours from the hidden page) stays in the app.
- What the app uses from it is `public`.

It also holds the process-level Rust calls (`mcpServe`, `appListen`, `mcpSnippets`, `connectMCP`). So the [layer rule](app-layers.md) is a convention inside FolioKit, not a package boundary: logic code does not call them.

## The preview

See [the native preview](preview.md).

## Source editor

`macos/Sources/Folio/Source/`.

- `SourceEditorView` is a TextKit 1 `NSTextView`, laid out at full height inside `EditorScrollView` (it does not scroll itself).
- It comes with `MarkdownHighlighter` (line-based, in FolioKit), `LineNumberView`, and annotation marks drawn as temporary attributes.
- It writes the file itself (debounced, `Document.writeFile`).
- It reloads on outside changes unless there are unsaved edits. Then the save asks whether to keep the typing or the file.
- It anchors with `Rust.anchor(raw: true)` against its own text.

## Scrolling

The preview and the source have no scroll view of their own. Each is laid out at its full height (`layoutContent`), and `EditorScrollView` scrolls it together with the comments pane. Scroll positions are kept as a fraction, per file and across the source/preview toggle.

## Annotations

See [the annotation UI](annotation-ui.md).

## Wiki mode

A set can hold a folder of notes next to the files under review. The design and what is built are in [wiki mode](../features/wiki-mode.md). The main types:

- **The sidebar.** `Workspace` reads the set again twice a second, so the sidebar follows a `git checkout` and files added, renamed, changed and removed underneath. `SidebarTree` in FolioKit gives:
  - the tree rows;
  - the headings by repo and branch;
  - the "also on …" subtitle;
  - the notice.
- **Links into Folio.**
  - `FolioLink` is the `folio://annotation/…`, `folio://passage?…` and `folio://document?…` links. They are found by repo, branch and path in the open windows (`AppServer.open`).
  - `WikiLinks` is `[[page]]` links.
  - `WikiReferences` is the links a page holds, for the backlinks on cards.
  - `PreviewBuilder` draws links live, or grey with the reason. The reason comes from `linkState`, which asks the window, since the window knows what is open. `PreviewView.refreshLinks` redraws when that changes.
- **The Open list.**
  - `OpenList` handles the grouping, and which items are about the file on screen (`about`, `paneRows`).
  - `OpenListView` shows the list in place of the editor while the sidebar's Open row is chosen.
- **The Open pane** (`OpenPaneView`) is the set window's inspector, with two tabs:
  - Open.
  - References: `FileReferences` in FolioKit, the links of the wiki pages to the file on screen, whatever they point at, including `folio://document`. In the window: `SetWindowController.paneTab`, `fileReferences`.

  It is a third split view item, with its own tracking separator, so its toolbar button sits over it and the editor's buttons stay over the editor. In the window: `SetWindowController.openPaneOn`, `openScope`; ⇧⌘O toggles it.
- **Ticking an item** writes the item's file through libfolio, after checking the item is still on its line.
- **Cards** list the pages that link to them and the open items about them (`AnnotationCardView.references`, `.items`). The set window works these out: `SetWindowController.computeBacklinks`, `computeCardItems`.
- Self-tests: `SelfTest+Wiki.swift`.

## Recent files

Recent files are kept in `<config>/recents.json`, beside the sets (`RecentFiles`; `FOLIO_CONFIG_DIR` moves it). AppKit's own list does not survive a rebuild of an ad-hoc signed app, so it is not enough.

- File ▸ Open Recent and the welcome window read ours.
- Clear Menu and the welcome list's Clear All Recents empty it. (`welcomeChecks` runs last in the self-test.)

## MCP

`main.swift` turns `--mcp` into the MCP server before AppKit starts; nothing may print on stdout but the protocol. `AppServer` answers the server's questions about windows and the focused annotation. See [MCP](../mcp.md).

## Chrome

Chrome follows the system: the accent colour, system toolbar items, Finder-style sidebar selection. Folio's own purple is for content: annotations, selection, avatars.

## Pitfalls

- **The set window's views come first, then the toolbar.** A set window has a full-height sidebar, like Finder or Preview. It is built from `.fullSizeContentView`, an `NSSplitViewController`, and a toolbar installed *after* the split view exists, with `.toggleSidebar` and an `NSTrackingSeparatorToolbarItem`.
  - Do not give that window an intermediate `contentView` first. The replacement ends up above the title bar and hides the traffic lights and the toolbar.
  - No check notices this by itself, so the self-test asserts the order.
- **Choose a symbol, not a size.** Toolbar glyphs are drawn at a fixed size, whatever symbol configuration you give them.
- **Resizing a text view must not scroll the window.** AppKit scrolls a text view's selection into view when it is resized, and overriding `scrollToVisible` does not catch it. So `PreviewTextView` and `SourceTextView` put the clip view back where it was in `setFrameSize`.
- **Watch what is visible.** Source-mode typing "worked" while the editor was hidden. A sidebar refresh bounced the page to the first file with every check green. See [development](../development.md#look-at-the-result).
