# Security

Pond records people's homes, so a weakness in it matters. If you find one, please tell us privately first, not in a
public issue.

## Reporting a vulnerability

Use GitHub's private reporting: the repository's **Security** tab › **Report a vulnerability**. Only the maintainers
see the report, and it can become a GitHub advisory, with you credited if you like, once it's fixed.

Please include what's affected and how (a version or commit, the steps, what someone could do with it), and, if you
can, a demo scenario that shows it ([docs/demo.md](docs/demo.md)) rather than anything from a real home: no
recordings, pictures, addresses or passwords of anyone's.

Pond is made by a very small team. You'll hear back within a week; a fix comes first in the next release, and we'll
say when we expect it.

## In scope

- Pond NVR.app and `pond`, the recorder: its control socket, its HomeKit accessories, remote access (pairing, the
  end-to-end encryption between Ponds, what a paired device can ask for), and how camera passwords and keys are
  kept ([docs/security.md](docs/security.md)).
- `pond-signal`, the signaling service, and the hosted one at `signal.pond.camera`: what it can learn or change.
- How Pond is updated and what it downloads: the app's updates (Sparkle, from `pond.camera/appcast.xml`, signed with
  Pond's update key), search's picture model (pond.camera's signed manifest), and the models builds download by
  their locks ([docs/release.md](docs/release.md), [docs/search.md](docs/search.md)).
- The release and CI's keys ([docs/ci-security.md](docs/ci-security.md)).
- pond.camera itself.

## Not in scope

- Cameras' own firmware and apps, and other projects Pond works with (report those to their makers).
- Anything that needs someone already logged in to the Mac as its owner, or with its Keychain unlocked.
- Denial of service by flooding a Mac on the local network.

## Supported versions

The latest release. Fixes aren't made to older ones: Pond updates itself (Pond › Check for Updates…).
