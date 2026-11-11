#!/usr/bin/env bash
# Drives the real app with its --self-test and prints what it found. Needs a desktop session, so Windows only
# (windows/verify.sh runs it there). FOLIO_CLI names the CLI the self-test annotates with.
cd "$(dirname "$0")/.."
app=windows/Folio.Wpf/bin/Debug/net8.0-windows/Folio.Wpf.exe
result=windows/selftest-result.txt
rm -f "$result"
export FOLIO_SNAPSHOT="${FOLIO_SNAPSHOT:-windows/snapshots/folio}"

"$app" --self-test "$result"
code=$?
cat "$result" 2>/dev/null || echo "✗ the app wrote no result (exit code $code)"
exit $code
