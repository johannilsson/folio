# Folio for macOS

A native shell around the same editor bundle the browser uses: AppKit windows (one per
markdown file, via `NSDocument`) hosting `frontend/dist` in a `WKWebView` at `folio://app/`.
The Rust core (anchoring, accept) is linked as `libfolio.a`. The bridge between page and
Swift is in [BRIDGE.md](BRIDGE.md).

## Run

```bash
(cd frontend && pnpm build)                      # the bundle the app serves
FOLIO_SKIP_FRONTEND_BUILD=1 cargo build --release  # libfolio.a
swift run --package-path macos Folio notes.md
```

## Build the .app

```bash
macos/scripts/bundle.sh        # -> macos/build/Folio.app (ad-hoc signed)
open macos/build/Folio.app
folio open notes.md            # from the CLI; FOLIO_APP=<path to .app> for an uninstalled build
```

`FOLIO_SIGN_IDENTITY` selects a signing identity other than ad hoc.

## Sets

A set is a named list of markdown files from any folders, kept in `~/.config/folio/sets`
and shared with `folio set add/rm/list`. In the app it opens in a window with a sidebar of
its files (grouped by repo, with a badge for unresolved annotations) beside the editor.

- **File > Open Set** lists the sets; **New Set…** asks for a name and the files to start with.
- **Add Files to Set…**, **Remove from Set** and **Delete Set…** (File menu, or the + / − under
  the sidebar and its context menu) change the list. Only the list changes; files and their
  annotations are never deleted. A set keeps at least one file.
- Changes made with `folio set` in a terminal appear in an open window within a second.
- `folio open --set <name>` opens a set from the CLI (it sends `folio://set/<name>` to the app).

## Test

```bash
FOLIO_SKIP_FRONTEND_BUILD=1 cargo build                      # the `folio` CLI the test drives
swift build --package-path macos
macos/.build/debug/Folio --self-test macos/selftest.md       # exits 0 when every check passes
```

The self-test works on throwaway copies: it types, undoes, copies and pastes through the
Edit menu, annotates with the CLI, accepts in both editor modes, replaces the file from
outside, and opens a second window. `FOLIO_SNAPSHOT=<base>` saves `<base>-cards.png`,
`-menu.png`, `-floater.png` and `-form.png`: pictures of the whole window with annotation
cards, the card menu, the Comment button and the comment form.
`FOLIO_CLI` points it at a different `folio` binary.

## README screenshot

`docs/screenshot.png` shows the `natural-wine` sample set (`demo-set/setup.sh` registers it).
`scripts/readme-screenshot.sh` retakes it from a clean copy of the set. The app photographs
itself: `Folio --set <name> --screenshot <png> [--appearance light|dark]`.
The README uses a plain markdown image, not a light/dark `<picture>`: raw HTML makes Folio's own
preview read-only, and the README should open editable.
