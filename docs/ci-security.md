# CI's keys, and what guards them

What Pond's CI holds that could hurt users if it got out (the keys that sign the app, notarize it, sign search's
model and publish it) is kept to a few places, each reachable by as little as possible. This page says where each
is, who and what can use it, and what to do if one leaks. It names no one's own accounts or where they keep things:
those stay with the maintainer.

## The keys

| Key | What it can do | Kept in | CI reads it from |
| --- | --- | --- | --- |
| Developer ID certificate and key (`.p12`) | Sign software as Pond's developer, which Macs then trust | the maintainer's keychain and password manager | the `release` environment |
| App Store Connect API key (`.p8`) | Notarize software for the team (a Team key, Developer role: not App Store or account changes) | the same | `release` |
| Pond's update key (EdDSA, Sparkle's) | Say which disk images Pond installs as updates: Pond refuses one that isn't signed with it | the maintainer's keychain and password manager | `release` |
| Model signing key (Ed25519) | Say which search model Pond may use: Pond refuses one that isn't signed with it | the password manager | `models` |
| pond-nvr-bot's private key | Act as the pond-nvr-bot GitHub App, within its permissions on the repositories it's installed on | the password manager | the environment of each job that uses it |

Each has one job, so one leaking doesn't give the others' power: the bot's key can upload files to `pond-models` but
can't make Pond accept a model (that takes the signing key), and the signing key can sign a manifest but can't
publish one (that takes merging to `main`, which deploys pond.camera through Vercel's GitHub app, which can read the repository
and nothing else of CI's).

## Environments: which workflows can read them

Secrets live in GitHub environments, never as repository-wide secrets, so a workflow reads them only if it names the
environment and the run is one the environment allows.

- **`release`**: tags `v*` only. Used by `release.yml`.
- **`models`**: the branch `main` only. Used by the model workflow (search model updates).

No workflow triggered by a pull request names either, and none uses `pull_request_target` (which runs with the base
repository's rights on a contributor's code). Once the repository is public, each environment also needs the
maintainer's approval before a job starts (required reviewers: GitHub offers them on private repositories only to
paid organisations).

## pond-nvr-bot

One GitHub App, "pond-nvr-bot", does what workflows can't with their own token (which reaches only its own repository):
today, uploading search's models to `pond-models`; later perhaps the CLA check's comments or a downloads feed. It's
meant to grow, so these hold for every job given to it:

- **Each job asks for only what it needs.** A workflow mints its own token for the run (`actions/create-github-app-token`)
  naming the repositories and permissions it needs (`repositories: pond-models`, `permission-contents: write`), never
  the app's whole reach. The token lasts an hour.
- **A permission is added for a job, and noted here.** An app's permissions apply on every repository it's
  installed on, so each is added only with the job that needs it (GitHub asks the owner to approve the change), and
  the table below says which job uses which; nothing it doesn't use stays granted. It has Contents and Pull requests
  (read and write), installed on `pond-models` and `pond-nvr`; each job's token narrows that to its own row.
- **Installed only where a job needs it**, repository by repository ("Only select repositories"), never on all of the
  account's.
- **No webhook**, so nothing calls into it; it acts only when a workflow mints a token.
- **Its key in the environment of the job that uses it**, not repository-wide; a second job in another environment
  gets its own copy there.

| Job | Workflow | Repositories | Permissions |
| --- | --- | --- | --- |
| Publish search models | `search-model.yml` (`models`) | `pond-models` | Contents: read and write |
| Propose a search model (a branch and a pull request) | `search-model.yml` (`models`) | `pond-nvr` | Contents: read and write; Pull requests: read and write |

## Rules for workflows

- **Actions pinned to a commit** (`uses: actions/checkout@<sha> # v4`), not a tag, which its owner could move. A
  version is updated on purpose, by changing the SHA.
- **Least `permissions:`** at the top of each workflow (`contents: read` unless it must write).
- **Secrets only in steps that use them**, as environment variables of that step, never echoed; files made from
  them (a `.p12`, a `.p8`) live in the job's temporary folder only while they're imported, and keychains made for a job
  are deleted however it ends (`scripts/ci-keychain.sh`).
- **What publishes needs a person.** A release is a draft until published by hand; a new model is a pull request until
  merged. The appcast workflow commits to `main` itself (with the workflow's own token), but only what a published
  release carries, signed when it was made: it holds no key.

## Protecting what's public

- **`main`**: a ruleset ("main: no force pushes or deletion"): nothing pushed to it rewrites its history or removes it.
  Changes don't go through pull requests yet (the maintainer pushes them); when they do, the ruleset requires them,
  with the code owners' review.
- **CODEOWNERS** (`.github/CODEOWNERS`): what handles the keys, makes and publishes releases, and says what Pond
  downloads and trusts (the workflows, the release and model scripts, the locks, the manifest and appcast, the app's
  Info.plist): a pull request touching them asks for the maintainer's review.
- **Outside contributions**: not merged until the CLA's review and its check (CONTRIBUTING.md); a first-time
  contributor's pull request runs no workflow until approved, and none of them names an environment.
- **Required reviewers** on `release` and `models` (the maintainer): a job needing their keys waits for approval.
- **GitHub's own checks**: Dependabot alerts, secret scanning with push protection, and private vulnerability
  reporting (SECURITY.md).
- **The appcast workflow's commit**: it pushes to `main` with the workflow's own token, which the ruleset allows (it
  adds a commit, rewriting nothing). If `main` comes to require pull requests, it moves to a pull request opened by
  pond-nvr-bot.

## If a key leaks

- **pond-nvr-bot's key**: the app's settings › Private keys: generate a new one, delete the old (which stops it at once),
  and put the new one in the environments. Then check `pond-models`' releases and the account's security log for what
  it did.
- **The model signing key**: make a new one (`swift scripts/search-model-sign.swift new-key`), put its public half in
  Pond (`models/search-signing.pub`), and release Pond; until then, the old one
  could sign a manifest, though it would still have to reach pond.camera. Remove the manifest's entries signed with
  it that weren't yours.
- **The Developer ID certificate**: revoke it (developer.apple.com › Certificates), which stops Macs trusting what
  it signed from then; make a new one and release again. Tell Apple (Developer Support) if software you didn't make
  was signed with it.
- **Pond's update key**: make a new one, put its public half in `app/Info.plist` (`SUPublicEDKey`), and release Pond
  signed with the old one one last time, so copies already out there take the release that trusts the new key; until
  then the old one could sign a disk image, though it would still need Pond's Developer ID and to reach the appcast.
- **The App Store Connect key**: revoke it in App Store Connect › Users and Access › Integrations and make another.
- Each in the password manager and the environments both (`scripts/ci-secrets.sh` puts the release's back).
