#!/usr/bin/env bash
# Builds a signed (and, with a notary profile, notarized) DMG for distribution: macos/build/Folio-<version>.dmg.
# Usage: FOLIO_SIGN_IDENTITY="Developer ID Application: … (TEAMID)" macos/scripts/release.sh
# FOLIO_SIGN_IDENTITY must be a Developer ID identity; an ad-hoc signature only runs on the Mac that built it.
# FOLIO_NOTARY_PROFILE names a profile from `xcrun notarytool store-credentials`; without it the DMG is not notarized.
set -euo pipefail
cd "$(dirname "$0")/../.."

identity="${FOLIO_SIGN_IDENTITY:-}"
if [[ -z "$identity" || "$identity" == "-" ]]; then
  echo "set FOLIO_SIGN_IDENTITY to a Developer ID Application identity (security find-identity -v -p codesigning)" >&2
  exit 1
fi

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" macos/Info.plist)
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" macos/Info.plist)

macos/scripts/bundle.sh
app=macos/build/Folio.app
# Notarization needs the hardened runtime and a secure timestamp, which bundle.sh does not add.
codesign --force --options runtime --timestamp --sign "$identity" "$app"
codesign --verify --strict --verbose=2 "$app"

stage=macos/build/dmg
dmg=macos/build/Folio-$version.dmg
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
cp -R "$app" "$stage/"
ln -s /Applications "$stage/Applications"
hdiutil create -volname Folio -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
codesign --force --timestamp --sign "$identity" "$dmg"

if [[ -n "${FOLIO_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$FOLIO_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature --verbose "$dmg"
else
  echo "FOLIO_NOTARY_PROFILE not set: the DMG is signed but not notarized" >&2
fi

team=$(codesign -dv --verbose=4 "$dmg" 2>&1 | sed -n 's/^TeamIdentifier=//p')
echo "built $dmg (version $version, build $build, team $team)"
