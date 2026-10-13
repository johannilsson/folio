#!/usr/bin/env bash
# Builds macos/build/Folio.app: frontend bundle, Rust library, Swift shell, assembled and signed.
# Usage: macos/scripts/bundle.sh
# FOLIO_SIGN_IDENTITY picks the signing identity (default: ad hoc, which runs on this Mac only).
set -euo pipefail
cd "$(dirname "$0")/../.."

(cd frontend && pnpm build)
touch src/main.rs
FOLIO_SKIP_FRONTEND_BUILD=1 cargo build --release
# SwiftPM does not relink when only libfolio.a changed, which ships stale Rust code.
rm -f macos/.build/release/Folio
swift build -c release --package-path macos

app=macos/build/Folio.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/.build/release/Folio "$app/Contents/MacOS/Folio"
cp macos/Info.plist "$app/Contents/Info.plist"
cp -R frontend/dist "$app/Contents/Resources/dist"
cp macos/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign "${FOLIO_SIGN_IDENTITY:--}" "$app"

echo "built $app"
