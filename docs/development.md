# Development

## Build

```bash
# Frontend: the diagram page the app loads
cd frontend && pnpm install && pnpm build

# Rust CLI
cargo build

# macOS app: needs the frontend build (the app reads frontend/dist) and a *release* libfolio.a (the app links it).
cargo build --release && swift build --package-path macos
macos/scripts/bundle.sh   # -> macos/build/Folio.app (ad-hoc signed)
```

To run the app without bundling it:

```bash
swift run --package-path macos Folio notes.md
```

`FOLIO_SIGN_IDENTITY` selects a signing identity other than ad hoc. `folio open notes.md` starts the installed app; `FOLIO_APP=<path to .app>` points it at an uninstalled build.

**A stale `libfolio.a`** shows up only as a bare "linker command failed" from `swift build`. Run `cargo build --release` again.

## Tests

```bash
cargo test                                               # Rust unit tests (anchoring, strip_markdown, sets, wiki, MCP)
swift test --package-path macos                          # FolioKit's unit tests, no desktop session needed
macos/.build/debug/Folio --self-test macos/selftest.md   # the real app against throwaway copies and the real CLI; needs a desktop session
./scripts/verify.sh                                      # everything; --skip-macos leaves the app out
./scripts/verify.sh --changed                            # only what the files changed since origin/main can affect
macos/.build/debug/Folio --self-test --only wiki,sets macos/selftest.md   # only some areas of the self-test
```

### Running less

- **`--only <areas>`** runs the checks that open the first window, then only the named areas of the self-test: `preview`, `source`, `scrolling`, `annotations`, `inline`, `windows`, `sets`, `wiki`, `items`, `welcome`. Without it every area runs. An unknown name exits with the list.
- **`verify.sh --changed [<base>]`** looks at `git diff` against `<base>` (default `origin/main`) and picks the steps, and the self-test areas. The map is the `case` in the script: docs only runs just the token check, `src/` runs the Rust steps and the areas that use the engine, FolioKit only runs the unit tests, a `SelfTest+<area>.swift` or `Preview/` file runs its area. Any file the map does not name, and a base it cannot find, run everything.
- **CI** uses `--changed` for a pull request, and everything on `main` and for a pull request with the `pictures` label. What a narrowed run misses (a change in one area breaking a check of another) is caught on `main`.
- The first window's areas run in order on one document. If an area fails alone and passes in the full run, it relies on one before it: run both.

Which kind of test a rule gets depends on its layer ([where Swift code goes](architecture/app-layers.md), rule 8):

- **A logic or layout rule** gets a unit test in `macos/Tests/FolioKitTests/`.
- **Wiring** gets a self-test check: windows, focus, files changing underneath, the CLI and MCP against the live app.

Add a test for new behaviour instead of writing a throwaway script.

### The self-test

`macos/Sources/Folio/SelfTest/`: `SelfTest.swift` has the run order and the helpers, and the `SelfTest+<area>.swift` extensions hold the checks. It works on throwaway copies:

- it types in the source, undoes, and copies and pastes through the Edit menu;
- it annotates with the CLI and accepts in both modes (the source editor included: typing, formatting, marks, undo, Find, drag-scroll);
- it replaces the file from outside and opens a second window;
- it starts the app's binary with `--mcp` and talks to it over its pipes, as Claude Desktop does (`SelfTest+MCP.swift`).

`FOLIO_CLI` points it at a different `folio` binary. It exits 0 when every check passes.

## Look at the result

Passing tests have not been enough here:

- Source-mode typing "worked" while the editor was hidden.
- A sidebar refresh bounced the page to the first file, with every check green.

For UI changes, assert what is visible, and look at a picture of the result. The preview and the source are both text views, so there is no DOM to assert on: check the text view's state and look at the pictures.

- **Pictures.** `FOLIO_SNAPSHOT=<base>` makes the self-test save pictures of the whole window: `<base>-cards.png`, `-menu.png`, `-floater.png`, `-form.png`, and more for newer features (`-inline-preview.png`, …).
- **The `pictures` label.** CI takes the pictures only for a pull request with the `pictures` label, and shows them on the PR. Add the label when a change touches what the app looks like.
- **Run `./scripts/verify.sh`** after UI changes, to confirm them in the real app.

## README screenshot

`docs/images/screenshot.png` (and `screenshot-dark.png`, for dark mode) show the `natural-wine` set from `examples/natural-wine/`.

- `scripts/readme-screenshot.sh` retakes the light one from a clean copy of the set.
- `scripts/readme-screenshot.sh --dark docs/images/screenshot-dark.png` retakes the dark one.
- The app photographs itself: `Folio --set <name> --screenshot <png> [--appearance light|dark]`.

## Design tokens

Edit `design/tokens.json` and run `node scripts/tokens.mjs`. Never edit the generated `Tokens.swift` or `tokens.ts`. See [the overview](architecture/overview.md#design-tokens-designtokensjson).
