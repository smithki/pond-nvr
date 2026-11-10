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
3. Nothing for the models: `make release` downloads the published ones `models/*.lock` name (once) and checks
   their hashes.

## Each release

1. Say what's in it: a `## VERSION` section in `CHANGELOG.md` (the release's notes): what's been gathered under
   `## Unreleased` since the last one, under its version now.
2. Set the version: `src/Sources/PondCore/Version.swift` (`"0.1.0"`, without `-dev`) and `app/Info.plist`
   (`CFBundleShortVersionString`, and `CFBundleVersion` one higher than the last release's). Commit.
3. `make release VERSION=0.1.0`. It refuses, and says why, when anything above isn't so: changes not committed,
   versions that don't agree, no changelog section, no certificate or notarization login, no search model. Then it:
   - builds the app under the hardened runtime with a secure timestamp, signed with the Developer ID;
   - notarizes it (a few minutes, waiting for Apple's answer) and staples the ticket to it;
   - puts it in a disk image beside a link to Applications, signs, notarizes and staples that;
   - checks both as Gatekeeper does on another Mac (`spctl`);
   - writes `dist/release/Pond-0.1.0.dmg` and its SHA-256.
4. Publish it: push a tag and CI makes the release ([Releases from CI](#releases-from-ci)), or, on the Mac that made
   it, `make publish VERSION=0.1.0` ([When CI can't](#when-ci-cant)). Either way it's a draft on GitHub; publish it
   there after a look. Then set `Version.swift` back to the next `-dev`.

If notarization refuses it, `xcrun notarytool log SUBMISSION-ID --keychain-profile pond --keychain ~/Library/Keychains/login.keychain-db` says
why.

## What goes in

- **The hardened runtime**, which notarization requires, on every build (`make app` too), so what it stops shows in
  everyday use first. The app asks for one entitlement (`app/Pond.entitlements`): the microphone, for talking through
  a camera's speaker. `pond` and `pond-signal` ask for none.
- **The detection model, built in** (YOLO26 small, about 18 MB): a release finds events from the first one, offline
  too. It's the published version `models/detection.lock` names, downloaded from pond-models and checked against the
  lock's SHA-256 ([detection.md](detection.md#the-built-in-model)), never one converted on the Mac making the release.
- **Search's picture model, not built in**: Pond downloads it itself on first run (about 350 MB), the version
  pond.camera's signed manifest names, and keeps it up to date ([search.md](search.md#published-versions)). Until
  it's there, search goes by what was found and the descriptions. (`make app` builds it in, for development.)
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

The runner is GitHub's `xcode-27` image (macOS 27 with Xcode 27); the repository variable `RELEASE_RUNNER` names another, which must
have macOS 27 and its Xcode too. A machine of your own must run nothing else (not your recorder, nor pull requests' code). The models are downloaded
by the release itself, in seconds. (As of 2026-11-10 the `xcode-27` image is still a preview, and GitHub gave this
repository's jobs no machine for it: a job waits, then is cancelled as "not acquired". Until it does, releases are
made on a Mac with `make release`.)

What guards these keys, and what to do if one leaks: [ci-security.md](ci-security.md).

## When CI can't

When CI can't make a release (its runner isn't there, or it's down), the Mac set up as above makes and publishes
it instead, the same way:

```sh
make release VERSION=0.1.0     # on the commit to release, pushed to main
make publish VERSION=0.1.0
```

`make publish` (`scripts/publish.sh`) does what the workflow does after building: a draft GitHub release with the
disk image, its checksum and the changelog's section as its notes (`scripts/release-notes.sh`, which the workflow
uses too), then the tag `v0.1.0` on that commit, pushed. It refuses to when:
- the disk image wasn't made from the commit checked out (`make release` records it), or there are changes not
  committed;
- that commit isn't on GitHub's `main`;
- the tag or a release of it exists already;
- the disk image doesn't match its checksum, has no notarization ticket, or Gatekeeper refuses it.

The draft goes up before the tag, so the workflow the tag starts finds that release there, with its disk image,
and builds nothing (a minute on Linux, its *check* job). Publish the draft on GitHub after a look, as with CI's.

## Updates

Pond updates itself with [Sparkle](https://sparkle-project.org) (2.10.1, MIT): it asks pond.camera's appcast
(`pond.camera/appcast.xml`, from `site/public/appcast.xml`) daily, or when asked (Pond › Check for Updates…, or
Settings › Advanced), and offers a newer version with its notes. It installs one only if its disk image is signed
with Pond's update key (an EdDSA key; its public half is `SUPublicEDKey` in `app/Info.plist`) and the app in it with
the same Developer ID. Nothing about the Mac is sent with a check (`SUEnableSystemProfiling` off). After an update,
the app restarts the recorder on its new copy of pond (it was still running the old one). Not in a demo.

- **The key**, once: `src/.build/artifacts/sparkle/Sparkle/bin/generate_keys --account pond` makes it, keeps the private
  half in the login keychain and prints the public half, for `SUPublicEDKey`. Kept in the password manager too
  (`generate_keys --account pond -x FILE` exports it), and in the `release` environment as `SPARKLE_ED_KEY`
  (`scripts/ci-secrets.sh`).
- **Each release**: `CFBundleVersion` one higher than the last (Sparkle compares it; `make release` refuses one that
  isn't). `make release` signs the disk image (`sign_update`) and writes `Pond-VERSION.sparkle` beside it: the
  signature, the size and the versions. It's published with the release (CI's or `make publish`'s).
- **The appcast**, when the release is published on GitHub (the draft, by hand): the appcast workflow
  (`.github/workflows/appcast.yml`) takes the release's `.sparkle` and its changelog section and adds its entry
  (`scripts/appcast.py`), committed to `main`, which deploys pond.camera. Until a release is published, no Pond is
  offered it. (It downloads the disk image from the release, so updates reach people once the repository is public.)
