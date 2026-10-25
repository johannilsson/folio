#!/usr/bin/env bash
# Registers the "natural-wine" set (the three files next to this script) and seeds a few
# annotations so the sidebar shows pending badges.
#
#   docs/natural-wine/setup.sh && target/debug/folio open --set natural-wine
#
# Set FOLIO_CONFIG_DIR to keep the set out of ~/.config/folio, FOLIO to use another
# binary. Annotations are only seeded for files that have no sidecar yet.
set -euo pipefail
here=$PWD
cd "$(dirname "$0")"

FOLIO=${FOLIO:-$here/target/debug/folio}
SET=natural-wine

# Where the sidecar of a file here lives: under the git root if there is one, else in this folder.
root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
rel=${PWD#"$root"}
rel=${rel#/}
sidecar() { echo "$root/.folio/${rel:+$rel/}$1.folio"; }

"$FOLIO" set add "$SET" guide.md producers.md tasting-notes.md

annotate() { "$FOLIO" annotate "$@" >/dev/null; }

if [[ ! -e $(sidecar producers.md) ]]; then
  annotate producers.md --kind replace --author claude --source agent \
    --context-before "buried clay vessels lined with beeswax, for around " \
    --target "6,000 years" --replacement "8,000 years" \
    --comment "Archaeological finds put qvevri winemaking at roughly 6000 BC, so about 8,000 years."
  annotate producers.md --kind highlight --author claude --source agent \
    --context-before "Chenin Blanc in particular shows what " \
    --target "low-intervention farming"
  annotate producers.md --kind comment --author me --source local \
    --context-before "Two bottles from the same village can taste " \
    --target "nothing alike" \
    --comment "Worth an example here, maybe two Jura growers side by side."
fi

if [[ ! -e $(sidecar tasting-notes.md) ]]; then
  annotate tasting-notes.md --kind delete --author claude --source agent \
    --context-before "Give the glass a " --target "really " \
    --comment "Filler word."
  annotate tasting-notes.md --kind insert --author claude --source agent \
    --context-before "Write down what you notice before you read the label." \
    --replacement " Blind tasting makes the label's story much harder to taste." \
    --comment "Explains why the order matters."
fi

echo
echo "Set ready. Start it with:  $FOLIO open --set $SET"
