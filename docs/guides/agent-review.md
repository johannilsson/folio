# Reviewing with an agent

1. **Ask your agent to review a file.** For example: *"Review docs/spec.md for clarity and annotate it with Folio."* The agent reads the markdown and writes annotations to its sidecar. It never edits the `.md` itself.
2. **Open the document** in the app (`folio open docs/spec.md`). Annotations appear as highlights in the text and as cards in the comments pane. They update live while the agent works.
3. **Triage.**
   - Accept a replacement, deletion or insertion to apply it to the file.
   - Reject one to discard it.
   - Dismiss a comment.
   - Reply on any card to start a thread.
4. **Hand it back.** Replies and resolved annotations are stored in the same sidecar, so the agent can read your answers and continue where you left off. `folio changes` (or the MCP tool `annotations_since`) lists what changed since a given time.

## Teaching the agent

This repository ships a Claude Code skill, [`.claude/skills/folio`](../../.claude/skills/folio/SKILL.md). It teaches an agent the whole workflow:

- how to find the sidecar;
- how to anchor annotations to the right text;
- how to check its own work;
- how to work with sets and open items.

Copy it into `~/.claude/skills/` to use it in any project.

Any other agent can follow the [sidecar format](../reference/sidecar-format.md) directly, since it is plain JSON. Or connect it over [MCP](../mcp.md).

## The command line

`folio review`, `accept`, `reject`, `annotate`, `changes`, `check`, `link`, `items` and `refs` work on the same annotations from scripts, CI or an agent, on any platform. `folio --help` lists everything.
