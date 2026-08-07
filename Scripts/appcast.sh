#!/usr/bin/env bash
# Adds the current notarised dist/ClawBar.dmg to a local checkout of the PUBLIC releases
# repo and regenerates appcast.xml with Sparkle's own generate_appcast.
#
#   ./Scripts/appcast.sh                       # uses VERSION from the built app
#   RELEASES=~/somewhere/else ./Scripts/appcast.sh
#
# Why a separate public repo: release assets on a private repo need authentication to
# download, so Sparkle could never fetch them. The source repo stays private; only the
# appcast and the DMGs are public. Same arrangement budgetry-mac-app uses.
#
# Why the DMGs are committed rather than attached as GitHub release assets: a release
# asset's URL contains its tag, so every version needs a different download-url-prefix,
# and generate_appcast takes exactly one for the whole folder. Committing them keeps the
# prefix constant and lets the stock tool do the whole job. The cost is repo size —
# roughly 5 MB per release, so prune old DMGs occasionally.
#
# After running this, commit and push the releases repo. Sparkle picks it up from the
# raw URL in ClawBar's SUFeedURL.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ClawBar.app"
DMG="$ROOT/dist/ClawBar.dmg"
RELEASES="${RELEASES:-$HOME/Code/personal/clawbar-releases}"
PREFIX="${DOWNLOAD_PREFIX:-https://raw.githubusercontent.com/vmlrodrigues/clawbar-releases/main/}"
ACCOUNT="${SPARKLE_ACCOUNT:-ClawBar}"

[ -f "$DMG" ] || { echo "error: $DMG not found — run Scripts/notarize.sh first" >&2; exit 1; }
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

# Refuse to publish something Apple has not blessed; an unnotarised update would fail
# Gatekeeper on every machine that installed it.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG has no stapled notarisation ticket. Run Scripts/notarize.sh." >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"

GENERATE="$(find "$ROOT/.build/artifacts/sparkle" -type f -name generate_appcast 2>/dev/null | head -1)"
[ -x "$GENERATE" ] || { echo "error: generate_appcast not found — run 'swift package resolve'" >&2; exit 1; }

[ -d "$RELEASES" ] || {
    echo "error: no releases checkout at $RELEASES" >&2
    echo "       Create a PUBLIC repo (source stays private) and clone it there, e.g.:" >&2
    echo "         gh repo create vmlrodrigues/clawbar-releases --public --clone" >&2
    echo "       Then re-run. Override the location with RELEASES=/path." >&2
    exit 1
}

echo "==> Staging ClawBar $VERSION (build $BUILD)"
cp "$DMG" "$RELEASES/ClawBar-$VERSION.dmg"

echo "==> Generating appcast (signing with the '$ACCOUNT' EdDSA key)"
"$GENERATE" --account "$ACCOUNT" --download-url-prefix "$PREFIX" "$RELEASES"

echo
echo "Appcast written: $RELEASES/appcast.xml"
grep -E '<sparkle:version>|<title>|sparkle:edSignature' "$RELEASES/appcast.xml" | tail -6 || true
echo
echo "Next: commit and push $RELEASES — Sparkle reads it from"
echo "  $(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$APP/Contents/Info.plist")"
