#!/bin/zsh
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Pass --arch arm64 --arch x86_64 to produce a universal application.
xcrun swift build -c release "$@"
BIN_DIR="$(xcrun swift build -c release --show-bin-path "$@")"
APP_DIR="$PROJECT_DIR/dist/SonicSwitch.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/SonicSwitch" "$APP_DIR/Contents/MacOS/SonicSwitch"
cp "$PROJECT_DIR/scripts/Info.plist" "$APP_DIR/Contents/Info.plist"
xcrun swift "$PROJECT_DIR/scripts/make-icon.swift" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - --identifier fr.local.SonicSwitch "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "SonicSwitch.app prête dans dist."
