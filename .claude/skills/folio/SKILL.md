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
  with a .folio file or a Folio-managed document.
---

# Working with Folio

Folio is a local markdown editor with an AI annotation system. Your job as an agent is to read a `.md` file and write structured annotations to its `.folio` sidecar — a JSON file that lives alongside the markdown. A human reviews your annotations in the Folio browser UI or via CLI.

**The golden rule: never modify the `.md` file.** All feedback, suggestions, and edits go into the `.folio` sidecar only.

---

## Workflow

1. Read the `.md` file and understand the content
2. Read `<file>.folio` — if it doesn't exist, start with `{"version": 1, "annotations": []}`
3. Build your annotation objects and append them to the `annotations` array
4. Write the full updated sidecar back to `<file>.folio`

---

## Sidecar format

The sidecar is a JSON file at `<document>.folio` (same directory as the `.md`):

```json
{
  "version": 1,
  "annotations": [
    {
      "id": "ann_k7mxpq2r",
      "kind": "replace",
      "source": "agent",
      "author": "your-agent-name",
      "context_before": "the 50–100 chars of raw markdown immediately before the target",
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

Folio finds your annotation in the document by searching for `context_before + target` as a single concatenated string in the raw markdown source. Getting this right is what makes annotations work.

### Rule 1: Use raw markdown, exactly as it appears in the file

The search runs directly on the raw markdown source text. Include all markdown syntax characters — `**`, `#`, backticks, etc. — exactly as they appear in the file.

```
## Introduction         →  context_before: "## Introduction"   ✓
**bold word**           →  target: "**bold word**"              ✓
`inline code`           →  target: "`inline code`"              ✓

## Introduction         →  context_before: "Introduction"       ✗
**bold word**           →  target: "bold word"                  ✗
```

Copy the text verbatim from the `.md` file — do not render or strip it.

### Rule 2: Block boundaries use newlines

In the raw markdown source, paragraphs and headings are separated by `\n` (one or two). Include these newlines in `context_before` when crossing a block boundary.

If your target is at the start of a new block, let `context_before` end with the newline(s) from the file:

```json
{
  "context_before": "ends here.\n\n",
  "target": "Next paragraph"
}
```

### Rule 3: Use enough context

`context_before` should be approximately 50–100 characters of raw markdown immediately preceding the target. Short context risks false matches if the same phrase appears elsewhere in the document. Longer is safer.

---

## IDs and timestamps

- **ID**: `ann_` followed by 8 lowercase alphanumeric characters. Must be unique within the sidecar. Example: `ann_k7mxpq2r`
- **Timestamp**: ISO 8601 UTC. Example: `2026-06-01T12:34:56Z`

Generate IDs by combining random characters from `a-z0-9`. Check existing annotation IDs to avoid collisions.

---

## Verification (CLI)

After writing the sidecar, you can verify with the `folio` CLI:

```bash
# Check sidecar is valid JSON and schema is correct
folio check <file.md>

# List pending annotations (optionally filter by kind or source)
folio review <file.md> [--kind replace] [--source agent] [--json]

# Preview what accept would do without changing files
folio accept <file.md> --all --source agent --dry-run
```

If `folio check` fails, your sidecar JSON is malformed. If `folio accept --dry-run` shows unexpected byte offsets, your `context_before` or `target` likely contains markdown syntax or is missing text across a block boundary.

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

---

## Common mistakes

**Stripping markdown from `context_before` or `target`**
The anchoring search runs on raw markdown source. `**word**` in the sidecar must exactly match `**word**` in the file. Do not strip `**`, `#`, backticks, or other markdown syntax.

**Missing newlines at block boundaries**
The most common cause of failed anchors. If your target is at the start of a paragraph or heading, `context_before` must include the `\n` (or `\n\n`) that precedes it in the file. Test with `folio accept --dry-run` if you're unsure.

**Short `context_before` on repeated phrases**
If "the" appears 50 times in the document, `context_before: "the"` will anchor to the first one. Use a long, unique slice of text.
