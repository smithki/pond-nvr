# Changelog

Newest first. "Unreleased" is everything since the last tag; there are no tags yet.

## Unreleased

The first version: recording, the app and HomeKit.

### Renamed: nvr is now Pond
- The command is `pond`, the app `Pond.app`. Settings are in `~/Library/Application Support/Pond/`, the log in `~/Library/Logs/Pond/`, the Keychain items under `pond` and `pond-homekit`, and the login service is `camera.pond.recorder`. Storage folders prepared before keep working (their `.nvr-storage` marker is copied to `.pond-storage`).
- **`pond migrate`** carries a setup from before over: it stops the old login service, moves the settings and the log, copies the camera passwords and each camera's HomeKit identity and pairings (so cameras stay in the Home app with their recordings), and installs the service again. `make app` runs it when it finds the old setup. macOS asks once per Keychain item whether Pond may read it.

### Recording
- **Continuous recording** (`pond run`): every camera's main stream with its sound, in 1-minute MP4 segments cut at keyframes (`<recordings>/continuous/<camera>/<YYYY-MM-DD>/<HH-MM-SS>.mp4`, UTC), never re-encoded. Written as `.partial` until complete and recovered after a crash. A camera that drops, goes silent or turns on privacy mode is reconnected with backoff; a lasting problem is repeated in the log every 5 minutes.
- **Storage folders** are used only while they hold the `.pond-storage` marker, so an unplugged drive or unmounted NAS share is reported instead of quietly filling the startup disk.
- **Retention**: continuous recording by days, an optional size cap and a free-space reserve (below it the oldest is overwritten); event clips by days, independently.
- **One connection per camera stream** (`StreamHub`): the recorder, HomeKit and the app's windows share it, and a late reader gets the video since the latest keyframe so pictures start at once.
- **The login service** (`pond service install|status|restart|uninstall`): `pond run` as a launchd agent that starts at login and again if it stops, holds off idle sleep while recording, and logs to `~/Library/Logs/Pond/pond.log` (rotated at 10 MB, one previous file kept).

### The app
- **Live**: a resizable rail of every camera and a stage of the chosen cameras, laid out as large as fits and animated as cameras come and go; double-click to watch one alone; drag to reorder; sound for one camera at a time; badges for a camera that is offline, sends no picture or has stopped being recorded, and its HomeKit state; today's events on hover.
- **Timeline**: any day's recordings, a lane per camera; scrubbing, skip, ½× to 16×, zoom from a day to 15 minutes, scrolling back across midnight, sound, and a LIVE mode.
- **Settings**: **Cameras** (Add Camera checks the camera, shows what it adds to storage and offers HomeKit; each camera's settings, check, HomeKit and removal with or without its recordings), **Storage** (the drive, how long it holds at the cameras' real rates, a checklist), **Retention** and **Recorder** (start, restart or stop the service; its log, filterable by source and kind).
- **Checks say what to do**: a camera's check gives its state in a word, the details and a button for the fix (Enter Password…, Change Address…, Open Privacy Settings).
- The app carries `pond` inside it, so the recorder can be started without installing anything else. Only `pond` reads the camera passwords; the app hands passwords to it and gets live video through the service.

### HomeKit
- **Native HomeKit Accessory Protocol** in Swift: SRP-6a pair setup, pair verify, encrypted sessions, the accessory database, events, timed writes, Bonjour. Each camera is a standalone accessory, added from the app or with `pond camera set ID --homekit on`; its identity and pairings are kept in the Keychain (`pond-homekit`).
- **Snapshots, live video and sound**: the camera's H.264 over SRTP (sub-stream, or main for a viewer with the bandwidth, switching on a reconfigure), the camera's AAC converted to AAC-ELD, 1–4 viewers at once on one camera connection.
- **Optional re-encoding** for the Home app (`homekitVideo`): the main stream sized and encoded per viewer on the Mac's video hardware, adapting to each viewer's connection from its RTCP reports.
- **HomeKit Secure Video** (`homekitRecording`, "Allow recording in the Home app"): the HomeKit Data Stream, the recording services, a prebuffer, and recordings re-encoded to the hub's choice, started by the camera's own motion (Reolink). The app shows whether a camera is recording, its last clip, and why it won't record.
- **Doorbells**: a video doorbell accessory that rings on a press of a Reolink doorbell's button, and records to HomeKit Secure Video on motion or a ring.

### Cameras
- **Camera checks** (`pond camera add`, `test`): Digest login, both streams' codecs and resolutions, then the video's frame rate, keyframe spacing and bitrate, with warnings about privacy mode, H.265 and keyframes too far apart.
- **Device details** (`pond camera identify`): maker, model, serial number, firmware and doorbell, from Reolink's API or ONVIF.
- **Stream addresses found for you**: adding a camera asks it where its streams are, through its make's API (Reolink) or ONVIF (its media profiles), and they can be typed or changed in Add Camera and the camera's settings; `pond camera add --main --sub` gives them by hand. `pond camera onvif ID` shows what a camera says over ONVIF, step by step.
- Camera passwords are kept in the login Keychain (service `pond`), never in the settings file.

### The `pond` command
- Settings (`init`, `check`), storage, retention, cameras (`list`, `add`, `set`, `password`, `test`, `record`, `rename`, `move`, `remove`, `identify`), the login service and HomeKit (`homekit code`, `reset`, `snapshot`). The app and the command save through the same code.

### Known gaps
- Only H.264 cameras; H.265 is not supported yet.
- Motion for HKSV and doorbell presses come from Reolink's API only; other brands need ONVIF events.
- Detection, event clips, descriptions and search are not built yet; the Events view shows made-up events with `POND_MOCK_EVENTS=1`.
- Zones are edited by hand in the settings file.
- `make test-docker` has not been run yet.
