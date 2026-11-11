#!/bin/sh
# Packages search's picture model (models/search/, as scripts/convert-siglip.py made it) as one published version:
# dist/models/VERSION.aar, an Apple Archive holding exactly the folder Pond loads (the two models compiled for
# Core ML, siglip2.json and the tokenizer), with SigLIP 2's licence and a notice of how it was made. Writes the
# archive's name, size and SHA-256 into models/search.lock. docs/search.md, Published versions.
#
#   scripts/search-model-package.sh siglip2-v1
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:-}
SRC=models/search
LOCK=models/search.lock
OUT=dist/models

fail() { echo "✗ $1" >&2; exit 1; }
lock() { sed -n "s/^$1 = //p" "$LOCK"; }

[ -n "$VERSION" ] || fail "Which version? scripts/search-model-package.sh siglip2-v1"
[ "$(lock version)" = "$VERSION" ] || fail "$LOCK says version $(lock version), not $VERSION: say what it's made from there first."
[ -e "$SRC/siglip2.json" ] || fail "No model in $SRC (scripts/search-model.sh makes one)."

STAGE="$OUT/$VERSION"
ARCHIVE="$OUT/$VERSION.aar"
rm -rf "$STAGE" "$ARCHIVE"
mkdir -p "$STAGE"

for m in "$SRC"/*.mlpackage; do xcrun coremlcompiler compile "$m" "$STAGE" >/dev/null; done
cp "$SRC/siglip2.json" "$SRC/siglip2-tokenizer.json" "$STAGE/"
cp third-party/Apache-2.0.txt "$STAGE/LICENSE"
cat > "$STAGE/NOTICE" <<EOF
$(lock name) ($VERSION), for Pond (https://pond.camera)

Google's SigLIP 2, $(lock source) at revision $(lock revision)
(https://huggingface.co/$(lock source)), licensed under the Apache License 2.0 (LICENSE).

Modified: converted to Core ML and quantized by Pond's $(lock converter | cut -d' ' -f1), with
$(lock packages), and compiled with Core ML's compiler $(xcrun coremlcompiler version).
EOF

aa archive -d "$STAGE" -o "$ARCHIVE" -a lzfse
rm -rf "$STAGE"

SIZE=$(stat -f %z "$ARCHIVE")
SHA=$(shasum -a 256 "$ARCHIVE" | cut -d' ' -f1)
URL="https://github.com/smithki/pond-models/releases/download/$VERSION/$VERSION.aar"
sed -i '' "s/^archive =.*/archive = $VERSION.aar/; s|^url =.*|url = $URL|; s/^size =.*/size = $SIZE/; s/^sha256 =.*/sha256 = $SHA/" "$LOCK"
echo "✓ $ARCHIVE ($(du -h "$ARCHIVE" | cut -f1)), SHA-256 $SHA"
