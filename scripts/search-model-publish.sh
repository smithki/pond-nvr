#!/bin/sh
# Publishes the model in models/search/ (just converted at REVISION) as the next version of search's picture model,
# for the search model workflow: the lock says what it was made from, the archive goes to pond-models as a
# release, and its signed entry goes first in pond.camera's manifest (web/data/search-models.json). What's
# published there is used by no Pond until the pull request with the manifest is merged.
#
#   GH_TOKEN=… MODEL_SIGNING_KEY=… scripts/search-model-publish.sh REVISION
#   (GH_TOKEN: one that can make releases in pond-models; MODEL_SIGNING_KEY: the model signing key, base64)
set -eu
cd "$(dirname "$0")/.."

REVISION=${1:?usage: search-model-publish.sh REVISION}
LOCK=models/search.lock
MANIFEST=web/data/search-models.json
MODELS_REPO=${MODELS_REPO:-smithki/pond-models}

lock() { sed -n "s/^$1 = //p" "$LOCK"; }
hash() { shasum -a 256 "$1" | cut -d' ' -f1; }

# The next version: siglip2-v1 → siglip2-v2.
CURRENT=$(lock version)
NEXT="${CURRENT%v*}v$(( ${CURRENT##*v} + 1 ))"
PACKAGES=$(grep -E '^(torch|numpy|transformers|coremltools|sentencepiece|pillow)==' scripts/siglip-requirements.txt | tr '\n' ' ' | sed 's/ $//')
sed -i '' \
    -e "s/^version = .*/version = $NEXT/" \
    -e "s/^revision = .*/revision = $REVISION/" \
    -e "s|^converter = .*|converter = scripts/convert-siglip.py $(hash scripts/convert-siglip.py)|" \
    -e "s|^packages = .*|packages = $PACKAGES|" \
    -e "s|^requirements = .*|requirements = scripts/siglip-requirements.txt $(hash scripts/siglip-requirements.txt)|" \
    "$LOCK"
# A new version's embeddings aren't comparable with the last one's: its name says which it is, so each Pond embeds
# its events again with it (the database keeps the model's name beside each embedding).
sed -i '' "s/^name = .*/name = SigLIP 2 base ${NEXT##*-}/" "$LOCK"
python3 - "$(lock name)" <<'EOF'
import json, sys
path = "models/search/siglip2.json"
manifest = json.load(open(path))
manifest["name"] = sys.argv[1]
json.dump(manifest, open(path, "w"), indent=1)
EOF

scripts/search-model-package.sh "$NEXT"
gh release create "$NEXT" "dist/models/$NEXT.aar" --repo "$MODELS_REPO" --title "$(lock name)" --notes "$(cat <<EOF
Google's SigLIP 2 (\`$(lock source)\` at revision \`$(lock revision)\`), converted to Core ML and quantized for Pond's search by picture, with $(lock packages), and compiled with Core ML's compiler $(xcrun coremlcompiler version).

An Apple Archive (\`aa extract -i $NEXT.aar -d $NEXT\`) of the folder Pond loads, with the Apache License 2.0 (\`LICENSE\`) and a notice of how it was made (\`NOTICE\`).

SHA-256 \`$(lock sha256)\`, $(lock size) bytes. Used by Pond once pond.camera's manifest names it.
EOF
)"

ENTRY=$(scripts/search-model-entry.sh)
python3 - "$ENTRY" <<'EOF'
import json, sys
path = "web/data/search-models.json"
manifest = json.load(open(path))
manifest["models"].insert(0, json.loads(sys.argv[1]))
with open(path, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF
echo "version=$NEXT"
