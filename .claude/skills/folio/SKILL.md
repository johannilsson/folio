---
name: folio
description: >
  Write annotations to a Folio sidecar file (.folio) for a markdown document.
  Use this skill whenever an agent needs to review a markdown file and produce
  structured feedback, suggestions, edits, or comments — including proofreading,
  editing, code review, content critique, or any task that involves marking up
  a document for a human to review. Trigger on phrases like "annotate this",
  "review and suggest changes", "add comments to", "mark up this document",
  "leave feedback on", "proofread", or whenever the user asks an agent to work
  with a .folio file or a Folio-managed document. Also use it to group several
  markdown files into a named Folio set ("folio set", "review these files
  together", "put these in one folio session") that is served and reviewed
  together.
---

# Working with Folio

Folio is a local markdown editor with an AI annotation system. Your job as an agent is to read a `.md` file and write structured annotations to its `.folio` sidecar — a JSON file that lives alongside the markdown. A human reviews your annotations in the Folio browser UI or via CLI.

**The golden rule: never modify the `.md` file.** All feedback, suggestions, and edits go into the `.folio` sidecar only.

---

## Workflow

1. Read the `.md` file and understand the content
2. Run `folio check <file.md>` to confirm the sidecar path — the output shows the exact `.folio` path the tool will read and write
3. Run `folio render <file.md>` to see the exact plain text the anchoring engine uses — derive all `context_before` and `target` values from this output, not from the raw markdown source
4. Read the sidecar at the path shown by `folio check` — if it doesn't exist, start with `{"version": 1, "annotations": []}`
5. Build your annotation objects and append them to the `annotations` array
6. Write the full updated sidecar back to the same path
7. Run `folio accept <file.md> --all --source agent --dry-run` to verify every annotation anchors. If any fail, re-check the `folio render` output and fix the offending `context_before`/`target` values before finishing.

---

## Sidecar format

The sidecar is a JSON file inside the `.folio/` directory at the project root, mirroring the `.md` file's path:

```
docs/README.md  →  .folio/docs/README.md.folio
report.md       →  .folio/report.md.folio
```

Run `folio check <file.md>` to see the exact resolved path. Never write to an adjacent `<document>.folio` — that location is not read by any Folio command.

```json
{
  "version": 1,
  "annotations": [
    {
      "id": "ann_k7mxpq2r",
      "kind": "replace",
      "source": "agent",
      "author": "your-agent-name",
      "context_before": "the 50–100 chars of plain rendered text immediately before the target",
      "target": "the exact text to act on",
      "replacement": "new text (for replace/insert kinds)",
      "comment": "optional human-readable explanation",
      "created": "2026-06-01T12:00:00Z",
      "resolved": false
    }
  ]
}
```

Always set `source` to `"agent"` and `resolved` to `false`.

---

## Annotation kinds

| kind | `target` | `replacement` | meaning |
|---|---|---|---|
| `replace` | required | required | Suggest replacing `target` with `replacement` |
| `delete` | required | — | Suggest deleting `target` |
| `insert` | — | required | Suggest inserting `replacement` after `context_before` |
| `comment` | — | — | Attach a note after `context_before` (use `comment` field) |
| `highlight` | required | — | Flag `target` for the reviewer's attention |

---

## Anchoring — the most important part

Folio finds your annotation by searching for `context_before + target` in the document's plain rendered text. Getting this right is what makes annotations work.

### Rule 1: Use plain rendered text — no markdown syntax

Write `context_before` and `target` as the text looks to a reader, not as it appears in the raw source. Strip all markdown syntax: heading markers, bold/italic delimiters, list markers, backticks.

```
## Introduction                  →  context_before: "Introduction"                  ✓
**bold word**                    →  target: "bold word"                             ✓
`inline code`                    →  target: "inline code"                           ✓
[REF-001](other-doc.md)          →  target: "REF-001"                              ✓

## Introduction                  →  context_before: "## Introduction"               ✗
**bold word**                    →  target: "**bold word**"                         ✗
`inline code`                    →  target: "`inline code`"                         ✗
[REF-001](other-doc.md)          →  target: "[REF-001](other-doc.md)"              ✗
```

The anchoring engine strips markdown from the document before searching, so your plain-text context and target will match even if the document contains heavy formatting.

### Rule 2: Block boundaries are invisible — concatenate directly

In the rendered (stripped) view, newlines and block markers disappear. When `context_before` ends in one block and the target starts in the next, join them with no separator:

```json
{
  "context_before": "End of first paragraph.Start of ",
  "target": "second paragraph"
}
```

A heading followed by a bullet works the same way — just use the heading text directly as context:

```json
{
  "context_before": "Introduction",
  "target": "First bullet text"
}
```

Do not add `\n`, `\n\n`, or block markers at the boundary.

### Rule 3: Use enough context

`context_before` should be approximately 50–100 characters of plain text immediately preceding the target. Short context risks false matches if the same phrase appears elsewhere in the document. Longer is safer.

---

## IDs and timestamps

- **ID**: `ann_` followed by 8 lowercase alphanumeric characters. Must be unique within the sidecar. Example: `ann_k7mxpq2r`
- **Timestamp**: ISO 8601 UTC. Example: `2026-06-01T12:34:56Z`

Generate IDs by combining random characters from `a-z0-9`. Check existing annotation IDs to avoid collisions.

---

## Verification (CLI)

After writing the sidecar, verify with the `folio` CLI:

```bash
# Show the exact plain-text view the anchoring engine uses
# Use this BEFORE writing annotations to derive correct context_before/target values
folio render <file.md>

# Create an empty sidecar (if one doesn't exist yet)
folio init <file.md>

# Check sidecar is valid JSON and schema is correct
folio check <file.md>

# Append a single annotation without editing JSON directly
folio annotate <file.md> --kind replace --context-before "rendered text before" --target "old text" --replacement "new text" [--comment "explanation"] [--author your-name] [--source agent]
folio annotate <file.md> --kind comment --context-before "rendered text before" --comment "your note"
folio annotate <file.md> --kind insert --context-before "rendered text before" --replacement "text to insert"

# List pending annotations (optionally filter by kind or source)
folio review <file.md> [--kind replace] [--source agent] [--json]

# Preview what accept would do without changing files
folio accept <file.md> --all --source agent --dry-run

# Accept and apply annotations (writes changes to the .md file)
folio accept <file.md> --all --source agent

# Reject annotations without applying them
folio reject <file.md> --all --source agent
```

If `folio check` fails, your sidecar JSON is malformed. If `folio accept --dry-run` reports that an annotation failed to anchor, run `folio render <file.md>` and compare its output against your `context_before`/`target` — the rendered text is the ground truth.

---

## Sets: several files in one Folio session

A set is a named list of markdown files, possibly from different repositories, that one `folio serve` process shows together: the filename pill in the editor becomes a menu of the set's files with pending-annotation counts. Create a set when the user wants related files reviewed together. Annotating works as described above, file by file.

```bash
# Create the set (or extend it); paths may be relative, they are stored absolute
folio set add <name> <file.md> [<file.md>...]

# Keep sidecars somewhere other than the file's git root (applies to the files in this call)
folio set add <name> <file.md> --root <dir>

folio set list                    # all sets
folio set list <name>             # files in a set: id, path and resolved sidecar root
folio set rm <name> <file.md>...  # remove files from a set
folio set rm <name>               # delete the whole set

folio serve --set <name>          # serve the set instead of a single file
```

Sets live in `~/.config/folio/sets/<name>.json` (`FOLIO_CONFIG_DIR` overrides the directory). Names may use letters, digits, `-`, `_` and `.`. A running server does not pick up changes to a set, so it has to be restarted. Starting `folio serve` is the user's call, so give them the command rather than launching it.

### Sidecars of files in a set

The server reads each file's sidecar from `<root>/.folio/<path relative to root>.folio`, where `root` is the file's git root (its own directory if it is not in a git repo) or the `--root` given at `set add`. `folio set list <name>` prints the resolved root for every file.

The per-file commands (`check`, `render`, `annotate`, `review`, `accept`, `reject`, `init`) resolve the sidecar from the **current directory**, so run them from the file's root:

```bash
cd <root shown by folio set list> && folio annotate docs/spec.md --kind comment --context-before "..." --comment "..."
```

Running them from anywhere else writes a sidecar that the set never reads. Confirm the location with `folio check <file.md>`: the sidecar path it reports (in its error when no sidecar exists yet) should be `<root>/.folio/...`.

---

## HTTP API (when `folio serve` is running)

If the user has started the Folio server, you can use the HTTP API instead of reading/writing files directly:

```bash
# Read the markdown file
curl http://localhost:<port>/api/file

# Read the current sidecar
curl http://localhost:<port>/api/folio

# Write a new sidecar (send full JSON body)
curl -X PUT http://localhost:<port>/api/folio \
  -H "Content-Type: application/json" \
  -d @updated.folio
```

If the server was started with `--token <secret>`, add `-H "Authorization: Bearer <secret>"` to every request.

When the server was started with `--set`, `/api/file`, `/api/folio` and the other file-scoped endpoints take `?file=<id>`; without it they act on the set's first file. `curl http://localhost:<port>/api/files` lists every file with its `id`, `name`, `group` and `pending` count.

---

## Common mistakes

**Including markdown syntax in `context_before` or `target`**
The anchoring engine works on plain rendered text. If you write `"**word**"` in `target` but the rendered text is just `"word"`, the annotation will fail to anchor. Always strip `**`, `#`, backticks, list markers, and other markdown syntax.

**Adding newlines at block boundaries**
The stripped view has no newlines between blocks — they are concatenated directly. Writing `"context_before": "heading text\n\n"` will not match. Use `"heading text"` (or `"heading textFirst word of next block"` if you need to bridge the gap).

**Table cell context includes pipes and padding spaces**
The CLI anchoring engine (`folio render`) preserves table pipes and the space-padding that aligns columns. Copy `context_before` and `target` exactly from `folio render` output — including the pipes and spaces — rather than guessing at clean cell text. Example: to target `"Lactic bacteria producing THP; irreversible"` in a table row, `context_before` might be `"Mousiness                         | Fault             | "`.

**Inline link syntax in `context_before` or `target`**
Write only the visible link text, not the markdown `[text](url)` wrapper. `folio render` shows `REF-001` for a `[REF-001](other-doc.md)` link; use that. Writing the raw brackets and URL will cause `folio accept --dry-run` to fail to anchor the annotation.

**Unescaped backslashes in JSON string values**
Backslashes in text (e.g., in inline code or LaTeX) must be doubled inside JSON strings: `\\` not `\`. A single unescaped backslash is invalid JSON and will make `folio check` fail. Similarly, backtick characters in markdown source (`\``) are just `` ` `` in the rendered text — write them as a literal backtick in the JSON value, not as `\``.

**Short `context_before` on repeated phrases**
If "the" appears 50 times in the document, `context_before: "the"` will anchor to the first one. Use a long, unique slice of text.
