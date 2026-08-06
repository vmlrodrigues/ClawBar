#!/usr/bin/env bash
# Builds ClawBar.app and signs it with a Developer ID identity.
#
#   ./Scripts/build.sh                 release build, signed
#   VERSION=0.2.0 BUILD=7 ./Scripts/build.sh
#   SIGN=0 ./Scripts/build.sh          skip signing (local testing only)
#
# Notarisation is a separate step — see Scripts/notarize.sh.

set -euo pipefail

APP_NAME="ClawBar"
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"
IDENTITY="${IDENTITY:-Developer ID Application: Victor Rodrigues (9N354A3UZK)}"
SIGN="${SIGN:-1}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

echo "==> Building $APP_NAME $VERSION ($BUILD)"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/$APP_NAME"
[ -x "$BIN" ] || { echo "error: no binary at $BIN" >&2; exit 1; }

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Info.plist already declares CFBundleIconFile; regenerate the .icns with
# `swift Scripts/make-icon.swift && iconutil -c icns dist/AppIcon.iconset -o Resources/AppIcon.icns`
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
else
    echo "warning: Resources/AppIcon.icns missing — the app will use the generic icon" >&2
fi

if [ "$SIGN" = "1" ]; then
    echo "==> Signing with: $IDENTITY"
    # --options runtime is the hardened runtime, required for notarisation.
    # --timestamp is required too; without it notarisation is rejected.
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
    echo "==> Gatekeeper assessment (expected to fail until notarised):"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
else
    echo "==> Skipping signing (SIGN=0). Ad-hoc signing so it will at least launch."
    codesign --force --sign - "$APP"
fi

echo
echo "Built: $APP"
du -sh "$APP" | awk '{print "Size:  " $1}'
