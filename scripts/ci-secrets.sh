#!/bin/bash
# Puts CI's keys into GitHub's environments, from 1Password (docs/ci-security.md says what each is for):
#   release (tags v* only): the Developer ID certificate and its password, the App Store Connect API key
#     notarization logs in with, and Pond's update key (Sparkle's), for the release workflow (release.yml);
#   models (main only): Pond's GitHub App (its ID and private key), which publishes search's models to pond-models,
#     and the model signing key, which signs them for pond.camera's manifest;
#   appcast (tags v*, and main by hand): the app's ID and key again, to propose a published release's appcast entry.
# release and models are approved by you, job by job (required reviewers).
# Each value goes from 1Password to GitHub through a pipe: never shown, never written to a file. Run it on your own
# Mac when they're first set up and whenever one is renewed in 1Password. docs/release.md, Releases from CI.
#
# Where they are in your 1Password is yours, not the repository's: it's read from ~/.config/pond/release-secrets
# (RELEASE_SECRETS to name another file), which this script writes as a template the first time.
#
# Needs the 1Password CLI (op, signed in) and GitHub's (gh, signed in, with access to this repository).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${RELEASE_SECRETS:-$HOME/.config/pond/release-secrets}

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
SPARKLE_KEY_DOCUMENT="" # Pond's update key (generate_keys --account pond -x), a Document item
BOT_APP_ID=""           # Pond's GitHub App's ID (its settings page), or op://…
BOT_KEY_DOCUMENT=""     # its private key (.pem), a Document item
MODEL_KEY_DOCUMENT=""   # the model signing key (swift scripts/search-model-sign.swift new-key), a Document item
EOF
    chmod 600 "$CONFIG"
    fail "Say where they are in 1Password, in $CONFIG (a template's there now), then run this again."
fi
# shellcheck source=/dev/null
. "$CONFIG"
for name in VAULT P12_DOCUMENT P12_PASSWORD P8_DOCUMENT ASC_KEY_ID ASC_ISSUER_ID SPARKLE_KEY_DOCUMENT BOT_APP_ID BOT_KEY_DOCUMENT MODEL_KEY_DOCUMENT; do
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
    local environment=$1 name=$2 secret=$3
    [ -n "$secret" ] || fail "$name came back empty from 1Password: nothing set."
    printf '%s' "$secret" | gh secret set "$name" --env "$environment" --repo "$REPO" >/dev/null
    echo "  ✓ $name"
}

# An environment that only runs of the given kinds and names can use (tag patterns, branches: "tag v*" "branch main"),
# so no other branch's or pull request's workflow reads its secrets; with `reviewed`, a job waits for your approval
# before it gets them (required reviewers: you, whoever runs this).
ME=$(gh api user --jq .id)
environment() {
    local name=$1 reviewed=$2
    shift 2
    echo "The $name environment of $REPO, for $* only$([ "$reviewed" = reviewed ] && echo ", each job approved by you")"
    if [ "$reviewed" = reviewed ]; then
        reviewers="[{\"type\": \"User\", \"id\": $ME}]"
    else
        reviewers="[]"
    fi
    gh api -X PUT "repos/$REPO/environments/$name" --input - >/dev/null <<JSON
{"reviewers": $reviewers, "deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
    for rule in "$@"; do
        local type=${rule%% *} pattern=${rule#* }
        if [ -z "$(gh api "repos/$REPO/environments/$name/deployment-branch-policies" \
                --jq ".branch_policies[] | select(.type == \"$type\" and .name == \"$pattern\") | .id")" ]; then
            gh api -X POST "repos/$REPO/environments/$name/deployment-branch-policies" -f name="$pattern" -f type="$type" >/dev/null
        fi
    done
}

environment release reviewed "tag v*"
put release DEVELOPER_ID_P12 "$(op document get "$P12_DOCUMENT" --vault "$VAULT" | base64)"
put release DEVELOPER_ID_P12_PASSWORD "$(value "$P12_PASSWORD")"
put release ASC_KEY_P8 "$(op document get "$P8_DOCUMENT" --vault "$VAULT")"
put release ASC_KEY_ID "$(value "$ASC_KEY_ID")"
put release ASC_ISSUER_ID "$(value "$ASC_ISSUER_ID")"
put release SPARKLE_ED_KEY "$(op document get "$SPARKLE_KEY_DOCUMENT" --vault "$VAULT")"

environment models reviewed "branch main"
put models BOT_APP_ID "$(value "$BOT_APP_ID")"
put models BOT_PRIVATE_KEY "$(op document get "$BOT_KEY_DOCUMENT" --vault "$VAULT")"
put models MODEL_SIGNING_KEY "$(op document get "$MODEL_KEY_DOCUMENT" --vault "$VAULT")"

# The appcast: pond-nvr-bot proposes a published release's entry in a pull request (no reviewer: you review the pull
# request itself).
environment appcast unreviewed "tag v*" "branch main"
put appcast BOT_APP_ID "$(value "$BOT_APP_ID")"
put appcast BOT_PRIVATE_KEY "$(op document get "$BOT_KEY_DOCUMENT" --vault "$VAULT")"

echo "✓ CI's keys are in $REPO's release, models and appcast environments."
