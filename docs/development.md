# Development

## Build, check, test

Once per Mac, before the first build:

```sh
make signing       # a local code-signing certificate (scripts/setup-signing.sh)
```

pond keeps camera passwords and the HomeKit record in the login Keychain, which ties "Always Allow" to the program's signature. Ad hoc signing gives each build a new one, so the Keychain would ask again after every rebuild (and a background `pond homekit` would wait on a dialog nobody sees). With "Pond Local Signing", a self-signed certificate made on your Mac, every build is the same program to the Keychain: allow once and it holds. The key stays in your keychain, usable only by `codesign`; it is not part of the repo. Without it the Makefile signs ad hoc and says so.

**Fewer prompts still: an Apple Development certificate.** A self-signed certificate has no team ID, and macOS's Keychain also keeps a *partition list* on each item, which for such code holds each build's own hash: so after a rebuild, the first read of each password asks once more (the service, waiting on that dialog, starts late). An Apple Development certificate carries your team ID, which the partition list holds instead, so rebuilds are trusted with no prompt. Any Apple ID will do (no paid membership): Xcode › Settings › Accounts › add the Apple ID › Manage Certificates › + › Apple Development. The Makefile then signs with it on its own; allow each password once more after the first build with it.

```sh
make build         # dist/pond (release)
make check         # compile everything, tests included, with warnings as errors
make test          # every test, on the Mac
make test-docker   # the modules that build on Linux, in a throwaway container
make app           # dist/Pond NVR.app
```

**Pictures of the app.** `POND_SNAPSHOTS=<folder>` makes the app save each view of the main window and each Settings tab as PNGs and quit; it draws its own window, so no screen-recording permission is needed. With `POND_CONFIG` it can show any settings file:

```sh
open -n -W --env POND_CONFIG=/tmp/pond/config.json --env POND_SNAPSHOTS=/tmp/pond/shots "dist/Pond NVR.app"
```

(Liquid Glass comes out flatter in these pictures than on screen.) `--search QUESTION` opens Events with that question asked. For the real thing, `scripts/capture-window.swift` opens a fresh copy of the app in the background, captures only its main window and quits it; it needs screen-recording permission for the terminal:

```sh
swift scripts/capture-window.swift /tmp/events.png --mode events --appearance light
swift scripts/capture-window.swift /tmp/inactive.png --inactive   # as it looks behind another app's window
```

 `--mode live|timeline|events` opens a view first, and `--settings general|cameras|storage|retention|recorder` also opens Settings on that tab; `--camera ID` opens that camera's settings, and `--live` starts the timeline live.

**Trying animations.** Live behaviour is hard to describe, so reproduce it: a temporary environment switch that drives the motion in question, rapid `screencapture -l` frames of the window, and an ffmpeg contact sheet of them; exaggerating the duration or scale makes the geometry easy to measure. Take the switch out again afterwards.

**Trying the timeline without a camera.** Any H.264 MP4 copied into `<recordings>/continuous/<camera>/<YYYY-MM-DD>/<HH-MM-SS>.mp4` (UTC) shows up, for example a minute of test pattern made with `ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=20 -t 60 -c:v libx264 -pix_fmt yuv420p seg.mp4`, copied under successive names, with a settings file of its own (`POND_CONFIG`).

The package is in `src/`; `swift build --package-path src` and Xcode (open `src/Package.swift`) work too.

**Toolchain.** Swift Testing and the default build system need Xcode's toolchain. If `xcode-select -p` says `/Library/Developer/CommandLineTools`, the Makefile sets `DEVELOPER_DIR` to Xcode for its own commands. Running `swift` by hand, either do the same (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) or switch for good with `sudo xcode-select -s /Applications/Xcode.app`.

## Where things go

