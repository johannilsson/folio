# Folio wiki

What we know about Folio: how to use it, how it is built, why it is built that way, and what is
still open. Start with the page for your question; each page links to the ones it builds on.

## Using Folio

- [Reviewing with an agent](guides/agent-review.md): the workflow, the skill, the CLI.
- [Sets](guides/sets.md): reviewing many files together, in the app and from the CLI.
- [Wiki mode](features/wiki-mode.md): a folder of notes in a set, links into Folio, open items.
- [Inline comments](features/inline-comments.md): cards in the text, collapsing them.
- [MCP](mcp.md): connecting Claude Desktop, Codex and other clients; the tools.
- [PlantUML](guides/plantuml.md): drawing `plantuml` blocks.

## Reference

- [Sidecar format](reference/sidecar-format.md): the `.folio` JSON that agents write.
- [MCP tools and the app socket](mcp.md#tools).

## How it is built

- [Overview](architecture/overview.md): the Rust engine and CLI, the frontend, design tokens.
- [The macOS app](architecture/macos-app.md): windows, FolioKit, the source editor, scrolling, wiki mode's types.
- [Where Swift code goes](architecture/app-layers.md): the three layers and how each is tested.
- [The native preview](architecture/preview.md).
- [The annotation UI](architecture/annotation-ui.md): cards, focus, anchoring, undo.
- [Decisions](decisions.md): choices that shape the code, and why.
- [Development](development.md): build, test, the self-test, pictures, the README screenshot.

## Keeping track

- [Drift reviews](drift-reviews/README.md): a weekly review of design drift and maintainability.
- Open questions are task items tagged `#investigate` on the page they belong to.
  `folio items docs/**/*.md` lists them, or open the wiki as a set (below) and choose **Open** in the sidebar.

## Reading it in Folio

This folder is a Folio wiki:

```bash
folio set add folio --folder docs && folio open --set folio
```

## How to write here

- **One topic per page**, under the folder that fits:
  - `guides/` for how to use a feature;
  - `reference/` for formats and protocols;
  - `architecture/` for how the code is put together;
  - `features/` for a feature's design and its build log.
- **Link with relative markdown links** (`[sets](guides/sets.md)`), not `[[wiki links]]`. They work on GitHub, in Folio's preview and for agents reading the files.
- **A feature page starts with its status**, then its behaviour, then how it is built and its steps.
- **Pitfalls go on the page of the area they bite.** Say what happened, so the rule isn't undone.
- **A decision with a reason** goes in [decisions](decisions.md).
- **Open questions are `- [ ] … #investigate` items**, so they show in Folio's Open list. Tick them when settled.
- **Knowledge goes here, not in `CLAUDE.md`.** `CLAUDE.md` keeps the rules that always apply and links here for the rest.
- **When a change alters behaviour, update its page** in the same pull request.
