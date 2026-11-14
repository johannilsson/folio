## Guiding Principles

Apply these principles during every step execution to keep changes focused and side-effect-free.

1. **Think Before Coding** — Before editing any file, fully understand the current state and the intended change. Read the relevant code first; never edit speculatively.
2. **Simplicity First** — Implement the simplest change that satisfies the step. Do not over-engineer, add abstractions, or introduce patterns beyond what the step requires.
3. **Surgical Changes** — Touch only the code the step calls for. Do not refactor nearby code, add unrelated improvements, update comments/docs you weren't asked to change, or "clean up while you're here."
4. **Goal-Driven Execution** — Every edit must trace back to the plan's stated goal. If a change isn't required by the current step, don't make it.

## Project

Folio is a local markdown editor and annotation review tool for macOS. Agents write annotations to a `.folio` sidecar file (with the CLI or over MCP); humans review them in the native app (`macos/`, Swift, AppKit). The Rust crate (`src/`) is the CLI and the engine (anchoring, accept, sets) that the app links as a static library. `frontend/` is only a hidden page that draws diagrams and colours code. There is no browser or server mode.

**Core constraint:** the markdown source file is always clean. Annotations live only in the `.folio` sidecar, never in the `.md` file.

## Build and test

```bash
cd frontend && pnpm install && pnpm build                 # the diagram page the app reads (frontend/dist)
cargo build && cargo test                                 # CLI and Rust unit tests
cargo build --release && swift build --package-path macos # the app links a *release* libfolio.a
swift test --package-path macos                           # FolioKit unit tests, no desktop session
macos/.build/debug/Folio --self-test macos/selftest.md    # the real app (needs a desktop session)
./scripts/verify.sh                                       # everything (--skip-macos to leave the app out)
```

A stale `libfolio.a` shows up only as a bare "linker command failed" from `swift build`: rebuild it with `cargo build --release`.

## Rules that always apply

- The engine (`sidecar.rs`, `edit.rs`, `accept.rs`, `changes.rs`, `location.rs`) uses only itself: no CLI, MCP, sets, config folder or processes.
- Anchoring and accept run in Rust (through `Rust.swift` → `ffi.rs`); never reimplement them in Swift.
- Swift has three layers, each calling only the one below:
  - the engine (Rust);
  - the logic (FolioKit: values in, values out, no views);
  - the UI (applies decisions, does not make them).

  A rule you can say in a sentence is a function in FolioKit, with a unit test.
- One owner per piece of state; the disk is the truth (read, modify and write through libfolio).
- Add no singletons, `NotificationCenter` broadcasts, or protocols for mocking.
- Agents' `context_before` and `target` are rendered text, with no separator between blocks.
- Never edit generated files (`Tokens.swift`, `tokens.ts`): edit `design/tokens.json` and run `node scripts/tokens.mjs`.
- Add a test for new behaviour, in the layer where the rule lives, instead of a throwaway script.
- For UI changes:
  - run `./scripts/verify.sh`;
  - assert what is visible, and look at the pictures (`FOLIO_SNAPSHOT=<base>`);
  - when you open a PR that changes what the app looks like, add the `pictures` label.
- When a change alters behaviour or structure, update its page in `docs/` in the same change.

## Read before you work on…

Read only the pages for the area you are changing. Each lists the types, the rules, and the pitfalls learned the hard way.

| When you touch | Read |
|---|---|
| Any Swift in `macos/` | [docs/architecture/app-layers.md](docs/architecture/app-layers.md): where code goes and how it is tested |
| Rust modules, the CLI (`src/commands/`), the frontend, design tokens | [docs/architecture/overview.md](docs/architecture/overview.md) |
| Windows, `FolioDocument`, `Workspace`, FolioKit, the source editor, scrolling, the set window and toolbar, recents | [docs/architecture/macos-app.md](docs/architecture/macos-app.md) |
| The preview (`Preview/`, `PreviewBuilder`, `PreviewText`, `DiagramPage`) | [docs/architecture/preview.md](docs/architecture/preview.md) |
| Cards, the comments pane, focus, the Comment button, undo of annotation actions | [docs/architecture/annotation-ui.md](docs/architecture/annotation-ui.md), and [docs/features/inline-comments.md](docs/features/inline-comments.md) for inline cards |
| Sets, the sidebar, wiki folders, `folio://` and `[[…]]` links, open items, the Open pane | [docs/features/wiki-mode.md](docs/features/wiki-mode.md) and the wiki section of [macos-app.md](docs/architecture/macos-app.md#wiki-mode) |
| MCP (`src/mcp.rs`, `src/live.rs`, `AppServer.swift`) | [docs/mcp.md](docs/mcp.md) |
| The sidecar format, anchoring rules | [docs/reference/sidecar-format.md](docs/reference/sidecar-format.md) |
| Tests, the self-test, pictures, the README screenshot | [docs/development.md](docs/development.md) |
| Something that looks odd and may be on purpose | [docs/decisions.md](docs/decisions.md) |
| The docs themselves | [docs/README.md](docs/README.md): where a page goes, how to link |

New knowledge (a pitfall, a decision, how a part works) goes on the page in `docs/` where it belongs, not in this file.
