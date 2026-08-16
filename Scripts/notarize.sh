#!/usr/bin/env bash
# Notarises dist/ClawBar.app, staples the ticket, and packages a signed DMG.
#
# Authenticates with an App Store Connect API key rather than an Apple ID and an
# app-specific password. The key is a file, so there is no interactive
# `notarytool store-credentials` step and nothing to repeat when setting up another
# machine — which also means the credential never lands in a keychain profile that is
# easy to forget about.
#
# SETUP: copy .env.example to .env and fill in the three variables it documents.
#
# Then:  ./Scripts/notarize.sh

set -euo pipefail

APP_NAME="ClawBar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build.sh first" >&2; exit 1; }
[ -f "$ROOT/.env" ] || {
    echo "error: no .env in $ROOT" >&2
    echo "       cp $ROOT/.env.example $ROOT/.env   and fill it in" >&2
    exit 1
}

# shellcheck disable=SC1091
set -a; . "$ROOT/.env"; set +a

: "${NOTARY_KEY:?.env must set NOTARY_KEY (path to the App Store Connect .p8)}"
: "${NOTARY_KEY_ID:?.env must set NOTARY_KEY_ID}"
: "${NOTARY_ISSUER:?.env must set NOTARY_ISSUER}"
IDENTITY="${RELEASE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
[ -n "$IDENTITY" ] || { echo "error: no Developer ID identity; set RELEASE_SIGN_IDENTITY in .env" >&2; exit 1; }

[ -f "$NOTARY_KEY" ] || { echo "error: NOTARY_KEY file not found: $NOTARY_KEY" >&2; exit 1; }

echo "==> Verifying the app signature before submitting"
codesign --verify --strict --verbose=2 "$APP"

# Two-stage notarisation. Notarising only the DMG leaves the .app without its own
# stapled ticket, so once a user drags it to /Applications Gatekeeper has to check
# Apple online — which stalls on first launch if they happen to be offline. Stapling the
# app first, then shipping the stapled app inside a notarised DMG, works offline.
ZIP="$DIST/$APP_NAME-app.zip"
echo "==> [1/2] Notarising the app itself"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
    --wait
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP" && echo "  App ticket: stapled"

echo "==> [2/2] Building DMG (containing the stapled app)"
rm -f "$DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
# hdiutil rather than create-dmg: it ships with macOS, so building a release needs nothing
# installed beyond Xcode's command line tools. `brew install create-dmg` would buy a styled
# window (background image, fixed icon positions) at the cost of that property.
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing the DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

echo "==> Submitting for notarisation (usually a few minutes)"
xcrun notarytool submit "$DMG" \
    --key "$NOTARY_KEY" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER" \
    --wait

echo "==> Stapling the DMG"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG" && echo "  DMG ticket: stapled"

echo "==> Gatekeeper assessment"
spctl --assess --type open --context context:primary-signature --ignore-cache "$DMG" \
    && echo "  Gatekeeper: OK" \
    || echo "  Warning: Gatekeeper check failed"

echo
echo "Distributable: $DMG"
