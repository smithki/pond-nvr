# Contributing to Pond

Thank you for helping. Pond is open source: under the [GNU Affero General Public License v3.0](LICENSE), and its network protocol (`protocol/`) under the MIT License.

Issues are welcome: bugs (with a demo scenario or the doctor's report: [docs/demo.md](docs/demo.md)), cameras that do
or don't work, and ideas. A vulnerability goes through [SECURITY.md](SECURITY.md), privately.

## Your contribution's licence

You keep the copyright in what you contribute, and license it under the licence of the part it goes into, as everyone
else's is there (each part's folder has its LICENSE; [NOTICE](NOTICE) has the table):

- **`protocol/`**, Pond's network protocol: the MIT License. It's what lets any app speak Pond's protocol.
- **Everything else** (`signaling/`, `recorder/`, `macos/`, the scripts, the docs, the site): the AGPL-3.0.

There's no agreement to sign. Pond's name, logo and icon aren't covered by these licences (NOTICE).

## Signing off

Every commit is signed off: a line at the end of its message saying you certify the
[Developer Certificate of Origin](https://developercertificate.org/), that you wrote it or otherwise have the right to
submit it under its part's licence.

```
Signed-off-by: Your Name <you@example.com>
```

`git commit -s` adds it, with the name and email of your git settings, which must be the commit's author's (a name
you're known by, not an anonymous one). A check on every pull request looks for it; to add it to commits made
without it, `git rebase --signoff main` and push again.

- **Third-party code**: say where any code you didn't write comes from, and its licence. Code copied from elsewhere
  comes in only by exception, under a licence compatible with its part's: into `protocol/`, only permissive licences
  (MIT, BSD, Apache-2.0).
- **Across the parts**: code doesn't move from an AGPL part into `protocol/` (that would put it under MIT) unless
  everyone who wrote it agrees. Protocol code that both sides of a connection need is written in `protocol/` from the
  start.
- **AI tools** are fine to use; you're responsible for what you submit as if you'd written it all, and your sign-off
  covers it. Say in the pull request if a substantial part was generated, and point out anything you think may come
  from somewhere else.
- **Your employer**: if your employer may own what you write, make sure you have its permission first.

## How to work on it

- Building, testing and the code's conventions: [docs/development.md](docs/development.md).
- `make check` must pass (warnings are errors), and new behaviour comes with tests.
- No personal setup in docs, tests or fixtures: no real addresses, names or credentials. Camera specifics go in the per-vendor pages under [docs/cameras](docs/cameras/README.md).
- Detection models are added beside the built-in one, not in place of it: see [docs/detection.md](docs/detection.md).
