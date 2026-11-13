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

**Pictures of the app.** `POND_SNAPSHOTS=<folder>` makes the app save each view of the main window, each page of the Settings window (this Pond's settings, HomeKit with a made-up mix of cameras in the Home app (in memory only: a demo serves nothing to HomeKit), the recorder, every camera, the first camera's Doctor and Settings, another Pond's camera) and a camera's settings panel as PNGs and quit, with three reports beside them: `sidebar.txt` (the Settings sidebar’s bounds, held as its divider is moved past each end, that it can’t be closed, and that both its layers’ first rows start at the same height), `resize-timing.txt` (each step's time, laying out and drawing General, a camera's Doctor and the Recorder as the window is resized from its least width to its most and the sidebar is resized, in 20 steps each; under ~16 ms a step is smooth) and `scrolling.txt` (on the Recorder and the busiest camera’s Doctor page at the window’s least size: the scroll views on the page, only the page’s with a scroll bar, and how far the page scrolls), with pictures of each log’s Show All… sheet; it draws its own window, so no screen-recording permission is needed. `POND_SNAPSHOTS_ONLY=<names>` (comma separated) takes only the pictures and reports whose names begin with one of them, skipping the rest: `--env POND_SNAPSHOTS_ONLY=cameras-settings` takes a camera's settings page and a private camera's in a few seconds. With `POND_CONFIG` it can show any settings file:

```sh
open -n -W --env POND_CONFIG=/tmp/pond/config.json --env POND_SNAPSHOTS=/tmp/pond/shots "dist/Pond NVR.app" --args -ApplePersistenceIgnoreState YES
```

(Liquid Glass comes out flatter in these pictures than on screen.) `--search QUESTION` opens Events with that question asked. For the real thing, `scripts/capture-window.swift` opens a fresh copy of the app in the background, captures only its main window and quits it; it needs screen-recording permission for the terminal:

```sh
swift scripts/capture-window.swift /tmp/events.png --mode events --appearance light
swift scripts/capture-window.swift /tmp/inactive.png --inactive   # as it looks behind another app's window
```

 `--mode live|timeline|events` opens a view first, and `--settings general|storage|remote|homekit|advanced|recorder|cameras` also opens the Settings window at that page, `--doctor [ID [settings]|recorder]` at a camera's Doctor or Settings tab, or the recorder; `--camera ID` opens that camera's settings panel over the main window, `--overview` opens the toolbar's overview, `--fake-new-events N` makes up N new events, for their dot on Events and their count in the menu bar item (one more every 4 s, cleared by opening Events), and `--live` starts the timeline live.

**Trying animations.** Live behaviour is hard to describe, so reproduce it: a temporary environment switch that drives the motion in question, rapid `screencapture -l` frames of the window, and an ffmpeg contact sheet of them; exaggerating the duration or scale makes the geometry easy to measure. Take the switch out again afterwards.

**Events' smoothness, timed.** The snapshot step `transitions` drives the Events view as someone would (far jumps, the panel opened and closed near the top and far down, arrow steps), three rounds, and writes `transitions.txt`: for each kind, the slowest wait on the main thread, the 95th percentile, and how many waits were over 16 ms (a frame missed at 60 Hz) and over 33 ms. Run it on a large library: `POND_DEMO_EVENTS=20000` fills the demo with that many events over the week first (once; kept after).

```sh
make app APP="dist/demo/Pond NVR.app"
open -n -W --env POND_SNAPSHOTS=$(mktemp -d) --env POND_SNAPSHOTS_ONLY=transitions --env POND_DEMO_EVENTS=20000 \
  "dist/demo/Pond NVR.app" --args --demo home
```

The step `panels` does only the detail panel, opened and closed 20 times (near the top, then far down), and writes `panels.txt`: with little else going on, it's the one to run under `sample`. Both steps keep macOS from napping the app while they run (a hidden window's timers are otherwise slowed, and the check timed its own naps), but a window behind others is still drawn less faithfully: compare two builds run the same way, one after the other, rather than against figures from another day.