- One module per responsibility; the table is in [architecture.md](architecture.md).
- Code that needs only Foundation stays free of Apple frameworks, so it is tested on Linux too. Modules that need Apple frameworks are added to `Package.swift` inside `#if os(macOS)`.
- Each module has a test target, `src/Tests/<Module>Tests/`.
- The app's views are in `NVRApp`; everything they change goes through `AppModel` (tested in `src/Tests/NVRAppTests/`).
- `pond` commands live in `NVRCLI` (`CLI.swift`, `CameraCommands.swift`); `Sources/pond/main.swift` only wires in the real terminal, Keychain and network. Test a command with `Harness` in `src/Tests/NVRCLITests/Fakes.swift`.
- Code ported from HAP-NodeJS or HomeKitADK names its source file in a comment.

## Adding a setting

1. The field in `Config` (`src/Sources/NVRCore/Config.swift`). A new optional field needs a default when it is missing, so older files still load.
2. Its check in `Config.problems()`, as a sentence.
3. A test in `src/Tests/NVRCoreTests/ConfigTests.swift`.
4. A command to change it in `NVRCLI`, its line in `CLI.help`, and a test in `src/Tests/NVRCLITests/`.
5. A row in [configuration.md](configuration.md) and a line in [CHANGELOG.md](../CHANGELOG.md).

## The app's conventions

- **Notes sit under the row they explain**: `LabeledContent { control } label: { Text(title); Text(note) }`, or a picker whose label has two texts; never loose text at the end of a section.
- **A choice between two values** (camera or doorbell) is a segmented control, not a menu.
- **The toolbar uses native items.** Custom glass in the toolbar hung the layout. A control that belongs to one view (the rail's toggle) is added and removed with it, not hidden.
- **A panel whose content changes height is a card in the window, not a popover.** A popover is a window of its own, and AppKit animates its resizing out of step with SwiftUI, so everything in it jitters. Find Cameras' card is an overlay with Liquid Glass and an arrow pointing at its toolbar button (`Callout.swift`), so it grows and shrinks like any view.
- **Glass is never drawn into a drag image**: drags get a plain preview (`DragPreview`); drawing glass that way crashed the app.
- **Vendor-neutral wording**: name a camera's own app only through its provider (`appName`, "the Reolink app"), else "the camera's own app". Say "ID", HomeKit, HKSV, RTSP, macOS.
- **The timeline's live mode is only ever chosen** by the viewer (LIVE or L); playing recording pauses at its end rather than switching to live.
- **The live view's spacing across lives in `LiveLayout`** (the rail's padding, the dock's inset, the adjustments' sidebar, the narrowest dock and the window's minimum). The view is laid out with those values and the dock works out its room from them, so a padding changed anywhere else breaks which arrangement it chooses and whether the rail or sidebar fits. Two checks log a fault (subsystem `camera.pond`, category `layout`) when that happens: the room worked out disagrees with the room laid out, or a camera's narrowest dock is wider than `narrowestDock` (an everyday control was added: measure again, and raise it and the window's minimum).
- **Errors say what happened in plain words** and name only a cause the error itself shows; a problem with a fix comes with the button for it.

## Message style

For the `pond` command's output and the log:

- `✓` progress lines are lowercase fragments; a command's final result is a capitalized sentence.
- `!` warnings and `✗` errors are capitalized sentences ending in a period (no period after a trailing command or path).
- Say HomeKit, HKSV, RTSP, macOS. No first person, no shouting, single spaces.

**HomeKit.** `HAP` and `HAPCamera` use CryptoKit and VideoToolbox, so their tests run on the Mac only (`make test`), not in `make test-docker`. The pairing tests drive the accessory with a controller written in the tests, so the SRP values are also checked against a port of fast-srp-hap (`SRPTests.matchesFastSRPHAP`): a misreading shared by both sides would otherwise pass. To try pairing for real, stop the login service, run `dist/pond homekit` and add the accessory in the Home app; it logs each pairing step. `make build` replaces `dist/pond` rather than overwriting it, because macOS kills programs started from a file rewritten while another copy runs.
