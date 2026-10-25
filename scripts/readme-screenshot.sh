#!/usr/bin/env bash
# Retakes docs/screenshot.png: the macOS app showing the natural-wine set.
# It works on a throwaway copy of the set with a temporary config, so none of your own sets
# or annotations end up in the picture. Needs a logged-in macOS desktop session.
# Usage: scripts/readme-screenshot.sh [--dark] [output.png]
set -euo pipefail
cd "$(dirname "$0")/.."

appearance=light
out=docs/screenshot.png
for arg in "$@"; do
  case $arg in
    --dark) appearance=dark ;;
    *) out=$arg ;;
  esac
done

[[ -f frontend/dist/diagram.html ]] || (cd frontend && pnpm build)
cargo build            # the `folio` CLI that seeds the annotations
cargo build --release  # libfolio.a, which the app links
swift build --package-path macos

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# A repo marker, so sidecars land where the app looks for them.
mkdir -p "$work/repo/.git"
cp docs/natural-wine/*.md docs/natural-wine/setup.sh "$work/repo/"
(cd "$work/repo" && FOLIO_CONFIG_DIR="$work/config" FOLIO="$OLDPWD/target/debug/folio" ./setup.sh >/dev/null)

FOLIO_CONFIG_DIR="$work/config" macos/.build/debug/Folio \
  --set natural-wine --screenshot "$work/shot.png" --appearance "$appearance"
sips -Z 2000 "$work/shot.png" --out "$out" >/dev/null
echo "wrote $out"
