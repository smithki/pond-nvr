# Contributing to Pond

Thank you for helping. Pond is open source under the [GNU Affero General Public License v3.0](LICENSE).

## Before your first pull request

Contributions are accepted under the [Pond Contributor License Agreement](CLA.md). You keep the copyright in your work; the agreement lets the project change or add licences in the future (for example, a commercial licence alongside the AGPL) without having to find every contributor again. You'll be asked to sign it once, in your first pull request.

## How to work on it

- Building, testing and the code's conventions: [docs/development.md](docs/development.md).
- `make check` must pass (warnings are errors), and new behaviour comes with tests.
- No personal setup in docs, tests or fixtures: no real addresses, names or credentials. Camera specifics go in the per-vendor pages under [docs/cameras](docs/cameras/README.md).
- Detection models are added beside the built-in one, not in place of it: see [docs/detection.md](docs/detection.md).
