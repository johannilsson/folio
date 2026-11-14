# Sets

A set is a named list of markdown files from any folders, reviewed together in one window.

- Sets are kept in `~/.config/folio/sets/` (`FOLIO_CONFIG_DIR` moves the folder).
- The CLI and the app share them: `folio set add/rm/list`.
- In the app, a set opens in a window with a sidebar of its files beside the editor. The files are grouped by repo and branch, with a badge for unresolved annotations.

## In the app

- **File ▸ Open Set** lists the sets. **New Set…** asks for a name and the files to start with.
- **Change the list** with:
  - **Add Files to Set…** (File menu, or the + under the sidebar);
  - **Remove from Set** (File menu, or a file's context menu);
  - **Delete Set…** (File menu).

  Only the list changes; files and their annotations are never deleted. A set keeps at least one file.
- **Reorder repos** by dragging a repo heading in the sidebar. That repo's files move up or down, and the order is saved in the set.
- **Terminal changes show up.** Changes made with `folio set` in a terminal appear in an open window within a second.

## From the command line

| Command | What it does |
|---|---|
| `folio set add <set> <file>…` | Adds files (creating the set). |
| `folio set add <set> --folder <dir>` | Adds a folder of notes ([wiki mode](../features/wiki-mode.md)). |
| `folio set rm <set> <file or folder>` | Takes one out again. |
| `folio set list` | Lists the sets. |
| `folio set tags <set> --add blocked:red` | Adds an open-item tag. A new set starts with `#investigate`, `#waiting` and `#replied`. |
| `folio open --set <name>` | Opens a set in the app (it sends `folio://set/<name>`). |

## Worktrees

The same file in a checkout and in its worktree is two entries, one under each repo-and-branch heading. Each has its own annotations, because each worktree has its own `.folio/`.

## An example set

`examples/natural-wine/setup.sh` registers the `natural-wine` set and seeds a few annotations. It is the set in the README's screenshot.
