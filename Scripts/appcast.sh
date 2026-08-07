#!/usr/bin/env bash
# Signs the notarised DMG for Sparkle and updates appcast.xml in this repository.
#
#   ./Scripts/appcast.sh
#
# The source repo is public, so it hosts the appcast directly. The DMGs are GitHub
# *release assets* rather than committed files — committing a ~5 MB binary per release
# would bloat git history permanently, and history is the one thing you cannot prune
# later without rewriting everyone's clones.
#
# This script does the local half only: sign, update appcast.xml, and print the two
# commands that actually publish. Publishing stays an explicit act.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/ClawBar.app"
DMG="$ROOT/dist/ClawBar.dmg"
APPCAST="$ROOT/appcast.xml"
REPO="${GITHUB_REPO:-vmlrodrigues/ClawBar}"
ACCOUNT="${SPARKLE_ACCOUNT:-ClawBar}"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/build.sh" >&2; exit 1; }
[ -f "$DMG" ] || { echo "error: $DMG not found — run Scripts/notarize.sh" >&2; exit 1; }

# An unnotarised update would fail Gatekeeper on every machine that installed it, and
# Sparkle would have already replaced the working copy by then.
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
    echo "error: $DMG has no stapled notarisation ticket. Run Scripts/notarize.sh." >&2
    exit 1
fi

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist"; }
VERSION="$(plist CFBundleShortVersionString)"
BUILD="$(plist CFBundleVersion)"
MIN_SYSTEM="$(plist LSMinimumSystemVersion)"

SIGN_UPDATE="$(find "$ROOT/.build/artifacts/sparkle" -type f -name sign_update 2>/dev/null | head -1)"
[ -x "$SIGN_UPDATE" ] || { echo "error: sign_update not found — run 'swift package resolve'" >&2; exit 1; }

ASSET="ClawBar-$VERSION.dmg"
STAGED="$ROOT/dist/$ASSET"
cp "$DMG" "$STAGED"

echo "==> Signing $ASSET with the '$ACCOUNT' EdDSA key"
SIG_ATTRS="$("$SIGN_UPDATE" --account "$ACCOUNT" "$STAGED")"
echo "    $SIG_ATTRS"

URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"

python3 "$ROOT/Scripts/appcast-add.py" \
    --appcast "$APPCAST" \
    --short-version "$VERSION" \
    --version "$BUILD" \
    --url "$URL" \
    --sig-attrs "$SIG_ATTRS" \
    --min-system "$MIN_SYSTEM" \
    --link "https://github.com/$REPO/releases/tag/v$VERSION"

cat <<EOF

Local work done. To publish:

  gh release create "v$VERSION" "$STAGED#ClawBar $VERSION (macOS, notarised)" \\
      --repo "$REPO" --title "ClawBar $VERSION" --notes "…"

  git add appcast.xml && git commit -m "Publish $VERSION" && git push

Order matters: create the release first, so the enclosure URL resolves by the time the
appcast advertising it goes live. Sparkle reads:
  $(plist SUFeedURL)
EOF
