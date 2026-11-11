# Tests

The tests are Swift Testing suites in each package's `Tests/` folder ([`../protocol/Tests/`](../protocol/Tests/), [`../recorder/Tests/`](../recorder/Tests/), [`../macos/Tests/`](../macos/Tests/)), one folder per module. The signaling service has none of its own: the recorder's remote tests run it.

```sh
make test          # all of them, on the Mac
make test-docker   # the modules that build on Linux, in a throwaway container
```

They never touch system folders: they write only temporary files and clean up after themselves, so `make test` is safe on a Mac.

Modules that use Apple frameworks (VideoToolbox, Core ML, Foundation Models, Network) are left out of the Linux build by the `Package.swift` files, so `make test-docker` covers less than `make test`. Fixtures that need real camera output (captured RTSP sessions, sample frames) go in `../<package>/Tests/<Module>Tests/Fixtures/`.
