# Decisions

Choices that shape the code, and why they were made. Add one when a choice would otherwise be
undone by someone who doesn't know the reason.

## The markdown file stays clean

Annotations live only in the `.folio` sidecar, never in the `.md` file. Accepting a suggestion is
the only thing that changes the markdown. So the document reads the same in any other tool, and
a review never leaves marks in the file.

## Sidecars live under the repo root, out of git

A sidecar is `<git root, else the file's folder>/.folio/<path>.folio`
([format](reference/sidecar-format.md#file-convention)). Every entry point (the CLI, MCP, sets,
the app) uses the one rule in `location.rs`, so they all read and write the same file. A review is
a personal workspace: `.folio/` is git-ignored. Each worktree has its own, so the same file on two
branches has two sets of annotations.

## Write through the engine, read the disk

The app and agents write the same sidecar at the same time. Every change is read, modified and
written through libfolio (`edit.rs`) against what is on disk, so an agent's concurrent writes
survive. Nothing in Swift trusts its copy in memory
([where Swift code goes](architecture/app-layers.md), rule 4).

## Anchor on rendered text

An annotation names its place by the text before it and the text itself, not by line numbers or
offsets, so it survives edits around it. The anchoring text is the rendered text, with no
separator between blocks, so an agent can copy from what it reads
([anchoring](architecture/annotation-ui.md#anchoring)).

## No browser or server mode

Folio is a native macOS app with a CLI. The only web view is a hidden page that draws diagrams
and colours code; the preview and the source editor are `NSTextView`s.

## Poll files instead of watching them

`Document` polls for changes (every 0.3 s) rather than using FSEvents or a vnode source.
Those follow an inode, and atomic saves (an editor, an agent, `git`) swap the inode, so a watcher
loses the file.

## The document has no undo manager

Undo belongs to the editors: the source's text view and the annotation actions. With a document
undo manager the window would answer Edit ▸ Undo itself and they would never get it
(`FolioDocument`).

## MCP is opt-in

The MCP server answers every tool with "access is off" until the person turns on Allow MCP
Clients ([MCP](mcp.md#allowing-access)). Setting up a client does not by itself give it access
to your files, and the switch can be turned off again at any time.
