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

# Cutting a release means editing VERSION first. Publishing a build whose version already
# has a release would overwrite that entry in the appcast and point it at different bits.
if [ -f "$ROOT/VERSION" ]; then
    WANT="$(tr -d '[:space:]' < "$ROOT/VERSION")"
    if git -C "$ROOT" rev-parse "v$WANT" >/dev/null 2>&1; then
        echo "error: v$WANT is already released. Bump the VERSION file before publishing." >&2
        exit 1
    fi
fi
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

# ---- the built app must correspond to a commit ---------------------------------
# `gh release create` tags whatever HEAD happens to be. If the release's own work is still
# uncommitted, the tag lands on the *previous* release's commit, and the published source
# then contradicts the published binary. That is not hypothetical: v0.4.3, v0.4.4, v0.4.5
# and v0.5.2 all shipped with the tag on the wrong commit and had to be moved by hand.
#
# BUILD is the commit count, so a dirty tree also produces a build number that identifies a
# commit whose contents are not what was built. Checking all three is cheap; each catches a
# different way of getting here.
if ! git -C "$ROOT" diff --quiet HEAD -- 2>/dev/null; then
    echo "error: uncommitted changes — commit the release's work before publishing." >&2
    echo "       Otherwise the tag lands on the previous commit and BUILD identifies" >&2
    echo "       source that was never built." >&2
    git -C "$ROOT" status --short >&2
    exit 1
fi

HEAD_VERSION="$(git -C "$ROOT" show HEAD:VERSION 2>/dev/null | tr -d '[:space:]')"
if [ "$HEAD_VERSION" != "$VERSION" ]; then
    echo "error: VERSION at HEAD is '$HEAD_VERSION' but the built app says '$VERSION'." >&2
    echo "       Commit the VERSION bump, then rebuild — the binary must match a commit." >&2
    exit 1
fi

HEAD_BUILD="$(git -C "$ROOT" rev-list --count HEAD)"
if [ "$HEAD_BUILD" != "$BUILD" ]; then
    echo "error: the app was built at commit count $BUILD, but HEAD is $HEAD_BUILD." >&2
    echo "       Rebuild from HEAD so the shipped build number names the tagged commit." >&2
    exit 1
fi

# The three checks above all interrogate the *local* repository, which is necessary and not
# sufficient: `gh release create` tags the REMOTE's HEAD. Commit without pushing and the
# remote is still a commit behind, so the tag lands there instead — with every local guard
# reporting success.
#
# This is not a theoretical gap. v0.5.3 went out with its tag on the wrong commit for
# exactly this reason, minutes after the other three guards were added to prevent precisely
# that class of mistake. Local correctness felt like enough right up until it wasn't.
BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
REMOTE="${GIT_REMOTE:-origin}"
git -C "$ROOT" fetch --quiet "$REMOTE" "$BRANCH" 2>/dev/null || true
if ! git -C "$ROOT" merge-base --is-ancestor HEAD "$REMOTE/$BRANCH" 2>/dev/null; then
    echo "error: HEAD is not on $REMOTE/$BRANCH yet." >&2
    echo "       Push before publishing — 'gh release create' tags the remote's HEAD, so an" >&2
    echo "       unpushed commit puts the tag on whatever the remote last saw." >&2
    echo "       git push $REMOTE $BRANCH" >&2
    exit 1
fi

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

# A second, version-less copy. The README's Download button points at
# releases/latest/download/ClawBar.dmg, which resolves only if an asset is named exactly
# that — and Sparkle needs the version-stamped name, since its enclosure URLs must differ
# per release. Both are attached; the duplication is a few megabytes.
STABLE="$ROOT/dist/ClawBar.dmg"

cat <<EOF

Local work done — the app at HEAD ($HEAD_BUILD) is what was built, and $REMOTE/$BRANCH has it.
To publish:

  1. Create the release. This tags the remote's HEAD, which the guards above have confirmed
     is both pushed and the commit this binary was built from:

  gh release create "v$VERSION" \\
      "$STAGED#ClawBar $VERSION (macOS, notarised)" \\
      "$STABLE#ClawBar (latest, Apple Silicon)" \\
      --repo "$REPO" --title "ClawBar $VERSION" --notes "…"

  2. Then commit the appcast, which advertises it:

  git add appcast.xml && git commit -m "Publish $VERSION" && git push

The release comes first so the enclosure URL resolves before the feed advertising it goes
live — a feed pointing at a 404 is worse than a late feed. The appcast commit landing after
the tag is expected and correct: the tag marks the source that was built, and the appcast is
a record of having published it.

Sparkle reads:
  $(plist SUFeedURL)
EOF
