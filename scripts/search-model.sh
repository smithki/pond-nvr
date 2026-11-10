#!/bin/sh
# Makes search's picture model (models/search/, SigLIP 2 converted to Core ML) if it isn't there, so the first
# make app builds it in without anyone having to know about it. It's too big for the repository, so each copy of
# the repository makes its own: once, into a Python environment of its own (.build/siglip-venv), downloading
# SigLIP 2 from Hugging Face (about 375 MB) and the converter's packages (a few GB). Later builds find it made and
# do nothing.
#
# It never fails the build: without Python, the network or room, it says why and Pond is built without the
# picture model (search then works on what was found and the descriptions alone). SEARCH_MODEL=0 skips it.
set -u
cd "$(dirname "$0")/.."
OUT=models/search
VENV=.build/siglip-venv

[ -e "$OUT/siglip2.json" ] && exit 0
if [ "${SEARCH_MODEL:-1}" = 0 ]; then
    echo "· search's picture model skipped (SEARCH_MODEL=0)"
    exit 0
fi

skip() {
    echo "⚠ search's picture model not made: $1"
    echo "  Pond is built without it (search works on what was found and the descriptions). It's tried again on"
    echo "  the next make app; SEARCH_MODEL=0 stops that. By hand: docs/search.md, The picture model."
    # Nothing half-made left to be taken for the model.
    rm -rf "$OUT"
    exit 0
}

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

echo "Making search's picture model (once for this copy of the repository: a few minutes, a few GB downloaded)…"
if [ ! -x "$VENV/bin/python" ]; then
    "$PYTHON" -m venv "$VENV" || skip "couldn't make a Python environment in $VENV"
fi
# The packages the published model was made with (coremltools 9 is tested with torch 2.7, and fails on numpy 2.3's
# stricter scalars), and the model at its published revision (models/search.lock).
"$VENV/bin/pip" install --quiet --disable-pip-version-check -r scripts/siglip-requirements.txt \
    || skip "the converter's packages couldn't be installed (offline?)"
SIGLIP_REVISION=$(sed -n 's/^revision = //p' models/search.lock) "$VENV/bin/python" scripts/convert-siglip.py || skip "the conversion failed (see above)"
[ -e "$OUT/siglip2.json" ] || skip "the conversion wrote no manifest"
echo "✓ $OUT: search's picture model"
