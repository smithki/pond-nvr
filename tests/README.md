# Tests

The tests are Swift Testing suites in the package, under [`../src/Tests/`](../src/Tests/), one folder per module.

```sh
make test          # all of them, on the Mac
make test-docker   # the modules that build on Linux, in a throwaway container
```

They never touch system folders: they write only temporary files and clean up after themselves, so `make test` is safe on a Mac.

Modules that use Apple frameworks (VideoToolbox, Core ML, Foundation Models, Network) are left out of the Linux build by `Package.swift`, so `make test-docker` covers less than `make test`. Fixtures that need real camera output (captured RTSP sessions, sample frames) go in `../src/Tests/<Module>Tests/Fixtures/`.
