# Wiki mode

While reviewing, people keep a wiki next to the documents: notes on requirements, threat models
and documentation, things to investigate, and questions they asked in a pull or merge request and
are waiting on. Today that lives in Obsidian, whose file tree and pages miss changes made outside
it (an agent writing a note) until a hard reload, which makes it unreliable for this.

This adds that wiki to a set: a folder of markdown, shown in the sidebar and kept current, with
links into Folio's own things (a passage, an annotation) that work in both directions, and the
open items collected from it into one list. Folio does not become a wiki editor: the files stay
plain markdown that Obsidian or GitHub read as before, and writing happens in the source editor.

Mockups: https://claude.ai/artifact/G6LuZR84WQLPiBDDrY5tyV (1: the wiki in the set, 2: links and
backlinks on a card, 3: the Open list).

## Behaviour

### 1. A wiki folder in the set

- A set can hold folders as well as files: `folio set add <set> --folder ~/wiki/payments`, then
  `folio open --set <set>`. Its markdown files are listed as a tree under the folder's name, after
  the set's other files. `folio set rm <set> <folder>` takes it out again; its files cannot be
  removed from the set one by one.
- Clicking a subfolder, or the folder's heading, folds its files away (its chevron points right)
  and clicking it again unfolds them. Folding is the window's, not saved. A page opened in a folded folder, by a link or
  an open item, unfolds it; folding the folder of the page on screen keeps the page.
