# Folio Sidecar Specification

## Overview

A Folio sidecar is a local JSON file that stores all annotations for a markdown document. It lives alongside the source file and is never committed or shared — it is a personal review workspace.

The markdown source stays clean at all times. Suggestions, comments, highlights, and flags are held exclusively in the sidecar. When a suggestion is accepted, the change is written back to the source file and the sidecar entry is marked resolved.

---

## File Convention

The sidecar lives in the same directory as its markdown file and takes the source filename as a prefix:

```
document.md
document.md.folio
```

The `.folio` extension is reserved for this format. The sidecar is excluded from version control — add `*.folio` to `.gitignore`.

---

## Top-Level Structure

```json
{
  "version": 1,
  "annotations": []
}
```

| Field         | Type    | Required | Description                              |
|---------------|---------|----------|------------------------------------------|
| `version`     | integer | yes      | Schema version. Currently `1`.           |
| `annotations` | array   | yes      | Ordered list of annotation objects.      |

---

## Annotation Object

Every annotation, regardless of kind or source, shares a common envelope:

```json
{
  "id":             "ann_lf4k2a9x",
  "kind":           "replace",
  "source":         "agent",
  "author":         "claude",
  "context_before": "limits are stored in Redis and shared across",
  "target":         "all gateway replicas",
  "replacement":    "all gateway replicas and survive restarts",
  "comment":        "The original omitted restart durability, which is a key property.",
  "created":        "2026-05-29T10:00:00Z",
  "resolved":       false,
  "replies": [
    {
      "id":      "reply-1748908800000",
      "author":  "me",
      "source":  "local",
      "body":    "Good catch — I'll check with the infra team first.",
      "created": "2026-06-01T08:00:00Z"
    }
  ]
}
```

### Common Fields

| Field            | Type    | Required | Description |
|------------------|---------|----------|-------------|
| `id`             | string  | yes      | Unique identifier. Prefix `ann_` followed by a random alphanumeric string. |
| `kind`           | string  | yes      | One of `replace`, `delete`, `insert`, `comment`, `highlight`. See below. |
| `source`         | string  | yes      | Origin of the annotation. One of `local`, `agent`, `github`, `gitlab`. |
| `author`         | string  | yes      | Display name of the author. `"me"` for local annotations. |
| `context_before` | string  | yes      | The verbatim text immediately preceding the target in the source. Used for anchoring. Minimum 20 characters where possible. |
| `target`         | string  | kind-dependent | The exact text in the source that this annotation refers to. Required for `replace`, `delete`, `highlight`. Null for `insert` and `comment`. |
| `replacement`    | string  | kind-dependent | The proposed replacement text. Required for `replace` and `insert`. Null otherwise. |
| `comment`        | string  | no       | Human-readable rationale or review note. Optional for all kinds. |
| `created`        | string  | yes      | ISO 8601 timestamp. |
| `resolved`       | boolean | yes      | `false` while pending. `true` once accepted, rejected, or dismissed. |
| `resolved_as`    | string  | no       | Set on resolution. One of `accepted`, `rejected`, `resolved`, `dismissed`. |
| `resolved_at`    | string  | no       | ISO 8601 timestamp set on resolution. |
| `replies`        | array   | no       | Ordered list of `ThreadReply` objects. Omitted from JSON when empty. |

---

## ThreadReply Object

Each annotation can accumulate follow-up discussion in its `replies` array. A reply is not an annotation — it has no anchoring, kind, or resolution state. It is purely a message attached to an existing annotation.

```json
{
  "id":      "reply-1748908800000",
  "author":  "me",
  "source":  "local",
  "body":    "Good catch — I'll check with the infra team first.",
  "created": "2026-06-01T08:00:00Z"
}
```

| Field     | Type   | Required | Description |
|-----------|--------|----------|-------------|
| `id`      | string | yes      | Unique identifier. Use a `reply-` prefix followed by a timestamp or random string. |
| `author`  | string | yes      | Display name. `"me"` for replies written by the local user. |
| `source`  | string | yes      | Origin: `local`, `agent`, `github`, or `gitlab`. |
| `body`    | string | yes      | The reply text. |
| `created` | string | yes      | ISO 8601 timestamp. |

Replies are displayed in order below the annotation card body. The local user can add replies via the in-card reply form; agents can pre-populate `replies` when writing an annotation.

---

## Annotation Kinds

### `replace`

Proposes substituting one phrase for another. Both `target` and `replacement` are required.

```json
{
  "kind":           "replace",
  "context_before": "failed auth attempts return ",
  "target":         "a 403 status code",
  "replacement":    "a 401 status code",
  "comment":        "401 is semantically correct for missing credentials."
}
```

**Accept:** finds `context_before + target` in the source, replaces `target` with `replacement`.
**Reject:** no source change. Entry marked `resolved: true, resolved_as: "rejected"`.

