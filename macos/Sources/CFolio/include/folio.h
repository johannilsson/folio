#ifndef FOLIO_H
#define FOLIO_H

#include <stdbool.h>
#include <stddef.h>

/* All functions return a heap string owned by the caller: free it with folio_free.
   Failures are reported as a JSON object {"error": "..."}. */

/* Same items/response JSON as POST /api/anchor (raw=false) and /api/anchor-raw (raw=true).
   doc is the markdown when raw, else the preview's rendered text. char_from/char_to are UTF-16 offsets into doc. */
char *folio_anchor(const char *doc, const char *items_json, bool raw);

/* The words a selection of the markdown (from..to, UTF-16 offsets) is anchored by, as rendered text:
   {"target", "context_before"}, or {} when none of the selection is rendered text. */
char *folio_rendered_selection(const char *doc, size_t from, size_t to);

/* {"doc": <patched markdown or null>, "sidecar": <sidecar JSON as the CLI writes it>} */
char *folio_accept(const char *doc, const char *sidecar_json, const char *id);

/* Applies one editor action to a sidecar: {"op": "resolve" | "restore" | "add_comment" | "remove" |
   "reply" | "edit_comment", ...} (src/edit.rs).
   {"sidecar": <sidecar JSON as the CLI writes it>, "id": <id of the new annotation or reply, or null>} */
char *folio_edit(const char *sidecar_json, const char *edit_json);

/* <git root or file's folder>/.folio/<relative path>.folio, as a plain string. */
char *folio_sidecar_path(const char *file);

/* Sets: the named lists of files kept in ~/.config/folio/sets, shared with `folio set`. */

/* {"names": ["a", "b"]} */
char *folio_set_names(void);

/* {"name", "manifest": <path of the set's JSON file>, "files": [{id, name, group, path, folio_path}]} */
char *folio_set_load(const char *name);

/* files_json is an array of paths; root may be NULL. Creates the set if needed.
   {"added": [...], "already": [...]} */
char *folio_set_add(const char *name, const char *files_json, const char *root);

/* {"removed": [...]}; fails for a path that is not in the set. */
char *folio_set_remove(const char *name, const char *files_json);

/* Deletes the set's manifest, never the files. {} */
char *folio_set_delete(const char *name);

/* The MCP server and the link between it and the running app (src/mcp.rs, src/live.rs). */

/* Runs the MCP server on stdin and stdout until the client closes them (`Folio --mcp`, started by Claude
   desktop). Returns the exit code. */
int folio_mcp_serve(void);

/* Answers one request of the MCP server about the running app: JSON in, JSON out. The result is malloc'ed;
   the library frees it. Called on a thread of the library's. */
typedef char *(*folio_app_handler)(const char *request_json);

/* Starts answering the MCP server on <config>/app.sock. {} or {"error": "..."} (another Folio already answers). */
char *folio_app_listen(folio_app_handler handler);

/* Takes the socket away; the app is quitting. */
void folio_app_stop(void);

/* The ways to register `<exe> --mcp` by hand in other tools (Claude Code, Cursor and others):
   {"snippets": [{"name", "hint", "text"}]} */
char *folio_mcp_snippets(const char *exe);

/* Registers `<exe> --mcp` as the "folio" server in a tool's config; `client` is "claude" (Claude desktop)
   or "codex". {"config": <path>, "change": "added" | "updated" | "unchanged"} */
char *folio_mcp_connect(const char *client, const char *exe);

void folio_free(char *ptr);

#endif
