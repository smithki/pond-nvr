#!/bin/sh
# Whether search's picture model might need making again: if anything the published one was made from
# (models/search.lock) has changed since. SigLIP 2's latest revision on Hugging Face, the converter, its packages.
# Prints changed=true|false, revision= and reason= (for GITHUB_OUTPUT); converting is the search model workflow's
# next step, and whether the result is worth publishing is decided after (scripts/search-model-compare.py).
set -eu
cd "$(dirname "$0")/.."

LOCK=models/search.lock
lock() { sed -n "s/^$1 = //p" "$LOCK"; }
hash() { shasum -a 256 "$1" | cut -d' ' -f1; }

SOURCE=$(lock source)
LATEST=$(curl -fsS "https://huggingface.co/api/models/$SOURCE" | python3 -c 'import json, sys; print(json.load(sys.stdin)["sha"])')
[ -n "$LATEST" ] || { echo "✗ Couldn't read $SOURCE's revision from Hugging Face." >&2; exit 1; }

reasons=""
[ "$LATEST" = "$(lock revision)" ] || reasons="$reasons $SOURCE has a new revision ($LATEST);"
[ "$(hash scripts/convert-siglip.py)" = "$(lock converter | cut -d' ' -f2)" ] || reasons="$reasons the converter changed;"
[ "$(hash scripts/siglip-requirements.txt)" = "$(lock requirements | cut -d' ' -f2)" ] || reasons="$reasons its packages changed;"

if [ -n "$reasons" ]; then
    echo "changed=true"
    echo "reason=${reasons# }"
else
    echo "changed=false"
    echo "reason=nothing it's made from has changed since $(lock version)"
fi
echo "revision=$LATEST"
