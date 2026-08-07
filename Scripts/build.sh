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
# Auto-detected rather than hardcoded, so a fork signs with its own identity.
IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
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

# ---- Sparkle -----------------------------------------------------------------
# The framework carries its own nested code: two XPC services, a helper app and the
# Autoupdate binary. Each needs signing in its own right, innermost first, because a
# signature covers everything beneath it — sign the framework before its XPC services
# and the outer signature is immediately invalid.
SPARKLE_FW="$(find "$ROOT/.build/artifacts/sparkle" -type d -name 'Sparkle.framework' -path '*macos*' 2>/dev/null | head -1)"
if [ -n "$SPARKLE_FW" ]; then
    echo "==> Embedding Sparkle ($(basename "$(dirname "$SPARKLE_FW")"))"
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    # ditto, not cp: the framework is a symlink farm and cp -R flattens it.
    ditto "$SPARKLE_FW" "$APP/Contents/Frameworks/Sparkle.framework"
else
    echo "error: Sparkle.framework not found — run 'swift package resolve' first" >&2
    exit 1
fi

if [ "$SIGN" = "1" ] && [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' identity in your keychain." >&2
    echo "       Set IDENTITY=… explicitly, or SIGN=0 to build unsigned for local use." >&2
    exit 1
fi

if [ "$SIGN" = "1" ]; then
    echo "==> Signing with: $IDENTITY"
    FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

    # --preserve-metadata=entitlements: the XPC services ship with their own
    # entitlements and re-signing without this silently drops them.
    for xpc in Installer Downloader; do
        codesign --force --options runtime --timestamp \
                 --preserve-metadata=entitlements \
                 --sign "$IDENTITY" "$FW/XPCServices/$xpc.xpc"
    done
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$FW/Updater.app"
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
             "$APP/Contents/Frameworks/Sparkle.framework"

    # --options runtime is the hardened runtime, required for notarisation.
    # --timestamp is required too; without it notarisation is rejected.
    codesign --force --options runtime --timestamp \
             --sign "$IDENTITY" "$APP"
    codesign --verify --strict --deep --verbose=2 "$APP"
    echo "==> Gatekeeper assessment (expected to fail until notarised):"
    spctl --assess --type execute --verbose=4 "$APP" 2>&1 || true
else
    echo "==> Skipping signing (SIGN=0). Ad-hoc signing so it will at least launch."
    codesign --force --sign - "$APP"
fi

echo
echo "Built: $APP"
du -sh "$APP" | awk '{print "Size:  " $1}'
