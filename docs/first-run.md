# First run

The plan for Pond's first run: someone who downloads it reaches a camera recording on their own, with no guide.
Planned, not built yet; the roadmap's *First run without a guide* ([roadmap.md](roadmap.md#release)).

## How it's judged

By watching: a fresh install, done by someone who isn't technical, timed. Each place they stall is a fix, and the
test is run again until it goes through without help.

## What a new user meets today

1. **"No settings yet"** (`SetupView`, PondApp.swift): the settings file's path and *Create Settings*, which saves
   settings recording to `/Volumes/Pond/recordings` (`AppModel.createSettings()`), a drive most people don't have.
   Pond then says its drive is missing until they find Settings › Storage.
2. **Add Camera** (`AddCameraSheet`, CamerasView.swift) is good already: cameras found on the network, the login
   and stream checked, how many days the drive will hold, the Home app offered as a last step.
3. **Nothing starts recording.** Adding a camera doesn't start the recorder (`installService()`, AppModel.swift, is
   only reached from *Start Recording* on the Recorder page and in the overview): the toolbar says *Not recording*
   until someone finds it.
4. **macOS asks without warning.** Local Network, the moment Pond looks for cameras (denied, nothing is found);
   the Keychain, for the recorder to read the cameras' passwords (*Always Allow*); notifications, at launch
   (`ServiceWatch.start`), before anything's set up.
5. **Search's picture model (about 350 MB) downloads unannounced.**
6. **The demo is hidden** in Settings › Advanced (`AdvancedSettings`).
7. **Nothing helps when a camera isn't found or won't connect.** Some cameras come with RTSP or ONVIF turned off;
   likely the most common place to stall.

## The wizard

Decided (2026-11-11): a wizard, holding the user's hand to a Pond's minimum settings; the demo is an escape hatch
for someone who only wants to look around, not a way through setup.

In the main window, in place of "No settings yet", until the minimum is reached: one thing a page, Back and
Continue, each page saying in a line why it's needed.

| # | Page | What happens | Built from |
|---|---|---|---|
| 1 | **Welcome** | What Pond is, in three lines: it records your cameras on this Mac, nothing leaves it, it works with the Home app. *Set Up Pond*; and, small, *Just look around: open the demo*. | `DemoSession.open` |
| 2 | **This Pond's name** | Prefilled with the Mac's; what other Ponds and devices will call it. | `Config.name` |
| 3 | **Where recordings go** | Drives listed, external first, each with "room for about N days of N cameras". The internal disk allowed, with a plain warning. The settings are made here, with no path shown. | `StorageOutlook`, `StorageEstimate`, `StorageLocation.prepare`, `AppModel.chooseFolder` |
| 4 | **Find your cameras** | A line before macOS's Local Network question ("so Pond can find cameras on your network"); then the cameras found; *Enter an Address*; *My camera isn't listed*: by make, how to turn on RTSP or ONVIF, linking the camera guides ([cameras/](cameras/README.md)). | `DiscoveryModel`, `CameraFinder` |
| 5 | **Add it** | Add Camera's pages in place: password, the check, the room on the drive. | `AddCameraSheet`'s pages |
| 6 | **Start recording** | The recorder installed and started without asking; a line before the Keychain's question (*Always Allow*); Open at Login on (done already on the first camera); then its live picture, *Recording*. **The minimum: here on, Pond is set up.** | `installService()`, `OpenAtLogin` |
| 7 | **Optional** | Each skippable, each there later: the Home app; notifications (asked here, with why, not at launch); Pond's sensor; descriptions and search ("downloads a 350 MB picture model", with its progress); the daily summary. | `HomeKitPairing`, `ServiceWatch`, `SensorPairingSheet` |
| 8 | **Done** | Into Live. A small *Getting started* list (another camera, the Home app, remote access) in the overview until done or dismissed. | the overview (`Attention`) |

### Rules

- **From Pond's real state, not a "seen" flag**: no settings, page 1; no drive, page 3; no camera, page 4; the
  recorder stopped, page 6. Quitting halfway comes back where it was, and someone already set up never sees it.
- **A line before each of macOS's questions**, saying what it's for, so the answer is the right one.
- **No paths or jargon on the way through**; the details (the folder, the camera's stream addresses) behind *More…*.
- **The demo's way out**: *Set up Pond*, back to the wizard.

## How it's built

1. **The real prompts, mapped**: a fresh install on a clean macOS user account, each of macOS's questions noted,
   its words and order, here.
2. **A way to try it** without touching a real Pond: the app pointed at an empty settings folder (`POND_CONFIG`),
   and a picture of each page from the snapshot mode (`POND_SNAPSHOTS_ONLY`, [development.md](development.md)).
3. **Pages 1–6**, the minimum.
4. **Pages 7–8.**
5. **The watched test**, its fixes, and again.
6. **The website's *Getting started***, from the same pages.

## To confirm when it's picked up

Recommended: the wizard in the main window (not a window of its own); the internal disk allowed, with a warning;
done when one camera is recording. Open: who tries it first.