- The tree is current: a file added, renamed or removed underneath (by the agent, by Obsidian, by
  `git pull`) shows within a second, without a reload. A file that changed since the reader last
  looked at it gets a dot; a file that is new since the window opened gets a NEW tag. A short
  notice at the bottom of the sidebar says what changed ("rotation-options.md added,
  requirements.md changed · just now"). The open file reloads as it does today.
- Only `.md` files are shown. Folders starting with a dot (`.git`, `.obsidian`, `.folio`) and
  `node_modules` are skipped.
- Wiki files are documents like any other: preview, source, annotations.

### Files under review, by repo and branch

- The files picked for the set (`folio set add`, `folio open`) are grouped by **repo and branch**,
  not by the folder they are in: *PAYMENTS-SVC · main*, *PAYMENTS-SVC · fix/logout · worktree*.
  Each group lists paths relative to its root (`docs/token-refresh.md`).
- The same file in two worktrees is two entries, one per group, each with its own annotations
  (each worktree has its own `.folio/`, which is git-ignored). The window's subtitle says when the
  open file is also in another group ("also on fix/logout").
- The repo is named after the `origin` remote's last path segment, without `.git`; with no remote,
  after the main checkout's folder. The branch is the worktree's `HEAD`; a detached `HEAD` shows
  its short commit. A file outside any repo is grouped by its folder, as today.
- Two repos with the same name get enough of their path to tell them apart.

### 2. Links

Two kinds, both plain markdown links, so the files read the same outside Folio:

- **Wiki links**: `[[requirements]]`, `[[requirements#R4]]`, `[[research/rotation-options]]`, as
  Obsidian writes them: a name resolves to the shortest unique path in the wiki folder, `#` to a
  heading.
- **Folio links** are the `folio://` links `folio link` already writes, which also name the repo,
  branch and path (the absolute `file` stays as a fallback):
  - an annotation: `folio://annotation/c3d4?repo=payments-svc&branch=main&path=docs/token-refresh.md&file=…`
  - a passage: `folio://passage?repo=payments-svc&branch=main&path=docs/token-refresh.md&file=…&q=rotate%20on%20every%20use`,
    anchored with the engine like an annotation (`before=` is added when `q` alone is not unique).

  A link names repo and branch and the file's path in that checkout, never a worktree's folder:
  folders come and go, the wiki outlives them. Without `branch`, any checkout of the repo has it.
  An older link has only `file`, and still works.
- `folio link <file> <id>` / `--passage <text> [--before <words>]` prints the link; with `--markdown`
  a whole link whose text is the author and the start of the comment (or the passage):
  `[Priya: “Does rotation alone cover a token copied…”](folio://…)`, so the wiki still reads once the
  target is gone. The agent writes links with it.
- In the preview, a `[[wiki link]]` shows what it names (its alias, else the name and heading, without
  the brackets) in the link colour; a link to an annotation or a passage is a purple chip showing the
  link's own text. Clicking a live one opens the page in the set window, or the file with the
  annotation focused or the passage selected.
- A link whose target is gone is grey, with a dotted underline, says why when the mouse rests on it,
  and does nothing when clicked. It goes live again, without a reload, when the target comes back (a
  page added to the wiki, a branch checked out):
  - "fix/logout isn't checked out any more": no open checkout is on that branch. Its
    annotations went with the worktree.
  - "docs/t.md isn't in this checkout": the branch is open, without that file.
  - "“missing” isn't in the wiki": no page by that name in the set's folders.
  - "payments-svc isn't in an open set": no open window has the repo.
  - "Not found in token-refresh.md": the file is there, but the annotation was resolved or deleted, or
    its text or the passage was edited away (read from the file and its sidecar, anchored as the app
    anchors). Checked again when any open file or sidecar changes.
  Not yet: "Add to Set" on a repo that is not open.

### Backlinks

- An annotation's card gets a **Referenced in** section: each wiki page that links to it, with the
  heading the link is under (else its line). Clicking one opens the page with the words of the link
  selected.
- A card with references and no focus shows only their count ("1 reference"). The cards in the text
  (View ▸ Comments Inline) are the same cards; a collapsed one counts them beside its header with its
  replies ("· 2 replies · 1 reference · 1 open").
- A link to an annotation is by its id; a link to a passage is on the cards of the annotations whose
  text it overlaps, and nowhere else (no marks in the text for now). Only links to the file on
  screen count, by repo, branch and path as for following a link: the copy on another branch has
  its own.
- The list follows the pages: a link added to or taken out of a page, a page added or removed, shows
  on the card without a reload.

### Between a document and the wiki

Backlinks above are per annotation. A reviewer also wants to go from the document under review to
every wiki page about it, and from a wiki page to the document, without an annotation in between.

- **Wiki → document**: a third Folio link, to the file as a whole:
  `folio://document?repo=payments-svc&branch=main&path=docs/token-refresh.md&file=…`.
  `folio link <file>` (no id, no `--passage`) prints it; with `--markdown` its text is the file's
  name. In the preview it is a chip like the other Folio links; clicking it opens the file in the
  set window. Dead as the others are ("fix/logout isn't checked out any more", "docs/t.md isn't
  in this checkout"); a document link has no "Not found in …".
- **Document → wiki**: the file on screen gets a **Referenced in** list for the whole file: every
  page of the set with a link to the document, to a passage of it or to one of its annotations,
  with the heading or line the link is under, grouped by page. It sits at the top of the comments
  pane, above the first card, and folds to "Referenced in 3 pages" (the count also shows in the
  window's subtitle while the pane is closed). Clicking a row opens the page with the link's words
  selected, as a backlink does. A passage link that overlaps no annotation shows here and only here
  (today it shows nowhere). Matched by repo, branch and path, as backlinks are; it follows the
  pages without a reload.
- A wiki page is a file of the set like any other, so the list works for it too: a page linked
  from another page lists that one. `[[wiki links]]` count for wiki pages (they name a page, not a
  document under review).
- `folio refs <file> --set <name> [--json]` prints the same list for the agent: page, line,
  heading and what the link points at (`the document`, `annotation <id>`, `passage “…”`).
- Not yet: marks in the text for passage links; an open item linking to the document (not an
  annotation) counting as "about" it in the Open pane's "This file".

### 3. Open items

- A task item in any file of the set with one of three tags is an open item:
  ```
  - [ ] Token refresh on logout from a second device #investigate
  - [ ] Key rotation: asked in review #waiting https://github.com/…/pull/42#issuecomment-981 [Priya](folio:…#c3d4)
  - [ ] Key rotation: asked in review #replied https://github.com/…/pull/42#issuecomment-981
    - Sam: the family is revoked by the gateway since v3 (https://github.com/…#issuecomment-990)
  ```
  Other task items are not collected; ticked ones (`- [x]`) are done and not shown.
- **Open** is a row above the files in the sidebar, with the count, while the set has any open items.
  Choosing it shows the list in place of the editor (the subtitle says "Open items"); choosing a
  file goes back. The list is grouped by tag (Replied, Waiting, Investigate) or by file. Each row
  shows its text, the first nested line under it (an answer's summary), the file and line it is in,
  a short form of its address ("github.com · pull/42") and, when it has one, a
  chip for the annotation or passage it is about. Clicking the file and line opens the file with the
  start of the item's words selected; clicking the address or the chip follows it. Only web
  addresses and links into Folio open.
- **The Open pane** (mockup board 5) is the same items in the window's inspector, at the right beside the
  editor and its comments pane, so both can be open at once. As in Xcode, the toolbar is divided over it:
  its button, with the set's count, is at the trailing edge, and the editor's buttons stay over the editor.
  View ▸ Toggle Open Items (⇧⌘O) opens it too. It is 272 points wide and can be dragged shut. It lists the whole set by tag
  until the reader picks "This file", the items whose Folio link points at the file on screen; a purple
  dot marks an item about an annotation of that file. A row is compact: the box, the words, then the file
  and line and the short address; clicking it opens the file with the item's words selected. The list in
  place of the editor stays for grouping by file, the answers' lines and following the addresses.
- Ticking an item reads its file again, checks the item is still on that line, and writes `[x]`
  through libfolio (the disk is the truth: an item that moved is not ticked, the list reads the
  file again instead). The count and the list follow the files without a reload.
- `folio items <file>… | --set <name> [--tag <tag>] [--json]` prints the same items for the agent.
- An item with a Folio link to an annotation also shows on that annotation's card, under **Open**,
  with its box (ticking it there writes the file as in the list); a card not in focus counts them
  with the references ("1 reference · 1 open"). Only links to an annotation count, not links to a
  passage.
- An item whose Folio link is dead stays in the list, marked as the link is ("fix/logout isn't
  checked out any more"). Closing it is the reader's call.

### Waiting items and the agent

Folio does not talk to GitHub or GitLab. The agent, which has `gh` and `glab`, checks waiting
items when asked (or on a schedule): for each `#waiting` item with a pull or merge request URL, it
reads the thread, and when someone replied after the question it changes the tag to `#replied` and
adds a nested line with who replied, a one-line summary and the reply's link. The reader sees the
change at once (the file and the Open list are current) and ticks the item when the question is
settled. The skill (`.claude/skills/folio`) gets this convention, so it works the same from Claude
Code and over MCP.

## How it is built

Follows "How the app is built" in `CLAUDE.md`. The engine (`sidecar.rs`, `edit.rs`, `accept.rs`,
`location.rs`) gains only the repo-and-branch lookup; links and items are desktop code.

### Rust

- `location.rs`: `repo_identity(root) -> { repo, branch }`, read from files only (no `git`
  process): a `.git` file's `gitdir:` leads to the worktree's `HEAD` and, through `commondir`, to
  the shared `config` and its `origin` URL. Unit tests for a checkout, a worktree, a detached
  `HEAD`, no remote, no repo.
- `set.rs`: a set gets `folders: Vec<SetFolder>` (`path`). A set file with folders is version 2,
  so an older Folio refuses it rather than saving it without its folders; one without stays 1.
  `scan_folder` lists a folder's markdown files in tree order; loading the set lists them again. `describe` groups by
  `repo_identity` instead of the root's folder name. `folio set add --folder`, `folio open --folder`.
- `wiki.rs` (new, desktop side): parsing `[[…]]` and `folio:` links and open items out of markdown,
  resolving a wiki name to a path, and the link's text for `folio link`. Values in, values out, unit
  tested. Through `ffi.rs` to the app; `folio link` and `folio items` (open items as JSON, for the
  agent) in `commands/`.

### App

- **The folder tree** belongs to the window controller beside the set's files (one owner, see
  `CLAUDE.md` 3). It is rescanned on a timer (polling, like `Document`; a folder of a few hundred
  files is cheap to list), and the sidebar redraws from it. Changed and new files are worked out by
  comparing scans (a function in FolioKit with unit tests); "changed since the reader looked" by
  modification times against when the file was last shown.
- **Links and backlinks** come from parsing every wiki file of the set again when it changes;
  the result (who links to which annotation or passage) is a value the `AnnotationController`
  reads to fill the card's sections. Rendering links and chips is `PreviewBuilder`'s, with a new
  attribute key for a link's target.
- **Open items** are parsed the same way from every file of the set; ticking writes through
  `Document.writeFile` against what is on disk.
- **The sidebar** gets the Open row and the Wiki section; `SidebarViewController` keeps drawing
  from the window controller's state.

## Tests

- **Unit** (Rust): `repo_identity`, set version 2 and folders, link and item parsing, wiki name
  resolution, link text.
- **Unit** (FolioKit): comparing two scans of a folder (added, removed, renamed, changed).
- **Self-test**: a set with a wiki folder; a file added, renamed and removed underneath shows in
  the sidebar within a second; the open file reloads; clicking a Folio link opens the file and
  focuses the annotation; a card lists the wiki file that links to it; an item ticked in the Open
  list is `[x]` on disk; a link to a branch no worktree is on is greyed out.
- **Pictures** (`FOLIO_SNAPSHOT`): the sidebar with a wiki, a card with references, the Open list,
  light and dark. The PR gets the `pictures` label.

## Steps

1. A set backed by folders: `set.rs` folders and version 2, `--folder`, the folder's tree in the
   sidebar, kept current, the changed/new marks and the notice (`SidebarTree` in FolioKit).
   Self-test for files changing underneath (`SelfTest+Wiki.swift`). Not yet: Add Folder to Set… in
   the app, and `folio open --folder`.
2. Groups by repo and branch: `repo_identity` in `location.rs`, `describe` grouping by it, headings
   such as "payments-svc · fix/logout · worktree" (`SidebarTree.headings`, which also tells apart
   two clones on one branch by the end of their path), and the subtitle "also on …"
   (`SidebarTree.subtitle`). The set is read again twice a second, so a `git checkout` in a worktree
   changes its heading. Self-test: `worktreeScenario`.
3. Links:
   - `folio link` with repo, branch and path, `--passage`, `--markdown` (`link.rs`); the app follows
     `folio://annotation` and `folio://passage` links by repo, branch and path (`FolioLink`,
     `AppServer.open`), selects a passage, and says when a branch is gone or the file is not in it.
   - `[[wikilinks]]` (`WikiLinks`: finding them in text, naming the page by the end of its path, the
     shortest path winning), drawn by `PreviewBuilder` with the other links into Folio, dead ones grey
     (`linkState`, asked by the window, which knows what is open), and `PreviewView.refreshLinks`
     redrawing them when a page or a branch comes or goes. Self-tests in `wikiScenario` and
     `worktreeScenario`.
   - `[[name#heading]]` opens the page with the heading selected.
   - "Not found in …" for an annotation resolved or deleted or a passage edited away
     (`FolioLink.targetFound`, asked by `AppServer.deadReason`; `AppServer.refreshLinks` when a file or
     sidecar changes). Self-test in `backlinkScenario`.
4. Backlinks on cards: `WikiReferences` (the `folio://` links in a page, with the heading or line
   they are under and their words) and `FolioLink.points(to:)` in FolioKit; the set window reads
   each page (again when it changes), works out which annotations of the file on screen each link
   is to (`SetWindowController.computeBacklinks`), and the card draws the count or the list
   (`AnnotationCardView.references`). Self-test: `backlinkScenario`.
5. Open items:
   - Done: `wiki.rs` (parsing and ticking, with `folio_open_items` / `folio_tick_item` for the app),
     `folio items`, `OpenList` (grouping) in FolioKit, the Open row, `OpenListView`, ticking.
     Self-test: `openItemsScenario`.
   - The Open pane (`OpenPaneView`, the split view's inspector, `SetWindowController.openPaneOn` and `openScope`;
     which items are about the file on screen is `OpenList.about` / `paneRows` in FolioKit). Self-test:
     `cardItemsScenario`.
   - Items on the cards of the annotations they link to (`AnnotationCardView.items`,
     `SetWindowController.computeCardItems`). Self-test: `cardItemsScenario`.
6. The skill's convention for waiting items: done (`.claude/skills/folio/SKILL.md`, "Open items").
7. `CLAUDE.md` and the README: done.
8. Between a document and the wiki:
   - Done: `folio://document` links (`folio link <file>`, `document_url` in `link.rs`), parsing
     Folio links and the pages' references in Rust (`wiki::FolioLink`, `wiki::references`,
     `FolioLink::points_to`, the same rule as `FolioLink.points(to:)` in the app), and
     `folio refs` (`commands/refs.rs`). Unit tests for parsing, matching and a set's pages.
   - Not yet (app): `FolioLink.Target.document` in FolioKit, `WikiReferences` finding
     `folio://document`, following and greying it (`AppServer.open`, `linkState`), the
     Referenced in list (`SetWindowController.computeBacklinks` keeping every link to the file, not
     only those on an annotation; a header view in the comments pane), the subtitle count.
     Self-test in `backlinkScenario`; a picture of the pane with the list.

## Open questions

- When the agent last checked the waiting items ("checked by Claude 10 min ago" in mockup 3): it
  needs to be written somewhere that is not the wiki's text. Left out until there is a place.
- Should the review groups also list, unasked, every file in the repo with open annotations (the
  sidecars are all under `<root>/.folio/`)? It would make "where is there something to answer"
  one look.
- Carrying a worktree's unresolved annotations to main before it is removed
  (`folio carry --from <worktree> --to main`, re-anchored by the engine).
- Registering `folio:` as a URL scheme, so a Folio link clicked in Obsidian opens Folio.

## Not in this change

- Editing in the preview (writing is in the source editor, as today).
- Search across the wiki, quick open, graph view, plugins, sync.
- Folio talking to GitHub or GitLab itself.
- Sidecars kept outside the worktree.
