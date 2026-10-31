# Folio for Windows (experimental)

A native Windows client on the Rust engine: .NET 8 and WPF, no web view except the hidden one that draws
mermaid diagrams and colours code. It is kept apart from the product: checked by its own workflow, and not part of
`./scripts/verify.sh` or the required `test` check.

What it does: opens a markdown file (`Folio.Wpf.exe <file>`) or a set (`Folio.Wpf.exe --set <name>`, or the
Set box in the toolbar) with its files in a sidebar, which the Sidebar button hides and shows. The markdown is rendered (headings, emphasis, lists and task
lists, tables, code in colour, quotes, frontmatter, pictures, mermaid diagrams), with the annotations marked in it and a card for each in the
pane beside the text, which scrolls with it. Cards sit at their text, in document order. A card accepts, rejects
or dismisses; the focused one (click its text or the card) takes a reply. Selecting text shows a Comment button
for a new comment. It follows the file, its `.folio` sidecar and the set on disk, so what an agent writes with
the CLI shows up.

Not yet: the source editor, the card that opens
beside the text with the pane closed, undo, the live link for the MCP server, an installer.

## Layers

The same three as the macOS app (CLAUDE.md, "How the app is built"):

- **Engine**: `folio.dll`, the Rust crate built as a `cdylib` into `target/cdylib` (`cargo rustc --release --lib
  --crate-type cdylib --target-dir target/cdylib`; not a crate type in `Cargo.toml`, and not in `target/release`,
  where a `libfolio.dylib` would be what the macOS app links). The C API is `src/ffi.rs`.
- **`Folio.Core`** (plain .NET, no UI; runs on any OS, so it is tested on Linux):
  - `Native`/`Engine` call the DLL: anchoring, accept, edits, rendered selections, sets.
  - `Sidecar` is the model, `Review.Place` puts the pending annotations in document order.
  - `Preview/PreviewBuilder` turns the markdown (Markdig) into blocks of spans and a `PreviewMap` between the shown
    text and the file, like `PreviewBuilder`/`PreviewText` in FolioKit. Anchors and selections go through the map
    to the engine, which works on the markdown itself.
  - `Preview/PreviewMarks` says what is marked where and cuts spans into pieces at the marks and the previews of
    suggestions; `CardLayout` stacks the cards and places the Comment button; `FolioSet.Keep` is which file stays
    shown when the set changes; `Preview/CodeColours` puts the page's colours on the code as shown and gives each
    scope its colour.
  - `ReviewFile` is a file and its sidecar on disk, changed only through the engine (accept, reject, reply, new
    comment), read without locking out an agent's write and written through a temp file of its own.
- **`Folio.Wpf`**: the window. `PreviewRenderer` draws the blocks as a `FlowDocument`, a run per piece, and keeps
  each piece's element, so a shown offset is a `TextPointer` and back. `MainWindow` draws from the disk state and
  applies what `Folio.Core` decides. `DiagramPage` is the hidden WebView2, in a window off every screen, that loads
  the diagram page (`frontend/`, built with `pnpm build` and copied next to the app), photographs each diagram and
  asks for the highlight.js scopes of each block of code; until a diagram is drawn, or when it cannot be (no WebView2
  runtime, no built page), its source is shown, and code is plain until its colours come.
  `--self-test` drives it (below).

## Checks

```bash
windows/verify.sh      # engine DLL, CLI, diagram page, build, unit tests; on Windows also the app's self-test
```

- **`Folio.Core.Tests`** (xunit) run the real engine library and the real CLI on throwaway files: the preview's
  text and map (CRLF too), that what the engine anchors is what the preview marks, the marks and cards, sets,
  accept with CRLF and a byte order mark, reject/dismiss, replies and new comments, an agent's write surviving an
  action. `FOLIO_CLI` names the CLI and `FOLIO_CONFIG_DIR` a throwaway folder for sets (`verify.sh` sets both).
- **`Folio.Wpf.exe --self-test <result file>`** opens a set made by the CLI of CRLF files annotated by the CLI,
  clicks the real buttons, changes the files and the set from outside and asserts what is visible: the rendered
  text, that every mark covers exactly its target, the cards beside their text, a reply, a new comment from a
  selection, a thread of an agent's and the reader's replies, a mermaid diagram drawn as a picture, coloured code,
  hiding the sidebar, switching files, the scroll position. Needs a desktop session. `FOLIO_SNAPSHOT=<base>` saves pictures
  (`<base>-before.png`, `<base>-thread.png` with a focused card and its replies, `<base>-sidebar-hidden.png`,
  `<base>-after.png`).
- **CI** (`.github/workflows/windows.yml`) runs `verify.sh` on `windows-2025` for a pull request (and on `main`)
  that changes `windows/**`, `frontend/**` (the diagram page) or the workflow. It uploads the result and pictures
  as the `windows-selftest` artifact, and on a pull request from this repository puts the pictures in a comment
  ("Self-test pictures (windows)", from the `ci-pictures-windows` branch), updated on every push.

On Linux or macOS the WPF project can be compiled (`EnableWindowsTargeting`) but not run, and needs
Microsoft's .NET 8 SDK: distribution builds of the SDK leave out the WindowsDesktop targets. The unit tests
need only the Core project:

```bash
cargo rustc --release --lib --crate-type cdylib --target-dir target/cdylib && cargo build
FOLIO_CLI=$PWD/target/debug/folio FOLIO_CONFIG_DIR=$(mktemp -d) dotnet test windows/Folio.Core.Tests
```
