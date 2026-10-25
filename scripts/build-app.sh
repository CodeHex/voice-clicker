#!/usr/bin/env bash
# Builds build/Voice Clicker.app from the Swift package.
#
#   ./scripts/build-app.sh            # ad-hoc signed
#   VERSION=1.2.0 ./scripts/build-app.sh
#   CODESIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/build-app.sh
#
# With no identity given, the first "Apple Development" certificate in your
# keychain is used, or else an ad-hoc signature pinned to the bundle ID. Either
# way, macOS permissions survive rebuilds.
#
# The version is VERSION, or else the latest vX.Y.Z git tag, or else the one in
# Resources/Info.plist. A local build is then never older than the release it
# was built from, so the update check doesn't replace it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Voice Clicker.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VoiceClicker" "$APP/Contents/MacOS/VoiceClicker"
cp Resources/Info.plist "$APP/Contents/Info.plist"

VERSION="${VERSION:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null | sed 's/^v//' || true)}"
if [[ -n "$VERSION" ]]; then
  if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must look like 1.2.3, got '$VERSION'" >&2
    exit 1
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi

# Prefer a real signing identity: use CODESIGN_IDENTITY, or else the first
# "Apple Development" certificate in the keychain.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi

if [[ -n "$IDENTITY" ]]; then
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  # Ad-hoc signing. By default macOS ties permission grants to the exact
  # build's hash, so every rebuild would lose Input Monitoring and
  # Accessibility. Pinning the designated requirement to the bundle ID makes
  # the grants survive rebuilds.
  codesign --force --options runtime --sign - \
    -r='designated => identifier "com.codehex.VoiceClicker"' "$APP"
  echo "Signed ad-hoc (permissions keyed to bundle ID com.codehex.VoiceClicker)"
fi
echo "Built $APP ($(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist"))"
