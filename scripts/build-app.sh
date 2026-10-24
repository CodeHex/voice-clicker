#!/usr/bin/env bash
# Builds build/Voice Clicker.app from the Swift package.
#
#   ./scripts/build-app.sh            # ad-hoc signed
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build-app.sh
#
# Signing with a real identity keeps macOS permissions across rebuilds;
# an ad-hoc signature changes on every build, so permissions must be re-granted.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Voice Clicker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceClicker" "$APP/Contents/MacOS/VoiceClicker"
cp Resources/Info.plist "$APP/Contents/Info.plist"

codesign --force --options runtime --sign "${CODESIGN_IDENTITY:--}" "$APP"
echo "Built $APP"
