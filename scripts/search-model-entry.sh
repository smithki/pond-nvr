#!/bin/sh
# pond.camera's manifest entry for the version models/search.lock names, signed with the model signing key
# (MODEL_SIGNING_KEY, base64: only the models environment has it, docs/ci-security.md) and checked against Pond's
# public key (models/search-signing.pub) before it's printed, as JSON, for web/data/search-models.json.
# Run by .github/workflows/search-model-sign.yml.
set -eu
cd "$(dirname "$0")/.."

LOCK=models/search.lock
PUBLIC=${PUBLIC_KEY:-$(cat models/search-signing.pub)}
WORK=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

fail() { echo "✗ $1" >&2; exit 1; }
lock() { v=$(sed -n "s/^$1 = //p" "$LOCK"); [ -n "$v" ] || fail "$LOCK has no $1."; printf '%s' "$v"; }

ENTRY="$WORK/search-model-entry.json"
cat > "$ENTRY" <<EOF
{"id": "$(lock version)", "name": "$(lock name)", "format": $(lock format), "minimumApp": "$(lock minimumApp)",
 "size": $(lock size), "sha256": "$(lock sha256)"}
EOF
SIGNATURE=$(swift scripts/search-model-sign.swift sign "$ENTRY")
swift scripts/search-model-sign.swift verify "$ENTRY" "$PUBLIC" "$SIGNATURE" >/dev/null \
    || fail "The signature doesn't verify with models/search-signing.pub: MODEL_SIGNING_KEY isn't its key."
rm "$ENTRY"

cat <<EOF
{
  "id": "$(lock version)",
  "name": "$(lock name)",
  "format": $(lock format),
  "minimumApp": "$(lock minimumApp)",
  "size": $(lock size),
  "sha256": "$(lock sha256)",
  "urls": ["$(lock url)"],
  "published": "$(date -u +%Y-%m-%d)",
  "signature": "$SIGNATURE"
}
EOF
