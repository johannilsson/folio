# Folio for macOS

A native markdown editor and review tool: AppKit windows (one per markdown file, via `NSDocument`)
whose preview and source editor are `NSTextView`s. `frontend/dist` holds one page, which a hidden
`WKWebView` loads at `folio://app/` to draw mermaid diagrams and colour code.
The Rust core (anchoring, accept) is linked as `libfolio.a`.

## Run

```bash
(cd frontend && pnpm build)   # the bundle the app serves
cargo build --release         # libfolio.a
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
cargo build                                                  # the `folio` CLI the test drives
swift build --package-path macos
swift test --package-path macos                              # FolioKit's unit tests, no windows
macos/.build/debug/Folio --self-test macos/selftest.md       # exits 0 when every check passes
```

## More

- [Development](../docs/development.md): the self-test, pictures (`FOLIO_SNAPSHOT`), the README screenshot.
- [The macOS app](../docs/architecture/macos-app.md): how the app is put together.
- [Sets](../docs/guides/sets.md), [MCP](../docs/mcp.md) and [PlantUML](../docs/guides/plantuml.md): using the app.
