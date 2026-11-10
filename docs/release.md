# Making a release

A release is `Pond-VERSION.dmg`: Pond NVR.app signed with a Developer ID, notarized by Apple and stapled, in a disk
image that's signed, notarized and stapled too. It opens on any Mac with Apple silicon and macOS 27 without a
warning, offline as well. `make release` makes it from a clean commit, on a Mac set up once as below.

## Once per Mac

1. **A Developer ID Application certificate** (an Apple Developer Program membership's own; the Apple Development
   one that `make app` uses is for this Mac only): Xcode › Settings › Accounts, the team › Manage Certificates… ›
   **+** › **Developer ID Application**. Only the team's Account Holder can make one. `security find-identity -v -p
   codesigning` then lists it.
2. **Notarization's login**, kept in the login keychain under the profile `pond`. Best an App Store Connect API key
   (App Store Connect › Users and Access › Integrations › App Store Connect API: a **Team** key with the Developer
   role; the `.p8` downloads once, so keep a copy somewhere safe). The Key ID is in the file's name, the Issuer ID
   above the list of keys:

   ```sh
   xcrun notarytool store-credentials pond --key AuthKey_KEYID.p8 --key-id KEYID --issuer ISSUER \
       --keychain ~/Library/Keychains/login.keychain-db
   ```

   It checks the key with Apple and copies it into the keychain, so the `.p8` file can be deleted afterwards. Then
   `xcrun notarytool history --keychain-profile pond --keychain ~/Library/Keychains/login.keychain-db` lists past
   submissions. Keep `--keychain`: without it the profile goes to notarytool's own store, which went on answering
   with an older login (HTTP 401) after saying it had replaced it. `make release` looks in the login keychain first,
   then notarytool's store; `NOTARY_PROFILE` names another profile, `NOTARY_KEYCHAIN` another keychain.

   An app-specific password works too (appleid.apple.com › Sign-In and Security › App-Specific Passwords), with
   `--apple-id YOU@EXAMPLE.COM --team-id TEAMID` in place of the key's three options; TEAMID is in developer.apple.com
   › Account › Membership details. Type the password without its dashes (`abcdefghijklmnop`): with them, it was
   refused as incorrect (HTTP 401).
3. **Search's picture model** made (`models/search/`): the first `make app` makes it, or `make release` does.

## Each release

1. Say what's in it: a `## VERSION` section in `CHANGELOG.md` (the release's notes).
2. Set the version: `src/Sources/PondCore/Version.swift` (`"0.1.0"`, without `-dev`) and `app/Info.plist`
   (`CFBundleShortVersionString`, and `CFBundleVersion` one higher than the last release's). Commit.
3. `make release VERSION=0.1.0`. It refuses, and says why, when anything above isn't so: changes not committed,
   versions that don't agree, no changelog section, no certificate or notarization login, no search model. Then it:
   - builds the app under the hardened runtime with a secure timestamp, signed with the Developer ID;
   - notarizes it (a few minutes, waiting for Apple's answer) and staples the ticket to it;
   - puts it in a disk image beside a link to Applications, signs, notarizes and staples that;
   - checks both as Gatekeeper does on another Mac (`spctl`);
   - writes `dist/release/Pond-0.1.0.dmg` and its SHA-256.
4. Tag the commit (`git tag v0.1.0`, pushed), publish the disk image and its checksum with the changelog section as
   its notes, and set `Version.swift` back to the next `-dev`.

If notarization refuses it, `xcrun notarytool log SUBMISSION-ID --keychain-profile pond --keychain ~/Library/Keychains/login.keychain-db` says
why.

## What goes in

- **The hardened runtime**, which notarization requires, on every build (`make app` too), so what it stops shows in
  everyday use first. The app asks for one entitlement (`app/Pond.entitlements`): the microphone, for talking through
  a camera's speaker. `pond` and `pond-signal` ask for none.
- **Search's picture model, built in** (about 390 MB more): a release searches pictures from the first event, with
  nothing downloaded later and no server to rely on. Each Mac that makes releases converts its own copy for now
  ([search.md](search.md#for-releases-and-ci-not-done-yet) says what a published, pinned model would need, for CI).
- **The licences**: `LICENSE`, `NOTICE` and `licenses/` (the texts the notices refer to) in the app's Resources.
- The bundle identifier `camera.pond` (from pond.camera): settings, the Keychain items and the login service are
  known by it, so it stays.

## Releases from CI

Pushing a tag `v*` runs `.github/workflows/release.yml`: `make release` on a macOS runner, then a **draft** GitHub
release with the disk image, its checksum and the changelog's section as its notes, published by hand after a look.
It signs and notarizes from a keychain made for the job (`scripts/ci-keychain.sh`), from five secrets in the
repository's `release` environment:

| Secret | What it is |
| --- | --- |
| `DEVELOPER_ID_P12` | the Developer ID Application certificate and its key, a `.p12`, base64 |
| `DEVELOPER_ID_P12_PASSWORD` | the `.p12`'s password |
| `ASC_KEY_P8` | the App Store Connect API key's `.p8`, as text |
| `ASC_KEY_ID`, `ASC_ISSUER_ID` | the key's ID and its issuer's |

The environment takes only tags `v*`, so no branch's or pull request's workflow can read them (once the repository
is public, add yourself as a required reviewer too). `scripts/ci-secrets.sh` sets the environment up and puts the
secrets in from 1Password, on your own Mac, piping each value from `op` to `gh` without showing it or writing it to
a file. Where they are in your 1Password stays out of the repository: the script reads it from
`~/.config/pond/release-secrets`, writing a template there the first time. Run it again whenever one is renewed.

The runner is the repository variable `RELEASE_RUNNER`, else `macos-latest`: it must have macOS 27 and its Xcode. A
machine of your own must run nothing else (not your recorder, nor pull requests' code). Search's picture model is
converted on the first release and kept in the Actions cache; a published one with a pinned hash replaces that
(search.md).

Not yet: updates from within the app (Sparkle and a signed feed).
