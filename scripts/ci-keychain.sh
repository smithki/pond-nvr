#!/bin/bash
# The keychain a release made by CI signs and notarizes from (.github/workflows/release.yml): made for the job, with
# a random password, holding the Developer ID certificate and its key (from DEVELOPER_ID_P12, base64, and
# DEVELOPER_ID_P12_PASSWORD) and notarization's login under the profile "pond" (the API key from ASC_KEY_P8,
# ASC_KEY_ID and ASC_ISSUER_ID). Removed by "remove", which the workflow runs however the job ends.
#
#   scripts/ci-keychain.sh setup     then make release, which finds both (NOTARY_KEYCHAIN, written to GITHUB_ENV)
#   scripts/ci-keychain.sh remove
#
# The .p12 and .p8 are files only for as long as they're imported, in the job's own temporary folder.
set -euo pipefail

TMP=${RUNNER_TEMP:?not set: this is for CI}
KC="$TMP/pond-release.keychain-db"

fail() { echo "::error::$1" >&2; exit 1; }

setup() {
    for name in DEVELOPER_ID_P12 DEVELOPER_ID_P12_PASSWORD ASC_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID; do
        [ -n "${!name:-}" ] || fail "The secret $name isn't set (docs/release.md, Releases from CI)."
    done
    local password
    password=$(openssl rand -hex 24)
    trap 'rm -f "$TMP/developer-id.p12" "$TMP/AuthKey.p8" "$TMP/DeveloperIDG2CA.cer"' EXIT

    security create-keychain -p "$password" "$KC"
    security set-keychain-settings -lut 21600 "$KC"   # unlocked for 6 hours, a job's longest
    security unlock-keychain -p "$password" "$KC"
    # First in the search list, so codesign and security find-identity (release.sh) see it.
    # shellcheck disable=SC2046
    security list-keychains -d user -s "$KC" $(security list-keychains -d user | tr -d '"')

    # The certificate and its key, usable by codesign without a dialog nobody could answer.
    printf '%s' "$DEVELOPER_ID_P12" | base64 --decode > "$TMP/developer-id.p12"
    security import "$TMP/developer-id.p12" -k "$KC" -f pkcs12 -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$KC" >/dev/null
    rm "$TMP/developer-id.p12"
    # The certificate's issuer, which a runner may not have: without it the identity isn't valid.
    curl -fsS -o "$TMP/DeveloperIDG2CA.cer" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
    security import "$TMP/DeveloperIDG2CA.cer" -k "$KC" >/dev/null 2>&1 || true
    security find-identity -v -p codesigning "$KC" | grep -q '"Developer ID Application: ' \
        || fail "DEVELOPER_ID_P12 holds no valid Developer ID Application certificate and key."

    # Notarization's login, checked with Apple as it's stored.
    printf '%s\n' "$ASC_KEY_P8" > "$TMP/AuthKey.p8"
    chmod 600 "$TMP/AuthKey.p8"
    xcrun notarytool store-credentials pond --key "$TMP/AuthKey.p8" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
        --keychain "$KC" >/dev/null
    rm "$TMP/AuthKey.p8"

    echo "NOTARY_KEYCHAIN=$KC" >> "${GITHUB_ENV:-/dev/null}"
    echo "✓ The release keychain is ready."
}

remove() {
    security delete-keychain "$KC" 2>/dev/null || true
    rm -f "$TMP/developer-id.p12" "$TMP/AuthKey.p8"
}

case ${1:-} in
    setup) setup ;;
    remove) remove ;;
    *) echo "usage: $0 setup|remove" >&2; exit 2 ;;
esac