**The Events page in AppKit (while it's made).** `defaults write camera.pond eventsAppKitGrid -bool true` (the demo's: `camera.pond.demo`) draws the page with `EventsShell`: the grid (`EventGridAppKit`, layer-backed cards), the rail and the detail panel laid out and moved by one AppKit view, every move run by Core Animation on one curve; what's in the rail and the panel is SwiftUI's, hosted. Off (the default), the SwiftUI page as before. Compare the two with the `panels` step, one after the other.

`POND_STALLS=1` (any run) logs each main-thread wait over 40 ms with what the grid was doing then (`/usr/bin/log stream --predicate 'subsystem == "camera.pond" AND category == "frames"'`). To find what a stall is, `/usr/bin/sample <pid> 30` during the check; for the main thread's own code, sum the samples under functions `in PondApp`.

**Trying it without a camera.** Demo mode (`make demo`, [demo.md](demo.md)) has made-up cameras recorded, watched and controlled like real ones, a second home to reach, H.265 cameras, and scenarios for what goes wrong, in a world of their own.

**Probes against real recordings.** Two tests run only when pointed at a real setup, for questions the made-up streams can't answer:
- `BoxTimingProbe` (Watch): how far detection's boxes are out from the recorded picture, by running the model again on recordings around each sighting. `POND_PROBE_BASE=<recordings> POND_PROBE_CAMERA=<id> POND_PROBE_DB=<pond.sqlite> POND_MODELS=<models> swift test --package-path recorder --filter BoxTimingProbe`.
- `RealLiveEdgeProbe` (the app): where the timeline's live edge sits on a camera's real recordings. `POND_PROBE_BASE=<recordings> POND_PROBE_CAMERA=<id> swift test --package-path macos --filter RealLiveEdgeProbe`.

They read the recordings and database without changing them.

**The soak, for video decoding's memory.** Decoded pictures live in macOS's video decoder service and the kernel, not in Pond's own memory, so a leak there doesn't show in Pond and isn't caught by the usual tests; one froze a 16 GB Mac in under an hour. After changing anything that decodes video (detection, the closer looks, HomeKit's re-encoding), run `scripts/soak.sh`: made-up cameras (8 at 4K by default, their video generated on the Mac, none needed) decoded as the service decodes them, for a few minutes, passing if the decoder service and wired memory stay flat. `--quick` is 2 cameras for 30 s; `--cameras`, `--size`, `--minutes`, `--recording` and `--taps` change the scene. A watchdog outside the test stops it at an eighth of the Mac's memory in the decoder service, and nothing it starts is left running, whatever happens. In the running service, `VideoMemoryGuard` does the same job (and logs the decoder service's size hourly).

