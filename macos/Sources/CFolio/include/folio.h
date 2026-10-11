#ifndef FOLIO_H
#define FOLIO_H

#include <stdbool.h>

/* All functions return a heap string owned by the caller: free it with folio_free.
   Failures are reported as a JSON object {"error": "..."}. */

/* Same request/response JSON as POST /api/anchor (raw=false) and /api/anchor-raw (raw=true). */
char *folio_anchor(const char *doc, const char *items_json, bool raw);

/* {"doc": <patched markdown or null>, "sidecar": <sidecar JSON as the CLI writes it>} */
char *folio_accept(const char *doc, const char *sidecar_json, const char *id);

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
