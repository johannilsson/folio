#!/usr/bin/env bash
# Registers the "natural-wine" sample set (demo.md plus the two files next to this
# script) and seeds a few annotations so the sidebar shows pending badges.
#
#   demo-set/setup.sh && target/debug/folio open --set natural-wine
#
# Set FOLIO_CONFIG_DIR to keep the set out of ~/.config/folio, FOLIO to use another
# binary. Annotations are only seeded for files that have no sidecar yet.
set -euo pipefail
cd "$(dirname "$0")/.."

FOLIO=${FOLIO:-$PWD/target/debug/folio}
SET=natural-wine

"$FOLIO" set add "$SET" demo.md demo-set/producers.md demo-set/tasting-notes.md

annotate() { "$FOLIO" annotate "$@" >/dev/null; }

if [[ ! -e .folio/demo-set/producers.md.folio ]]; then
  annotate demo-set/producers.md --kind replace --author claude --source agent \
    --context-before "buried clay vessels lined with beeswax, for around " \
    --target "6,000 years" --replacement "8,000 years" \
    --comment "Archaeological finds put qvevri winemaking at roughly 6000 BC, so about 8,000 years."
  annotate demo-set/producers.md --kind highlight --author claude --source agent \
    --context-before "Chenin Blanc in particular shows what " \
    --target "low-intervention farming"
  annotate demo-set/producers.md --kind comment --author me --source local \
    --context-before "Two bottles from the same village can taste " \
    --target "nothing alike" \
    --comment "Worth an example here, maybe two Jura growers side by side."
fi

if [[ ! -e .folio/demo-set/tasting-notes.md.folio ]]; then
  annotate demo-set/tasting-notes.md --kind delete --author claude --source agent \
    --context-before "Give the glass a " --target "really " \
    --comment "Filler word."
  annotate demo-set/tasting-notes.md --kind insert --author claude --source agent \
    --context-before "Write down what you notice before you read the label." \
    --replacement " Blind tasting makes the label's story much harder to taste." \
    --comment "Explains why the order matters."
fi

echo
echo "Set ready. Start it with:  $FOLIO serve --set $SET"
