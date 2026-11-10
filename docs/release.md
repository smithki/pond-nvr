# Making a release

A release is `Pond-VERSION.dmg`: Pond NVR.app signed with a Developer ID, notarized by Apple and stapled, in a disk
image that's signed, notarized and stapled too. It opens on any Mac with Apple silicon and macOS 27 without a
warning, offline as well. `make release` makes it from a clean commit, on a Mac set up once as below.

## Once per Mac

1. **A Developer ID Application certificate** (an Apple Developer Program membership's own; the Apple Development
   one that `make app` uses is for this Mac only): Xcode › Settings › Accounts, the team › Manage Certificates… ›
   **+** › **Developer ID Application**. Only the team's Account Holder can make one. `security find-identity -v -p
   codesigning` then lists it.
2. **Notarization's login**, kept in the keychain under the profile `pond`. With an app-specific password
   (appleid.apple.com › Sign-In and Security › App-Specific Passwords):

   ```sh
   xcrun notarytool store-credentials pond --apple-id YOU@EXAMPLE.COM --team-id TEAMID
   ```

   It asks for the password and checks it. Type it without its dashes (`abcdefghijklmnop`): with them, it was refused as
   incorrect (HTTP 401). An App Store Connect API key works too (`--key`, `--key-id`, `--issuer`). TEAMID is the team's ID (developer.apple.com › Account › Membership
   details). `NOTARY_PROFILE` names another profile.
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

If notarization refuses it, `xcrun notarytool log SUBMISSION-ID --keychain-profile pond` says why.

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

Not yet: updates from within the app (Sparkle and a signed feed), and releases made by CI from a tag rather than on a
Mac (roadmap: A signed, notarized release).
