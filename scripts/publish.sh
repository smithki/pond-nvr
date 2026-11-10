#!/bin/sh
# Publishes, from this Mac, the release make release made: what the release workflow does after building, for when
# CI can't make it (docs/release.md, When CI can't). A draft GitHub release with the disk image, its checksum and its
# Sparkle signature, and the changelog's section as its notes, then its tag, pushed. The draft is published by hand,
# after a look, as CI's are.
#
#   make release VERSION=0.1.0 && make publish VERSION=0.1.0
#
# It publishes only what was made from the commit checked out now, and checks the disk image as Gatekeeper does
# first. The draft goes up before the tag, so the release workflow the tag starts finds it there and builds nothing.
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:-}
OUT=dist/release
DMG="$OUT/Pond-$VERSION.dmg"
TAG="v$VERSION"

fail() { echo "✗ $1" >&2; exit 1; }

[ -n "$VERSION" ] || fail "Which version? make publish VERSION=0.1.0"
[ -e "$DMG" ] && [ -e "$DMG.sha256" ] && [ -e "$OUT/Pond-$VERSION.sparkle" ] && [ -e "$OUT/Pond-$VERSION.commit" ] \
    || fail "No release of $VERSION in $OUT: make release VERSION=$VERSION first."
COMMIT=$(git rev-parse HEAD)
[ "$(cat "$OUT/Pond-$VERSION.commit")" = "$COMMIT" ] \
    || fail "$DMG was made from $(cut -c1-7 "$OUT/Pond-$VERSION.commit"), not the commit checked out ($(git rev-parse --short HEAD)): make release again."
[ -z "$(git status --porcelain)" ] || fail "There are changes not committed: a release is published from a commit as it is."

command -v gh >/dev/null || fail "No GitHub CLI: brew install gh."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI isn't signed in (gh auth login)."
git fetch -q origin main
git merge-base --is-ancestor "$COMMIT" origin/main \
    || fail "$(git rev-parse --short HEAD) isn't on GitHub's main: push it first, so the release is of a commit others can see."
! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "The tag $TAG is here already."
! git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 || fail "The tag $TAG is on GitHub already."
gh release view "$TAG" >/dev/null 2>&1 && fail "GitHub has a release $TAG already."

# The disk image as it is now, as Gatekeeper sees it on another Mac, and as its checksum says.
(cd "$OUT" && shasum -a 256 -c "Pond-$VERSION.dmg.sha256" >/dev/null) || fail "$DMG doesn't match its checksum."
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG has no notarization ticket stapled to it."
spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null || fail "Gatekeeper refuses $DMG."

NOTES=$(mktemp)
trap 'rm -f "$NOTES"' EXIT
scripts/release-notes.sh "$VERSION" > "$NOTES"
[ -s "$NOTES" ] || fail "CHANGELOG.md has no \"## $VERSION\" section."

echo "Publishing Pond $VERSION ($(git rev-parse --short HEAD)) as a draft…"
gh release create "$TAG" --draft --target "$COMMIT" --title "Pond $VERSION" --notes-file "$NOTES" \
    "$DMG" "$DMG.sha256" "$OUT/Pond-$VERSION.sparkle"
git tag -a "$TAG" -m "Pond $VERSION" "$COMMIT"
git push -q origin "refs/tags/$TAG"
echo "✓ A draft release of Pond $VERSION, and its tag $TAG: publish it on GitHub after a look."
