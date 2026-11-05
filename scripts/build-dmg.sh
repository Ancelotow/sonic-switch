#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/SonicSwitch.app"
[[ -d "$APP_DIR" ]] || { print -u2 "Compile d’abord l’application avec scripts/build-app.sh."; exit 1; }
codesign --verify --strict "$APP_DIR"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 "Version invalide."; exit 1; }
ARCHS=$(lipo -archs "$APP_DIR/Contents/MacOS/SonicSwitch")
if [[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]]; then
    FLAVOR=universal
else
    FLAVOR="${ARCHS// /-}"
fi
STAGING_DIR=$(mktemp -d "${TMPDIR:-/tmp}/SonicSwitch-dmg.XXXXXX")
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_DIR" "$STAGING_DIR/SonicSwitch.app"
ln -s /Applications "$STAGING_DIR/Applications"
DMG="$PROJECT_DIR/dist/SonicSwitch-$VERSION-$FLAVOR.dmg"
hdiutil create -volname "SonicSwitch $VERSION" -srcfolder "$STAGING_DIR" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd "$PROJECT_DIR/dist" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
print "DMG prêt : $DMG"
