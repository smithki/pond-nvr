#!/bin/bash
# Puts the release's secrets into GitHub, from 1Password, for the release workflow (.github/workflows/release.yml):
# the Developer ID certificate and its password, and the App Store Connect API key notarization logs in with. Each
# value goes from 1Password to GitHub through a pipe: never shown, never written to a file. Run it on your own Mac
# when they're first set up and whenever one is renewed in 1Password. docs/release.md, Releases from CI.
#
# Where they are in your 1Password is yours, not the repository's: it's read from ~/.config/pond/release-secrets
# (RELEASE_SECRETS to name another file), which this script writes as a template the first time.
#
# Needs the 1Password CLI (op, signed in) and GitHub's (gh, signed in, with access to this repository).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${RELEASE_SECRETS:-$HOME/.config/pond/release-secrets}
ENVIRONMENT=release

fail() { echo "✗ $1" >&2; exit 1; }

if [ ! -e "$CONFIG" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    cat > "$CONFIG" <<'EOF'
# Where the release's secrets are in 1Password, for scripts/ci-secrets.sh. Names only: no secret goes in this file.
# Item names (or IDs) of Document items, in VAULT; the rest a value or a secret reference (op://vault/item/field,
# from a field's menu › Copy Secret Reference).
VAULT=""
P12_DOCUMENT=""         # the Developer ID Application certificate and its key, exported as .p12
P12_PASSWORD=""         # the .p12's password: op://…
P8_DOCUMENT=""          # the App Store Connect API key, AuthKey_KEYID.p8 (a Team key, Developer role)
ASC_KEY_ID=""           # the key's ID (in the .p8's name), or op://…
ASC_ISSUER_ID=""        # the Issuer ID (App Store Connect › Users and Access › Integrations), or op://…
EOF
    chmod 600 "$CONFIG"
    fail "Say where they are in 1Password, in $CONFIG (a template's there now), then run this again."
fi
# shellcheck source=/dev/null
. "$CONFIG"
for name in VAULT P12_DOCUMENT P12_PASSWORD P8_DOCUMENT ASC_KEY_ID ASC_ISSUER_ID; do
    [ -n "${!name:-}" ] || fail "$name is empty in $CONFIG."
done

command -v op >/dev/null || fail "No 1Password CLI: brew install 1password-cli, then turn on Settings › Developer › Integrate with 1Password CLI."
command -v gh >/dev/null || fail "No GitHub CLI: brew install gh."
op whoami >/dev/null 2>&1 || op signin >/dev/null || fail "1Password CLI isn't signed in (op signin)."
gh auth status >/dev/null 2>&1 || fail "GitHub CLI isn't signed in (gh auth login)."
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

# A value as written, or what a secret reference points to.
value() {
    case $1 in
        op://*) op read --no-newline "$1" ;;
        *) printf '%s' "$1" ;;
    esac
}

# The value is held in memory only to check it isn't empty (a failed read sets nothing), then piped to GitHub.
put() {
    local name=$1 secret=$2
    [ -n "$secret" ] || fail "$name came back empty from 1Password: nothing set."
    printf '%s' "$secret" | gh secret set "$name" --env "$ENVIRONMENT" --repo "$REPO" >/dev/null
    echo "✓ $name"
}

# The environment, usable only by tags v* (a release), so no branch's or pull request's workflow reads its secrets.
# (Required reviewers too once the repository is public: GitHub's private repositories on Pro don't have them.)
echo "The $ENVIRONMENT environment of $REPO, for tags v* only"
gh api -X PUT "repos/$REPO/environments/$ENVIRONMENT" --input - >/dev/null <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
if [ -z "$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
        --jq '.branch_policies[] | select(.type == "tag" and .name == "v*") | .id')" ]; then
    gh api -X POST "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null
fi

put DEVELOPER_ID_P12 "$(op document get "$P12_DOCUMENT" --vault "$VAULT" | base64)"
put DEVELOPER_ID_P12_PASSWORD "$(value "$P12_PASSWORD")"
put ASC_KEY_P8 "$(op document get "$P8_DOCUMENT" --vault "$VAULT")"
put ASC_KEY_ID "$(value "$ASC_KEY_ID")"
put ASC_ISSUER_ID "$(value "$ASC_ISSUER_ID")"

echo "✓ The release's secrets are in $REPO's $ENVIRONMENT environment."
