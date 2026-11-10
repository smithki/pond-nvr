#!/bin/sh
# A release of Pond: Pond NVR.app signed with a Developer ID, notarized by Apple and stapled, in a disk image that's
# signed, notarized and stapled too, so it opens on any Mac without a warning. Made from a clean commit, with search's
# picture model built in. Writes dist/release/Pond-VERSION.dmg and its SHA-256.
#
#   make release VERSION=0.1.0
#
# Needs, once per Mac (docs/release.md):
#   - a Developer ID Application certificate (Xcode › Settings › Accounts › Manage Certificates… › + ›
#     Developer ID Application);
#   - notarization's login in the keychain, under the profile "pond" (NOTARY_PROFILE to use another), best an App
#     Store Connect API key kept in the login keychain:
#       xcrun notarytool store-credentials pond --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER \
#           --keychain ~/Library/Keychains/login.keychain-db
set -eu
cd "$(dirname "$0")/.."

VERSION=${1:-}
PROFILE=${NOTARY_PROFILE:-pond}
KEYCHAIN=${NOTARY_KEYCHAIN:-}
OUT=dist/release
APP="$OUT/Pond NVR.app"

fail() { echo "✗ $1" >&2; exit 1; }

# notarytool with the profile, from the keychain it was found in (none: notarytool's own store).
notary() {
    if [ -n "$KEYCHAIN" ]; then
        xcrun notarytool "$@" --keychain-profile "$PROFILE" --keychain "$KEYCHAIN"
    else
        xcrun notarytool "$@" --keychain-profile "$PROFILE"
    fi
}

[ -n "$VERSION" ] || fail "Which version? make release VERSION=0.1.0"

# What's released is a commit, as it is: nothing changed or left out.
[ -z "$(git status --porcelain)" ] || fail "There are changes not committed: a release is made from a commit as it is."

# The version, the same everywhere it's shown: pond --version and Settings (PondCore/Version.swift), and Finder's Get
# Info (app/Info.plist).
grep -q "version = \"$VERSION\"" src/Sources/PondCore/Version.swift \
    || fail "src/Sources/PondCore/Version.swift doesn't say $VERSION (no -dev): set it, commit, then release."
plist_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" app/Info.plist)
[ "$plist_version" = "$VERSION" ] || fail "app/Info.plist's CFBundleShortVersionString is $plist_version, not $VERSION."
grep -q "^## $VERSION" CHANGELOG.md || fail "CHANGELOG.md has no \"## $VERSION\" section: say what's in it."

IDENTITY=${DEVELOPER_ID:-$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}
[ -n "$IDENTITY" ] || fail "No Developer ID Application certificate in the keychain: Xcode › Settings › Accounts › Manage Certificates… › + › Developer ID Application."
# The profile in the login keychain first (where store-credentials --keychain puts it), then notarytool's own store,
# which can go on answering with an older login after store-credentials says it replaced it.
if [ -z "$KEYCHAIN" ]; then
    KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
    notary history >/dev/null 2>&1 || KEYCHAIN=""
fi
notary history >/dev/null 2>&1 \
    || fail "No notarization login that works under the profile \"$PROFILE\" (docs/release.md: Once per Mac)."

# Search's picture model is part of a release: built in, not left out (search would work without pictures).
[ -e models/search/siglip2.json ] || SEARCH_MODEL=1 scripts/search-model.sh
[ -e models/search/siglip2.json ] || fail "Search's picture model couldn't be made (above): a release needs it."

echo "Releasing Pond $VERSION, signed by $IDENTITY"
rm -rf "$OUT" && mkdir -p "$OUT"
make app APP="$APP" SIGN="$IDENTITY" SIGN_TIMESTAMP=1

codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -q 'flags=.*runtime' || fail "The app isn't signed with the hardened runtime."

# The app notarized and its ticket stapled to it, so it opens offline once copied out of the disk image.
echo "Notarizing the app (a few minutes)…"
ditto -c -k --keepParent "$APP" "$OUT/Pond.zip"
notary submit "$OUT/Pond.zip" --wait
xcrun stapler staple "$APP"
rm "$OUT/Pond.zip"

# The disk image: the app beside a link to Applications, signed, notarized and stapled.
DMG="$OUT/Pond-$VERSION.dmg"
STAGE="$OUT/stage"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Pond NVR.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Pond $VERSION" -srcfolder "$STAGE" -fs APFS -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$IDENTITY" --timestamp "$DMG"
echo "Notarizing the disk image…"
notary submit "$DMG" --wait
xcrun stapler staple "$DMG"

# As Gatekeeper sees them on someone else's Mac.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

(cd "$OUT" && shasum -a 256 "Pond-$VERSION.dmg" > "Pond-$VERSION.dmg.sha256")
echo "✓ $DMG ($(du -h "$DMG" | cut -f1)), SHA-256 $(cut -d' ' -f1 "$DMG.sha256")"
