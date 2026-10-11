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

## Test

```bash
FOLIO_SKIP_FRONTEND_BUILD=1 cargo build                      # the `folio` CLI the test drives
swift build --package-path macos
macos/.build/debug/Folio --self-test macos/selftest.md       # exits 0 when every check passes
```

The self-test works on throwaway copies: it types, undoes, copies and pastes through the
Edit menu, annotates with the CLI, accepts in both editor modes, replaces the file from
outside, and opens a second window. `FOLIO_SNAPSHOT=<png>` saves a picture of the window.
`FOLIO_CLI` points it at a different `folio` binary.