---

### `delete`

Proposes removing text entirely. `target` is required. `replacement` is null.

```json
{
  "kind":           "delete",
  "context_before": "expand to the full service mesh",
  "target":         " over the following quarter",
  "comment":        "Timeline belongs in the project plan, not the spec."
}
```

**Accept:** finds and removes `target` from the source.
**Reject:** no source change.

---

### `insert`

Proposes inserting new text after a context anchor. `target` is null. `replacement` holds the text to insert.

```json
{
  "kind":           "insert",
  "context_before": "- Per-client rate limiting, configurable per route",
  "target":         null,
  "replacement":    "\n- Circuit breaking with configurable error thresholds per upstream",
  "comment":        "Circuit breaking is a standard gateway concern."
}
```

**Accept:** finds `context_before` in the source, inserts `replacement` immediately after it.
**Reject:** no source change.

---

### `comment`

A review note anchored to a paragraph. No source change on accept or reject — only resolution state changes.

```json
{
  "kind":           "comment",
  "context_before": "JWT verification happens once at the edge",
  "target":         null,
  "replacement":    null,
  "comment":        "Should we support mTLS for internal service calls?"
}
```

**Resolve:** marks the entry resolved. Nothing written to the source.
**Delete:** removes the entry from the sidecar.

---

### `highlight`

Flags a specific span of text for attention. `target` is required. `replacement` is null.

```json
{
  "kind":           "highlight",
  "context_before": "The default limit is ",
  "target":         "1 000 req/min per API key",
  "comment":        "Confirm with the platform team before publishing."
}
```

Rendered as an amber highlight in the preview. Accept/reject behaviour same as `comment`.

---

## Anchoring

Annotations are anchored to their position in the source using `context_before` and `target` rather than line numbers or character offsets. Line numbers break on any edit above the annotation; context strings are resilient to surrounding changes.

**Matching algorithm:**

1. Concatenate `context_before + target` into a search string.
2. Case-insensitive search — first against raw markdown bytes, then (if that fails) against inline-stripped plain text (bold/italic/code markers removed, list/heading markers removed from line starts). This means producers may write plain rendered text in `context_before` and `target` without markdown syntax.
3. If found, the target span begins at `indexOf(context_before) + len(context_before)`.
4. If not found with exact concat, a single space is tried between `context_before` and `target`.
5. If still not found, the annotation is shown as unresolvable in the UI (the source has diverged).

**Guidelines for producers:**

- `context_before` should be at least 20 characters and end at a natural word boundary.
- Avoid using the very start or end of the document as context — there is nothing before or after to disambiguate.
- If `target` appears multiple times in the document, extend `context_before` until the combination is unique.

---

## Sources

The `source` field identifies where an annotation came from. This determines visual treatment in the UI and is the extension point for external integrations.

| Source    | Colour | Description |
|-----------|--------|-------------|
| `local`   | blue   | Written by the user via the Folio UI |
| `agent`   | green  | Written by an AI agent via the sidecar API |
| `github`  | amber  | Imported from a GitHub pull request review |
| `gitlab`  | amber  | Imported from a GitLab merge request |

External source annotations (`github`, `gitlab`) are read-only in the current version — they can be resolved or deleted but not edited.

---

## Agent Write Path

An agent appends to the `annotations` array. It does not need to read or merge the existing sidecar — it generates new entries with unique IDs and appends them.

Minimal agent payload:

```json
{
  "id":             "ann_<unique>",
  "kind":           "replace",
  "source":         "agent",
  "author":         "claude",
  "context_before": "<verbatim text before the target>",
  "target":         "<exact text to change>",
  "replacement":    "<proposed replacement>",
  "comment":        "<rationale>",
  "created":        "<ISO 8601 timestamp>",
  "resolved":       false
}
```

The agent must not modify `resolved`, `resolved_as`, or `resolved_at` on existing entries.

Agents may include a `replies` array when writing a new annotation to pre-populate the thread, or omit it entirely (the field defaults to empty).

---

## External Source Import (Future)

GitHub PR and GitLab MR comments will be imported as sidecar annotations by a separate import step, not by Folio itself. The importer is responsible for:

- Mapping PR comment body to `comment`
- Mapping the diff hunk to `context_before` + `target`
- Setting `source` to `"github"` or `"gitlab"`
- Setting `author` to the reviewer's username

Folio treats imported annotations identically to agent annotations for rendering purposes, distinguished only by the `source` field.

PR review comment threads map naturally to `replies`: the top-level review comment becomes the annotation `comment` field, and subsequent replies in the thread map to `ThreadReply` objects with `source: "github"` or `source: "gitlab"`.

---

## Versioning

The `version` field is reserved for future breaking changes to this schema. Folio will refuse to open a sidecar with an unrecognised version number and will display an error rather than silently misreading it.

Current version: **1**.