The code is in four packages, one per part ([architecture.md](architecture.md)): `protocol/`, `signaling/`, `recorder/` and `macos/`. `swift build --package-path macos` builds them all, and Xcode works too (open `macos/Package.swift`, or a part's own).

**Toolchain.** Swift Testing and the default build system need Xcode's toolchain. If `xcode-select -p` says `/Library/Developer/CommandLineTools`, the Makefile sets `DEVELOPER_DIR` to Xcode for its own commands. Running `swift` by hand, either do the same (`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`) or switch for good with `sudo xcode-select -s /Applications/Xcode.app`.

## Footage stays private

No one's recordings, event pictures, snapshots, test scenes or Pond database (camera names, times, what was seen) are kept in the repository or shared with contributors or other users: not the maintainers' own, not a user's in a bug report. `scripts/check-private.sh` refuses any recording, picture or database file (it runs in `make check`; `make hooks` adds it as a pre-commit hook), unless `scripts/private-allowlist.txt` names it: made-up media only, such as a test pattern or a drawing of the demo's, each with why. A bug's shown with a demo scenario ([demo.md](demo.md)) or the doctor's report, which leaves out addresses, passwords and pictures.

What a Pond learns from its owner (events said to be nothing or something, the rules and likenesses from them, any tuning) stays in that Pond's own database, on its Mac; nothing of it is sent anywhere, and no Pond learns from another's cameras.

## How detection changes are judged

Everything every Pond starts with (detection's thresholds, the tracker's rules, what quiets an event) changes only on evidence anyone can see and run again, so no one home's cameras decide what all homes get:

- **Many homes, numbers only:** each Pond keeps test scenes of its own (beside its database, on its Mac: the events its owner said weren't anything or were something, and some they saw and kept), and `pond advanced scenes --json` replays them through a build and reports only the scores; testers send those, never footage. A change has to hold up across homes, not in one, and above all not hide what anyone said mattered.
- **Public footage, later:** datasets whose terms allow it, downloaded to the Mac that runs them, never kept here: for what no home's scenes can show (a detector's blind spots: what it never noticed doesn't become an event, so isn't in anyone's scenes).
- **One home finds, it doesn't decide:** a problem seen on one's own cameras (a parked car that kept an event going all night, say) says what to look into; the fix is made general, and its numbers are chosen and checked on shared scenes before it ships.

Learning from one's own feedback is a Pond's own business, tuned for its own cameras and checked against examples held back from what it learned from (so it's never graded on what it was taught, and never hides what its owner said mattered).

## Where things go

- One module per responsibility; the table is in [architecture.md](architecture.md).
- Code that needs only Foundation stays free of Apple frameworks, so it is tested on Linux too. Modules that need Apple frameworks are added to their package's `Package.swift` inside `#if os(macOS)`; the protocol (`protocol/`) depends on nothing of Pond's, and each package only on the ones before it ([architecture.md](architecture.md)).
- Each module has a test target, `<package>/Tests/<Module>Tests/`.
- The app's views are in `PondApp`; everything they change goes through `AppModel` (tested in `macos/Tests/PondAppTests/`).
- `pond` commands live in `PondCLI` (`CLI.swift`, `CameraCommands.swift`); `recorder/Sources/pond/main.swift` only wires in the real terminal, Keychain and network. Test a command with `Harness` in `recorder/Tests/PondCLITests/Fakes.swift`.
- Code ported from HAP-NodeJS or HomeKitADK names its source file in a comment.

## Adding a setting

1. The field in `Config` (`recorder/Sources/PondCore/Config.swift`). A new optional field needs a default when it is missing, so older files still load.
2. Its check in `Config.problems()`, as a sentence.
3. A test in `recorder/Tests/PondCoreTests/ConfigTests.swift`.
4. A command to change it in `PondCLI`, its line in `CLI.help`, and a test in `recorder/Tests/PondCLITests/`.
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
- **Settings pages share one layout** (`PageLayout.swift`). Every page's cards are one width (`PageMargin`: at most 704 pt, centred, at least 30 pt from the sides), on this Pond's pages and a camera's alike: a page is a grouped form with `pageForm()`, and anything beside a form uses `besideForm()`. A page that doesn't fit scrolls as a whole. A log (the recorder's, a camera's What happened) shows only its newest lines in the page's last section (`LogPage`, `PageCard`), one height on every page and not scrolling; Show All… opens the whole log in a sheet (`FullLogSheet`), so a page never has a scroll bar inside its own. The window is never wider than the sidebar at its widest beside a page at its first width (`SettingsWindow.mostWidth`): any wider would only widen the margins.
- **Errors say what happened in plain words** and name only a cause the error itself shows; a problem with a fix comes with the button for it.

## Message style

For the `pond` command's output and the log:

- `✓` progress lines are lowercase fragments; a command's final result is a capitalized sentence.
- `!` warnings and `✗` errors are capitalized sentences ending in a period (no period after a trailing command or path).
- Say HomeKit, HKSV, RTSP, macOS. No first person, no shouting, single spaces.

**HomeKit.** `HAP` and `HAPCamera` use CryptoKit and VideoToolbox, so their tests run on the Mac only (`make test`), not in `make test-docker`. The pairing tests drive the accessory with a controller written in the tests, so the SRP values are also checked against a port of fast-srp-hap (`SRPTests.matchesFastSRPHAP`): a misreading shared by both sides would otherwise pass. To try pairing for real, stop the login service, run `dist/pond homekit` and add the accessory in the Home app; it logs each pairing step. `make build` replaces `dist/pond` rather than overwriting it, because macOS kills programs started from a file rewritten while another copy runs.
