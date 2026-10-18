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
- **HomeKit Secure Video** (`homekitRecording`, "Allow recording in the Home app"): the HomeKit Data Stream, the recording services, a prebuffer, and recordings re-encoded to the hub's choice, started by the camera's own motion (Reolink's API, or any camera's ONVIF events). The app shows whether a camera is recording, its last clip, and why it won't record.
- **Doorbells**: a video doorbell accessory that rings on a press of a Reolink doorbell's button, and records to HomeKit Secure Video on motion or a ring.

### Cameras
- **Camera checks** (`pond camera add`, `test`): Digest login, both streams' codecs and resolutions, then the video's frame rate, keyframe spacing and bitrate, with warnings about privacy mode, H.265 and keyframes too far apart.
- **Device details** (`pond camera identify`): maker, model, serial number, firmware and doorbell, from Reolink's API or ONVIF.
- **Finding cameras**: Add Camera lists cameras on the network that aren't set up (picking one fills in its address and its own name), and the toolbar's Find Cameras looks on a click and turns into Cameras Found, with a count, for new ones until added or ignored (by MAC address when known; listed apart to show again, and left out of Add Camera unless asked for). Found every way at once: ONVIF discovery, Reolink's own discovery, and a quick look at the local network for RTSP or ONVIF; when Pond opens, daily, and when Add Camera opens. `pond camera discover`.
- **Talks through**: each camera's settings say plainly how Pond talks to it, and switch it between its make's own API (Reolink), ONVIF and **Video only** (no logins but for its video; its motion and button aren't watched, and HomeKit Secure Video pauses, keeping its setting). `pond camera identify ID --provider reolink|onvif|video` does the same.
- **Motion over ONVIF**: Pond subscribes to an ONVIF camera's events, and its motion, person, vehicle and animal detection drive HomeKit's motion sensor (so HomeKit Secure Video records cameras of any make with ONVIF events); a doorbell's visitor event rings. `pond camera onvif ID --events` prints them as they come.
- **Stream addresses found for you**: adding a camera asks it where its streams are, through its make's API (Reolink) or ONVIF (its media profiles), and they can be typed or changed in Add Camera and the camera's settings; `pond camera add --main --sub` gives them by hand. `pond camera onvif ID` shows what a camera says over ONVIF, step by step.
- Camera passwords are kept in the login Keychain (service `pond`), never in the settings file.

### Camera controls
- **The controls dock**: under a camera watched on its own (⌥⌘L, or Control This Camera in its menu), what the camera can do and only that: a move pad, its kept positions with a picture of what each shows (keep, remove, drag to reorder, More for the rest), home and preset tours, zoom, day and night, a still saved to Pictures › Pond, talking through its speaker and its volume. It's as wide as what's in it, from three layouts.
- **Adjustments**: the camera's other settings, by group (Picture, Light, Sound, Device): brightness, contrast, saturation, sharpness, IR lights, the status light, mirror and flip, restarting it, setting home, relays, and whatever its make's API adds. In a sidebar beside the stage; in a narrow window, the dock's second frame, its edge sliding the controls aside, a page per group.
- **Talking back** over ONVIF's RTSP backchannel (G.711), from a tile or the dock.
- **The best way for each control**: every control goes through the camera's chosen way, then its make's own API, then ONVIF, passing over one that turns out not to work; one shared login per camera (cameras allow only a few). Reolink's API serves PTZ, positions, day and night and volume; ONVIF the rest.
- **Privacy**: any camera can be made private (in the dock, the list's menu or its settings): not recorded, shown live or served to HomeKit, where it shows as off, until turned off; applied at once, and kept across restarts. The Home app's own camera off stays HomeKit's and never turns privacy off. `pond camera privacy ID [on|off]`.
- **Reolink's own protocol (Baichuan)**: one lasting connection per Reolink camera (TCP 9000). Privacy mode in step with Pond's both ways, and motion, detections and doorbell presses pushed as they happen instead of asked each second (over HTTP still for a camera that doesn't answer there). `pond camera baichuan ID [watch | privacy-on | privacy-off]`.
- **Back from privacy**: a camera whose own privacy mode turned off is *waking* until its video returns (shown as Waking up, not as can't connect, and not a problem for the doctor). While a camera is private or waking, moving it, talking through it and its actions are off; its settings wait and are set, one at a time, once it's back.
- **HomeKit Secure Video, steadier**: a camera's AAC sound is written with each frame its 1024 samples (a camera that sends its sound in bursts made frames of a few milliseconds), in HomeKit's recordings and Pond's own; a doorbell's button is no longer linked to its recording service (as HAP-NodeJS has it); the end of motion is logged; and a camera's doctor page says when its last clip was sent, with what to do if the Home app never shows them ([docs/doctor.md](docs/doctor.md#homekit-secure-video)). An accessory's services are read in the log, and recordings can be kept as files while looking into them (`hksv-dump`).
- **Talking back from the Home app**: a camera that can be talked through has a Speaker in HomeKit, and the Home app's talk button reaches its speaker during a live view (through the same way the app talks to it, the ONVIF backchannel).
- **The doctor, finished**: a mark in the camera list as on a tile (and Doctor… in its menu), **Run Check Now** on a camera's page (its video for a few seconds and its controls, only when asked), and the rules' **Thresholds** as an advanced setting. [docs/doctor.md](docs/doctor.md).
- **The doctor: video that didn't come back after privacy mode** (the camera's video server stuck while its controls answer), until it does; restart it.
- **Settings as last known are kept** (`camera-values.json`), so after a restart one already as the camera has it isn't queued, and the dock shows a private camera's settings.
- **Privacy changed in the Reolink app while Pond wasn't connected stands**: on connecting again, Pond puts the camera right only if its own change never reached it.
- `pond camera controls|ptz|item|night-mode|talk|abilities` try them from a terminal ([docs/controls.md](docs/controls.md)).

### The `pond` command
- Settings (`init`, `check`), storage, retention, cameras (`list`, `add`, `set`, `password`, `test`, `record`, `rename`, `move`, `remove`, `identify`), the login service and HomeKit (`homekit code`, `reset`, `snapshot`). The app and the command save through the same code.

### Known gaps
- Only H.264 cameras; H.265 is not supported yet.
- Detection, event clips, descriptions and search are not built yet; the Events view shows made-up events with `POND_MOCK_EVENTS=1`.
- Zones are edited by hand in the settings file.
- `make test-docker` has not been run yet.
- ONVIF home, preset tours and relays are built to the standard but not yet tried on a camera that has them.
