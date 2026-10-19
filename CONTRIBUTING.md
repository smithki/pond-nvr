# Contributing to Pond

Thank you for helping. Pond is open source under the [GNU Affero General Public License v3.0](LICENSE).

## Before your first pull request

Contributions are accepted under the [Pond Contributor License Agreement](CLA.md). You keep the copyright in your work. Pond will always be open source; the agreement lets the project also offer it under other licences (for example, a commercial licence alongside the AGPL) without having to find every contributor again. You'll be asked to sign it once, in your first pull request; nothing is merged before that.

- **Third-party code**: say where any code you didn't write comes from, and its licence. Code copied from elsewhere can only come in under its own licence, and some (GPL or AGPL code, for instance) may not be accepted.
- **Your employer**: if your employer may own what you write, make sure you have its permission first. Contributions on a company's behalf may need an agreement signed by the company.
- **Examples and ideas** shared in issues and discussions aren't contributions unless you submit them for inclusion; mark anything you want kept out "Not a Contribution".

## How to work on it

- Building, testing and the code's conventions: [docs/development.md](docs/development.md).
- `make check` must pass (warnings are errors), and new behaviour comes with tests.
- No personal setup in docs, tests or fixtures: no real addresses, names or credentials. Camera specifics go in the per-vendor pages under [docs/cameras](docs/cameras/README.md).
- Detection models are added beside the built-in one, not in place of it: see [docs/detection.md](docs/detection.md).
