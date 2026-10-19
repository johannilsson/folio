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

void folio_free(char *ptr);

#endif
