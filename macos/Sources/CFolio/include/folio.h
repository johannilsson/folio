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

void folio_free(char *ptr);

#endif
