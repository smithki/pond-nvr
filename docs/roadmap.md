# Roadmap

What is done and what comes next. The build phases are in [architecture.md](architecture.md#phases); this page has the detail.

Status: **done**, **in progress**, **next**, **later**.

## Recording and the app

| Goal | Status | Notes |
|---|---|---|
| Continuous recording | done | 1-minute MP4 segments per camera, the camera's own video and sound, retention by age, size and free space. |
| Live view | done | Every camera, main or sub-stream by tile size, sound for one camera at a time, health badges. |
| Timeline | done | Any day, a lane per camera, scrubbing, speeds, zoom, sound, live mode. |
| One connection per camera stream | done | `StreamHub` in the service, shared with the app's windows through `StreamRelay`; many cameras serve only a few connections. |
| Storage and retention settings | done | Days the drive holds from real rates, the drive as a bar, a checklist (startup disk, Spotlight, format), a new camera's impact. |
| The recorder's log in the app | done | Settings › Recorder: filters by source and kind, reads only what it shows. |
| Recording the sub-stream instead | later | For a camera that doesn't fit at full resolution: keep the main stream for live view and HomeKit, record the sub-stream. |
| Live frames in transitions | later | When tiles change rows quickly, the fading stand-in shows the camera's latest recorded still, up to a minute old. It should show the tile's last live frame (`AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer()` with the clock briefly paused, or decoding in the app and keeping the last frame). |
| H.265 cameras | later | Recording as is (`hvc1`), and re-encoding to H.264 for HomeKit live view. |
| A signed, notarized release | later | Today Pond is built from source; a release needs a Developer ID, notarization and an app bundle identifier of its own. |

## HomeKit

| Goal | Status | Notes |
|---|---|---|
| Pairing, accessory database, Bonjour | done | Native HAP in Swift (`HAP`), one standalone accessory per camera. |
| Snapshots | done | A sub-stream keyframe through VideoToolbox, or the running live stream's latest. |
| Live video and sound | done | The camera's H.264 as is over SRTP (sub-stream, or main for a viewer that allows 1.5 Mbit/s), switching on a mid-stream reconfigure; AAC-LC → AAC-ELD at the asked packet time. |
| Several viewers at once | done | 1–4 per camera (default 2), all on one camera connection. |
| Re-encoding for the Home app | done | Optional per camera: sized and encoded per viewer on the Mac's video hardware, steered by each viewer's RTCP reports (`RateControl`). Not for cameras that send B-frames. |
| Fast start | done | `StreamHub` replays the video since the latest keyframe; `instantLive` keeps the sub-stream open. |
| HomeKit Secure Video | done | Recording on the camera's motion, from a prebuffer, re-encoded to the hub's choice; status and "Allow recording" in the app. Needs a home hub and iCloud+. |
| Doorbells | done | A video doorbell accessory that rings on a press (Reolink's API, or ONVIF events) and records to HomeKit Secure Video on motion or a ring. A 4:3 doorbell is recorded fitted inside the size the hub chooses. Tried with a Reolink Video Doorbell WiFi. |
| Motion from ONVIF cameras | done | A pull-point subscription to the camera's events: any motion, person, vehicle or animal detector drives the motion sensor, and a doorbell's visitor event rings. Tried end to end over ONVIF with a Reolink doorbell. |
| Talkback | later | The Home app's microphone to the camera's speaker: see two-way audio under ONVIF. |

The Home app on a Mac without a microphone plays no live sound from any camera; that is the Home app's behaviour, not Pond's.

## ONVIF

Many cameras speak ONVIF (SOAP over HTTP, with WS-Security username-token login). It brings a standard way to do what Pond now does per brand, and more:

| Goal | Status | Notes |
|---|---|---|
| Device information | done | `GetDeviceInformation` for any camera Reolink's API doesn't answer. |
| Discovery | done | ONVIF discovery, Reolink's own discovery (Reolinks don't answer ONVIF's), and a look at the local network's addresses for RTSP (554) or ONVIF (8000), all at once; on opening, daily, and in Add Camera. Add Camera lists what it finds; the toolbar offers new cameras until added or ignored. `pond camera discover`. |
| Stream addresses | done | Media `GetProfiles`, then `GetStreamUri` (Media2's when there is one); asked when a camera is added, editable in its settings. `pond camera onvif ID` shows what a camera says. |
| Camera events | done | Motion, person, vehicle and animal detection, and doorbell presses (see HomeKit above). |
| PTZ | done | Continuous move, zoom and presets (kept, removed, gone to), home and preset tours. In the app: a pad and the positions, each with a picture of what it shows, in the live view's dock. |
| Two-way audio | done | The ONVIF backchannel (RTSP with `Require: www.onvif.org/ver20/backchannel`, then G.711 RTP to the camera): push-to-talk in the app and `pond camera talk`. |
| Imaging | done | Day/night (IR cut filter), brightness, contrast, saturation, sharpness; speaker volume; relay outputs. The everyday ones in the dock, the rest in its Adjustments sidebar. |
| Controls through a make's own API | done | Providers per make, ONVIF the fallback: each control is resolved on its own, from the camera's chosen provider, then any that fit, then ONVIF. Reolink's HTTP API for PTZ, day/night and volume. |
| HomeKit talkback | later | The Home app's microphone to the camera's speaker, through the same backchannel. |
| Reolink's own protocol (Baichuan) | later | For what Reolink's HTTP API and ONVIF don't offer, such as two-way audio on cameras without an ONVIF backchannel; a provider like the others. |
| More of a make's own controls | later | Reolink's IR lights, status light, privacy mode, siren and chime volume, as items in the Adjustments sidebar. |

Not every camera speaks ONVIF, and some do two-way audio only through their own protocol; the camera check says what a camera supports, so the app shows only the controls that work.

## Camera health

A doctor for each camera: what's going wrong, since when, and what to try. First from what Pond sees itself, the same for every make; then from what cameras report about themselves.

| Goal | Status | Notes |
|---|---|---|
| Vitals from the service | next | Per camera, from what Pond already sees, with no extra requests to the camera: connections (how long they last, reconnects, stalls, refusals, network errors, telling the Mac's own network trouble from the camera's), video (frame rate against what was promised, lost packets, keyframe spacing, bitrate, jitter), clock drift, gaps in recordings, and the controls' answers (failures and how long they took). Kept as 5-minute counts for a day, in `camera-health.json` beside the settings. |
| Diagnosis | next | Rules turning vitals into findings with a severity, the evidence, how long and how often, and what to try: unstable video, dropping off the network, the Mac's network, frames missing, keyframes far apart, clock drifting, controls failing, recording gaps, privacy mode. A finding clears after a calm spell, so nothing flickers. |
| The doctor in Settings | next | Every camera with its state; a camera's findings, its vitals over the day, Run Check Now (a short test stream and a control read, only when asked), and Copy Report (without passwords or addresses). |
| In the live view | next | A mark on a camera's tile and in the rail when something is wrong (not for notices), its headline on hover, and a click opens the doctor. Never a pop-up. |
| What cameras say about themselves | later | Through the providers, gently (every few minutes, more often while a problem is open): ONVIF's device information, clock and monitoring events (last reboot, processor use); Reolink's CPU, Wi-Fi signal, connected users and SD card. They feed the same rules ("CPU at 96% while video stalls: the camera is overloaded"). |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Detection | later | People, vehicles, animals and packages, in zones, on the Neural Engine (Core ML), from the sub-stream. It then drives the HomeKit motion sensor instead of the camera's own motion. **Revisit Video only then:** today a video-only camera's HomeKit Secure Video is paused, because only the camera's own motion can start a recording; with Pond's own detection it could record again (`HomeKitHost`'s recording condition, and the paused toggle in camera settings). |
| Event clips and the Events view | later | Clips kept longer than continuous recording; the app's Events view (`POND_MOCK_EVENTS=1` shows made-up events until then). |
| Descriptions | later | A sentence per event, from Apple's on-device models. |
| Search | later | Plain-language questions ("packages delivered this week") to filters and semantic ranking, results that open the clip. |
| Zones in the app | later | Drawn on the camera's picture; edited by hand in the settings file until then. |
