# Changelog

What's in each release. What's been built, goal by goal and how, is in [docs/done.md](docs/done.md).

## Unreleased

## 0.2.0

### Search
- **The picture model is downloaded by Pond**, not built into the app (the download is about 350 MB smaller): on
  first run, the version pond.camera names, signed by Pond's own key and checked before it's used. Pond checks once a
  week for a new version (Settings › General: Download picture model updates, and Check for Updates), and while a
  new one indexes every event again, search keeps finding them all.

### Updates
- **Pond updates itself** (Sparkle): Pond › Check for Updates…, and checking daily by itself (Settings › Advanced).
  An update is installed only if it's signed with Pond's update key and Developer ID; after one, the recorder starts
  again on the new copy.

### Making Pond
- **The models aren't in the repository**: builds download the published ones by their locks, checked by hash
  (YOLO26 with its source, as its licence asks).
- **Releases from a tag on CI**, or made and published on a Mac when CI can't (`make publish`).

## 0.1.0

The first version.

### Recording
- **Continuous recording** of every camera to a drive of your choice, in 1-minute MP4 files: the camera's own H.264 or H.265 and its sound, never re-encoded (or its sub-stream, per camera, to save room). Retention by age, size and free space; nothing is written to a drive that isn't there.
- **One connection per camera stream**, shared by recording, live views, HomeKit and detection.
- **The recorder** runs in the background as a login service (`pond service install`, or Start Recording in the app), and is watched: a notification says when it stops recording, with the fix.
- **A budget for the Mac's media engine**: when there's more video work than it can do, the least important (closer looks, then detection) gives way first, and HomeKit recordings never do.

### The app
- **Live**: every camera live, with sound, in a rail beside a stage of the ones chosen; camera controls under one watched on its own.
- **Timeline**: any day's recordings, a lane per camera, with events and private stretches marked.
- **Events**: what the cameras saw, a card each, by day, with plain-language search.
- **Settings** for cameras (added by address, or found on the network), storage, retention, remote access and the recorder (with its log); **the camera doctor**, saying what's going wrong with a camera and what to try.
- **A menu bar item**: recording or not, each camera's privacy, and Pond's window a click away.
- Narrow windows, down to the smallest.

### HomeKit
- Each camera chosen is a camera (or video doorbell) in the Home app, natively (the HomeKit Accessory Protocol, in Swift): snapshots, live video and sound, several viewers at once, optional re-encoding for each viewer, talking back, and **HomeKit Secure Video**.

### Cameras
- Reolink through its own API and protocol (Baichuan); others through ONVIF and RTSP. Discovery, PTZ and positions, day and night, picture settings, volume, two-way audio, privacy (and the camera's own privacy mode, both ways).

### Detection, events, search
- People, vehicles, bikes, animals, and items left, found on the Mac (Core ML, a built-in model or one of your own), with zones; each event's picture and clip kept.
- Each event described in a sentence, and found by plain-language search ("a courier at the front door this week"), with Apple's on-device models only.

### Away from home
- **Other Ponds**, paired with a code, peer to peer and end-to-end encrypted, through a signaling service you run yourself (`deploy/`): their cameras live, their events and search, and their timeline, beside this Mac's; told when one stops recording. Directly, through a relay of your own, or only over your mesh (Tailscale, Headscale).

### Demo mode
- Made-up cameras to explore Pond with, recorded and watched like real ones, in worlds of their own: a home with a second home to reach, many cameras, things going wrong, a first run (`make demo`, or Settings › General).

### The `pond` command
- Everything from a terminal: settings, cameras, storage, retention, the login service, HomeKit codes, detection and search, remote access, demo mode (`pond help`).
