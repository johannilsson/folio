# Folio for Windows (experimental)

How far a minimal Windows client gets on the Rust engine. It is an experiment: kept apart from the
product, checked by its own workflow, and not part of `./scripts/verify.sh` or the required `test` check.

What it does: opens a markdown file, shows its text with the annotations marked, and a card for each
pending one with Accept / Reject (Dismiss for a comment). It follows the file and its `.folio` sidecar on
disk, so what an agent writes with the CLI shows up. What it does not do: no rendered preview or diagrams
(the text is the source), no new comments or replies, no undo, no sets, no installer.

## Layers

The same three as the macOS app (CLAUDE.md, "How the app is built"):

- **Engine**: `folio.dll`, the Rust crate built as a `cdylib` (`cargo rustc --release --lib --crate-type
  cdylib`; not a crate type in `Cargo.toml`). The C API is `src/ffi.rs`.
- **`Folio.Core`** (plain .NET, no UI): `Native`/`Engine` call the DLL; `Sidecar` is the model; `Review.Place`
  (what is shown and where) and `Lines` (offset to line and column) are the rules as functions; `ReviewFile`
  is the file and sidecar on disk, changed only through the engine. Runs on any OS, so it is tested on Linux.
- **`Folio.Wpf`**: the window. It draws from the disk state and applies what `Folio.Core` decides.
  `--self-test` drives it (below).

## Checks

```bash
windows/verify.sh      # engine DLL + CLI, build, unit tests; on Windows also the app's self-test
```

- **`Folio.Core.Tests`** (xunit) run the real engine library and the real CLI on throwaway files: UTF-16
  offsets, accept with CRLF, reject/dismiss, an agent's write surviving an action. `FOLIO_CLI` names the CLI
  (`verify.sh` sets it).
- **`Folio.Wpf.exe --self-test <result file>`** opens a CRLF file annotated by the CLI, clicks the real buttons,
  changes the files from outside and asserts what is visible: the text, that every mark covers exactly its
  target, the cards, the scroll position. Needs a desktop session. `FOLIO_SNAPSHOT=<base>` saves pictures
  (`<base>-before.png`, `<base>-after.png`).
- **CI** (`.github/workflows/windows.yml`) runs `verify.sh` on `windows-2025`, only when `windows/**` or the
  workflow changes, and uploads the result and pictures as the `windows-selftest` artifact.

On Linux or macOS the WPF project can be compiled (`EnableWindowsTargeting`) but not run, and needs
Microsoft's .NET 8 SDK: distribution builds of the SDK leave out the WindowsDesktop targets. The unit tests
need only the Core project.
