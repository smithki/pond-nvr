# Contributing to Pond

Thank you for helping. Pond is open source under the [GNU Affero General Public License v3.0](LICENSE).

> **Pull requests aren't accepted yet.** The Contributor License Agreement below is waiting for a lawyer's review,
> and the check that asks for it isn't running yet, so nothing from outside can be merged for now. Issues are
> welcome meanwhile: bugs (with a demo scenario or the doctor's report: [docs/demo.md](docs/demo.md)), cameras that
> do or don't work, and ideas. A vulnerability goes through [SECURITY.md](SECURITY.md), privately.

## Before your first pull request

Contributions are accepted under the [Pond Contributor License Agreement](CLA.md). You keep the copyright in your work. Every feature of Pond will always be open source; the agreement lets the project also offer it under other licences (for example, a commercial licence alongside the AGPL), and use contributions in companion apps such as an iPhone app, without having to find every contributor again. You'll be asked to sign it once, in your first pull request: a check on the pull request asks you to read it and post, as a comment of its own, the statement that signs it (a review or approval doesn't count). It records your GitHub account, the date, and the version of the CLA you signed (its version number and the SHA-256 of its text, a copy of which is kept). Nothing is merged before that. Contributions you made before signing are covered only if they're named in that pull request.

**What "always open source" means.** Every feature of Pond stays available under an open-source licence: today the AGPL-3.0, and in future the AGPL-3.0 or a later version, or another licence the Open Source Initiative approves. That's a promise of open-source availability, not of copyleft: a later version could be offered under a permissive licence (MIT, Apache) instead. A release already published keeps its licence for good. Companion apps for other platforms (an iPhone app, say) that work with Pond, and aren't meant as a standalone replacement for it, may be distributed under other terms, including proprietary ones.

- **Third-party code**: say where any code you didn't write comes from, and its licence. Pond's own code is kept free of third-party code that couldn't be relicensed, so code copied from elsewhere comes in only by exception, under its own licence; some (GPL or AGPL code, for instance) won't be accepted.
- **AI tools** are fine to use; you're responsible for what you submit as if you'd written it all. Say in the pull request if a substantial part was generated, and point out anything you think may come from somewhere else.
- **Your employer**: if your employer may own what you write, make sure you have its permission first. Contributions on a company's behalf may need an agreement signed by the company.
- **Examples and ideas** shared in issues and discussions aren't contributions unless you submit them for inclusion; mark anything you want kept out "Not a Contribution".

## How to work on it

- Building, testing and the code's conventions: [docs/development.md](docs/development.md).
- `make check` must pass (warnings are errors), and new behaviour comes with tests.
- No personal setup in docs, tests or fixtures: no real addresses, names or credentials. Camera specifics go in the per-vendor pages under [docs/cameras](docs/cameras/README.md).
- Detection models are added beside the built-in one, not in place of it: see [docs/detection.md](docs/detection.md).

## About the agreement

The CLA follows the shape of the Apache Software Foundation's Individual Contributor License Agreement, which the ASF allows to be reused and adapted, with the right to relicense made explicit, and a commitment that every feature of Pond stays open source. It is not legal advice, and is to be reviewed by a lawyer experienced in open-source licensing before contributions are taken under it. The draft is frozen until then; the questions for that review:

- Whether Section 5's open-source commitment, and its exceptions, hold as intended, and whether it survives every kind of transfer the agreement permits: an assignment of the agreement (Section 13, with the assignee's written assumption), and also a grant of broad sublicensing rights without one.
- The companion-app boundary (Section 1): that a full mobile companion is allowed, and a proprietary replacement for Pond isn't.
- The patent licence (Section 3), with the AGPL's own patent terms and proprietary sublicensing.
- The third-party material provisions (Sections 2, 5 and 7), and contributions with AI-generated material in them (Sections 6 and 8).
- That electronic acceptance (Section 14), with the records the signing process keeps, is enough.
