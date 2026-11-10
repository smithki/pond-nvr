#!/bin/sh
# Downloads the published model a lock file names into a folder, for builds (make app, make release, CI): its
# archive from pond-models, checked against the lock's SHA-256 (refused if it differs) and unpacked. Once there,
# later builds find it and download nothing; a changed lock downloads its new version.
#
#   scripts/model-fetch.sh models/detection.lock models/detection
#   scripts/model-fetch.sh models/search.lock models/search
#
# The folder holds a .sha256 of the archive it was unpacked from. A folder without one (a model converted on this
# Mac) is left as it is, unless REPLACE=1 (make release: a release builds in what was published).
set -eu
cd "$(dirname "$0")/.."

LOCK=${1:?usage: model-fetch.sh LOCK FOLDER}
DEST=${2:?usage: model-fetch.sh LOCK FOLDER}

fail() { echo "✗ $1" >&2; exit 1; }
lock() { v=$(sed -n "s/^$1 = //p" "$LOCK"); [ -n "$v" ] || fail "$LOCK has no $1."; printf '%s' "$v"; }

VERSION=$(lock version)
SHA=$(lock sha256)
if [ -e "$DEST/.sha256" ]; then
    [ "$(cat "$DEST/.sha256")" = "$SHA" ] && exit 0
elif [ -d "$DEST" ] && [ -n "$(ls -A "$DEST")" ] && [ "${REPLACE:-0}" != 1 ]; then
    echo "· $DEST: one of this Mac's own, kept (not $VERSION as published; REPLACE=1, or remove it, to download that)"
    exit 0
fi

echo "Downloading $VERSION ($(( $(lock size) / 1000000 )) MB) into ${DEST}…"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 3 -o "$TMP/archive.aar" "$(lock url)" || fail "Couldn't download $(lock url) (offline?)."
[ "$(shasum -a 256 "$TMP/archive.aar" | cut -d' ' -f1)" = "$SHA" ] \
    || fail "$(lock url) isn't the archive $LOCK names (its SHA-256 differs): not used."
mkdir "$TMP/unpacked"
aa extract -i "$TMP/archive.aar" -d "$TMP/unpacked"
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$TMP/unpacked" "$DEST"
printf '%s\n' "$SHA" > "$DEST/.sha256"
echo "✓ $DEST: $VERSION"
