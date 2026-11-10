#!/bin/sh
# Search's picture model for a build (models/search/), so make app builds it in without anyone having to know about
# it: the published version models/search.lock names, downloaded from pond-models (about 350 MB, once; checked
# against the lock's SHA-256), by scripts/model-fetch.sh. Later builds find it there and do nothing. A model
# converted on this Mac instead (SEARCH_MODEL=convert, below) is kept.
#
# It never fails the build: offline, or without room, it says why and Pond is built without the picture model
# (search then works on what was found and the descriptions alone). SEARCH_MODEL=0 skips it.
#
# SEARCH_MODEL=convert makes it here instead, from SigLIP 2 at the lock's revision with the lock's packages: once, into
# a Python environment of its own (.build/siglip-venv), downloading SigLIP 2 from Hugging Face (about 375 MB) and
# the converter's packages (a few GB). For working on the conversion itself; what's published is made by CI
# (docs/search.md, Published versions).
set -u
cd "$(dirname "$0")/.."
OUT=models/search
VENV=.build/siglip-venv

skip() {
    echo "⚠ search's picture model not made: $1"
    echo "  Pond is built without it (search works on what was found and the descriptions). It's tried again on"
    echo "  the next make app; SEARCH_MODEL=0 stops that. By hand: docs/search.md, The picture model."
    exit 0
}

case ${SEARCH_MODEL:-1} in
    0)
        echo "· search's picture model skipped (SEARCH_MODEL=0)"
        exit 0
        ;;
    convert) ;;
    *)
        scripts/model-fetch.sh models/search.lock "$OUT" || skip "the published one couldn't be downloaded (above)"
        exit 0
        ;;
esac

[ -e "$OUT/siglip2.json" ] && [ ! -e "$OUT/.sha256" ] && exit 0
# A Python torch 2.7 runs on (3.9 to 3.13): the first python3 on the PATH that is one, else macOS's own.
PYTHON=
for candidate in python3 python3.13 python3.12 python3.11 python3.10 /usr/bin/python3; do
    path=$(command -v "$candidate" 2>/dev/null) || continue
    if "$path" -c 'import sys; sys.exit(0 if (3, 9) <= sys.version_info[:2] <= (3, 13) else 1)' 2>/dev/null; then
        PYTHON=$path
        break
    fi
done
[ -n "$PYTHON" ] || skip "no Python 3.9 to 3.13 found (Xcode's command line tools have one)"

echo "Converting search's picture model (a few minutes, a few GB downloaded the first time)…"
rm -rf "$OUT"
if [ ! -x "$VENV/bin/python" ]; then
    "$PYTHON" -m venv "$VENV" || skip "couldn't make a Python environment in $VENV"
fi
# The packages the published model was made with (coremltools 9 is tested with torch 2.7, and fails on numpy 2.3's
# stricter scalars), and the model at its published revision (models/search.lock).
"$VENV/bin/pip" install --quiet --disable-pip-version-check -r scripts/siglip-requirements.txt \
    || skip "the converter's packages couldn't be installed (offline?)"
SIGLIP_REVISION=$(sed -n 's/^revision = //p' models/search.lock) "$VENV/bin/python" scripts/convert-siglip.py \
    || { rm -rf "$OUT"; skip "the conversion failed (see above)"; }
[ -e "$OUT/siglip2.json" ] || skip "the conversion wrote no manifest"
echo "✓ $OUT: search's picture model, converted here"
