# Roadmap

What is done and what comes next. The build phases are in [architecture.md](architecture.md#phases); this page has the detail.

Status: **done**, **in progress**, **next**, **later**.

## Recording and the app

| Goal | Status | Notes |
|---|---|---|
| The service, watched | next | Saying so when Pond isn't recording and nobody's looking: after a restart or a login, the app (and later a small login item of its own, with the window closed) checks that the service is installed and running, and recording; if not, a notification says what's wrong and offers the fix (Install, Start, plug in the drive). A Mac that restarts unattended (a power cut, a panic) is the case: the service gone or stuck stays unseen until someone opens the app. With remote access, a paired device is told when its Pond goes quiet. |
| A budget for the media engine | later | One budget for all of Pond's video decoding and encoding, each job weighed by its cost (a 4K decode more than a sub-stream's, an encode on top), in order: HomeKit Secure Video recordings, then live views (the Home app's and Pond's), then detection on the sub-streams, then closer looks (today's `TapSlots`, which only covers those). Continuous recording decodes nothing and is never touched. When it's full, the least goes first: closer looks pause, detection looks less often, a HomeKit recording re-encodes from the sub-stream instead of the main stream, and only then is a new live view turned down, with the reason given. Detection keeps only its latest picture, never a backlog. Not needed yet: `scripts/soak.sh` with 16 4K cameras, all recording to HomeKit at once, kept up on a base M6 with the decoder service flat at about 1.3 GB. It's for live views on top of that, 30 fps, and H.265. |
| Narrow windows | later | Rethink the timeline (and the app around it) at small window sizes: today the video, controls, filters and lanes squeeze together and the whole interface gets janky on narrow windows. Likely a compact layout: fewer controls inline (the rest in a menu), filters folded into one control, the hint text dropped, lanes shorter. |
| Recording the sub-stream instead | later | For a camera that doesn't fit at full resolution: keep the main stream for live view and HomeKit, record the sub-stream. |
| Live frames in transitions | later | When tiles change rows quickly, the fading stand-in shows the camera's latest recorded still, up to a minute old. It should show the tile's last live frame (`AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer()` with the clock briefly paused, or decoding in the app and keeping the last frame). |
| H.265 cameras | later | Recording as is (`hvc1`), and re-encoding to H.264 for HomeKit live view. |
| Demo mode | later | Pond with made-up cameras, to explore without any (or before buying one), and to try what a single home doesn't have: many cameras, other makes, doorbells, PTZ, a camera that keeps dropping, a full drive, busy days of events. Each demo camera plays generated video (a test pattern, or rendered scenes) or a bundled clip, recorded, watched and found in like a real one, with events, sentences and search working on it. Its own settings and storage, apart from a real setup; scenarios chosen in Settings or with a launch argument, so a bug report's situation can be set up exactly. Replaces `POND_MOCK_EVENTS`. |
| A menu bar item | later | Pond at a glance without its window: whether it's recording, each camera's state (the doctor's mark, private, waking), privacy on and off per camera, and opening the live view or a camera's doctor. Optional, in Settings › General. |
| A signed, notarized release | later | Today Pond is built from source; a release needs a Developer ID, notarization and an app bundle identifier of its own. It also settles how search's picture model reaches users (about 390 MB: in the app, or downloaded on first use). |
| Continuous recording | done | 1-minute MP4 segments per camera, the camera's own video and sound, retention by age, size and free space. |
| Live view | done | Every camera, main or sub-stream by tile size, sound for one camera at a time, health badges. |
| Timeline | done | Any day, a lane per camera, scrubbing, speeds, zoom (remembered), sound, live mode. Plays the minute being written, a few seconds behind live. Real events with their pictures, filters for the kinds there are, private stretches. |
| One connection per camera stream | done | `StreamHub` in the service, shared with the app's windows through `StreamRelay`; many cameras serve only a few connections. |
| Storage and retention settings | done | Days the drive holds from real rates, the drive as a bar, a checklist (startup disk, Spotlight, format), a new camera's impact. |
| The recorder's log in the app | done | Settings › Recorder: filters by source and kind, reads only what it shows. |

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
| Talkback | done | The Home app's microphone to the camera's speaker, for a camera that can be talked through (it then has a Speaker in HomeKit): the Home app's AAC-ELD back over the live view's audio port, decoded, resampled and sent through the camera's own way of talking (the ONVIF backchannel). The camera's speaker opens with the first sound and closes after 2 s of silence. |

The Home app on a Mac without a microphone plays no live sound from any camera; that is the Home app's behaviour, not Pond's.

## ONVIF

Many cameras speak ONVIF (SOAP over HTTP, with WS-Security username-token login). It brings a standard way to do what Pond now does per brand, and more:

| Goal | Status | Notes |
|---|---|---|
| More of a make's own controls | later | Reolink's IR lights, status light, mirror and flip are done (and restarting any ONVIF camera); its siren, chime volume and spotlight are next. |
| Device information | done | `GetDeviceInformation` for any camera Reolink's API doesn't answer. |
| Discovery | done | ONVIF discovery, Reolink's own discovery (Reolinks don't answer ONVIF's), and a look at the local network's addresses for RTSP (554) or ONVIF (8000), all at once; on opening, daily, and in Add Camera. Add Camera lists what it finds; the toolbar offers new cameras until added or ignored. `pond camera discover`. |
| Stream addresses | done | Media `GetProfiles`, then `GetStreamUri` (Media2's when there is one); asked when a camera is added, editable in its settings. `pond camera onvif ID` shows what a camera says. |
| Camera events | done | Motion, person, vehicle and animal detection, and doorbell presses (see HomeKit above). |
| PTZ | done | Continuous move, zoom and presets (kept, removed, gone to), home and preset tours. In the app: a pad and the positions, each with a picture of what it shows, in the live view's dock. |
| Two-way audio | done | The ONVIF backchannel (RTSP with `Require: www.onvif.org/ver20/backchannel`, then G.711 RTP to the camera): push-to-talk in the app and `pond camera talk`. |
| Imaging | done | Day/night (IR cut filter), brightness, contrast, saturation, sharpness; speaker volume; relay outputs. The everyday ones in the dock, the rest in its Adjustments sidebar. |
| Controls through a make's own API | done | Providers per make, ONVIF the fallback: each control is resolved on its own, from the camera's chosen provider, then any that fit, then ONVIF. Reolink's HTTP API for PTZ, day/night and volume. |
| HomeKit talkback | done | Through the same backchannel: see Talkback under HomeKit. |
| Privacy | done | Per camera, for every camera: not recorded, shown live or served to HomeKit (shown as off in the Home app), applied at once by the service; in the dock, the list's menu, its settings and `pond camera privacy`. |
| Privacy on the camera itself | done | Two-way through a provider: Pond's privacy switches the camera's own mode, and its changes are pushed to Pond (Reolink: Baichuan's 574 to read, 575 to set, 623 pushed); a change made on the camera while Pond wasn't connected stands. Coming back, a camera is waking (its make's time) and its settings wait until its video returns. A camera without a provider for it that goes into its own privacy mode is seen by the recorder and shown as private on the camera. |
| Reolink's own protocol (Baichuan) | done | A provider over TCP 9000, as Home Assistant's integration does (following reolink_aio, MIT): one lasting connection per camera. Privacy mode both ways, and motion, detections and doorbell presses pushed (HTTP polling only for a camera that doesn't answer there). Talking back over it, for cameras without an ONVIF backchannel, is later. |

Not every camera speaks ONVIF, and some do two-way audio only through their own protocol; the camera check says what a camera supports, so the app shows only the controls that work.

## Camera health

A doctor for each camera: what's going wrong, since when, and what to try. First from what Pond sees itself, the same for every make; then from what cameras report about themselves.

| Goal | Status | Notes |
|---|---|---|
| What cameras say about themselves | later | Through the providers, gently (every few minutes, more often while a problem is open): ONVIF's device information, clock and monitoring events (last reboot, processor use); Reolink's CPU, Wi-Fi signal, connected users and SD card. They feed the same rules ("CPU at 96% while video stalls: the camera is overloaded"). |
| Vitals from the service | done | Per camera, from what Pond already sees, with no extra requests to the camera: connections (how long they last, reconnects, stalls, refusals, network errors, telling the Mac's own network trouble from the camera's), video (frame rate against what was promised, lost packets, keyframe spacing, bitrate, jitter), clock drift, gaps in recordings, and the controls' answers (failures and how long they took). Kept for a week in Pond’s SQLite database (`pond.sqlite`, on the internal disk; its first use), as 5-minute counts and each incident; pruned by age, apart from recording retention. |
| Diagnosis | done | Rules turning vitals into findings with a severity, the evidence, how long and how often, and what to try: unstable video, dropping off the network, the Mac's network, frames missing, keyframes far apart, clock drifting, controls failing, recording gaps, privacy mode. A finding clears after a calm spell, so nothing flickers. |
| The doctor in Settings | done | Every camera with its state; a camera's findings, its vitals over the day, Run Check Now (a short test stream and a control read, only when asked), and Copy Report (without passwords or addresses). |
| In the live view | done | A mark on a camera's tile and in the rail for a problem, or a warning with a fix to make (not for notices), its headline on hover, and a click opens the doctor. Never a pop-up. |
| Thresholds | done | Fixed defaults (stalls an hour, packet loss, keyframe spacing, clock drift, control failures), shown with the actual figures; changeable as an advanced setting in the doctor (Thresholds, under the cameras), and **Ignore** per finding per camera. See [doctor.md](doctor.md). Privacy is never a problem: a private camera's gaps are explained, not flagged. |

## Away from home

Pond stays open source; what's paid for is convenience, as with Home Assistant Cloud.

| Goal | Status | Notes |
|---|---|---|
| Remote access | in progress | The Mac reached from outside, peer to peer: first from another Mac (the start of "sites"), then the iPhone app. Pond's own WebRTC-style stack, no dependencies (as its HomeKit is): connection checks with STUN (RFC 8445's) to get through NAT, IPv4 and IPv6 alike, then SRTP video and an encrypted control channel, keyed from Pond's own pairing (a QR code; long-term keys in the Keychain). Live video adapts to the link (HomeKit's rate control), and search, events and clips work remotely. The connection follows a phone from Wi-Fi to cellular (its path found again). No relay by default: when no direct path is found, a diagnosis says why (strict NAT, no IPv6) and what to do (IPv6, a forwarded port, the mesh, a relay of one's own). Only temporary IPv6 addresses are shared, and local addresses can be left out. So far: pairing; a path found peer to peer (or through a relay of one's own, or only over a mesh), restarted as networks change, with a diagnosis when there's none; an encrypted session over it (keys for that session alone) with a reliable control channel and live video (passed through, or re-encoded for a weak link), and an API over it: the cameras, events (with their sentences, pictures and clips), search and the cameras' controls, as the app has them at home (not pairing or the settings); all tried from the command line (`pond remote watch`, `cameras`, `events`, `search`, `picture`, `clip`), and across two networks (a MacBook on an iPhone's hotspot, directly over IPv6). Clips come as fast as the link allows, resumed if cut off and checked. Settings › Remote Access turns it on, pairs and joins, and sets how connections are made. Next: the Mac app's viewer ("Connect to another Pond": its cameras live, its events, clips and search). |
| Signaling, self-hosted | in progress | `pond-signal`, a blind courier: it passes sealed, signed envelopes between paired devices' mailboxes and can read none of them (offers, answers and candidates are encrypted to the other device's key); it answers STUN too, so no third party learns addresses. Runs anywhere Docker does (`deploy/docker-compose.yml`), with optional profiles for coturn (a relay of one's own, kept to itself) and Headscale (a private WireGuard mesh). The NVR itself stays on the Mac. |
| Mesh mode | in progress | "Only over my mesh": with Tailscale or Headscale, connections are made over the tunnel alone (candidates from its interface only, no STUN, no relay), so no public address is ever exchanged. |
| The iPhone app | later | A separate program (an App Store–friendly licence for the protocol it shares, which the CLA allows), on the same protocol: live, events, clips, search. |
| A hosted service | later | Signaling, an opt-in relay and push alerts with a snapshot (APNs needs a sender of Pond's) run for those who'd rather not, for a small fee (a few dollars a month); open source too, to deploy oneself. Video stays end-to-end encrypted through the relay. |
| Models | later | Detection models beyond the built-in one (packages, or fitted to a home's own scenes), perhaps from others, from an official Pond model marketplace. Any model's terms are its maker's and travel with its file; the built-in one is Ultralytics YOLO26 (AGPL-3.0, as Pond is). Should Pond need other terms one day (a commercial or App Store version), the ways out: Ultralytics' enterprise licence, another built-in model, or YOLO26 as an optional download from the marketplace. |
| Shared work between Ponds | later | A paired Pond with power to spare (a Mac Studio, a MacBook Pro at home) takes on another's work that can wait: describing events (the language model), embedding their pictures for search, and running a new detection model back over weeks of recordings. The inputs are small (a picture, a short clip) and so are the answers (a sentence, an embedding), sent over the same sealed connection as remote access, and on the Macs of whoever owns them, so nothing leaves their own devices. A Pond hands work over when its backlog grows or it can't do the work itself (no Apple Intelligence), and does it itself whenever the other is asleep or away. Live work stays where the cameras are: recording to HomeKit, live views and detection on live video aren't sent anywhere (the video would cross the network twice, against HomeKit's deadlines, and across homes, upload speeds can't carry it). A home with more cameras than one Mac can watch splits its cameras between Ponds instead (see sites). Comes after remote access. |
| Camera groups and sites | later | Cameras gathered into groups (Front of house, Garage), named and ordered, for the live view's grid, the timeline's lanes and the Events filters; distinct from detection zones, which are areas in one camera's picture. A group can be a site: another Pond, at another location, with its own cameras, recordings and detection, joined over the same tunnel as remote access (peer to peer, or the relay), so one app shows every location (live, timeline, events, search) while each site's footage stays on its own Mac. Sites trust each other once paired (as HomeKit pairing does), and can be one-way (a cabin seen from home, not home from the cabin). |
| Sponsorship | later | Donations and sponsors (GitHub Sponsors, Open Collective). |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |
| Detection | done | Models: done. Any Core ML detection model with a manifest, built in (Ultralytics YOLO26 small) or added to the Models folder, swapped while running; four output formats read (end-to-end, raw YOLO, Vision, DETR); `pond detect` tries one on recordings ([detection.md](detection.md)). Events: done. Every camera's sub-stream watched (motion, then the model), what's seen followed and made into events with a picture, kept in the database (`pond events`). Zones: done (watched and ignored, drawn in the app). Events hold together (one per thing that comes and stays, counted at once, the surest word for each); bikes, left items and doorbell presses are kinds of their own; on the timeline: done. The HomeKit motion sensor: done (Pond's events set it by default; a video-only camera records to HomeKit Secure Video again). Packages wait for a model that knows them (below). |
| The Events view | done | Every event as a card (its picture, its subject boxed, its sentence), by day, filtered by camera and kind, new ones glowing in as they come; laid out by Pond, so opening the details panel moves the grid as one animation. Beside it, the activity rail: every day kept, an hour a cell shaded by how much happened, the hours on screen outlined, a click away. Details in a panel: the recording looping with its boxes, what was seen, where, when and how sure, the way to the timeline; arrows step through. Events can be deleted (the recording stays); removing a camera with its recordings removes its events too. |
| Event clips | done | Each event's own clip, kept as long as events are (event retention), not only as long as the continuous recording around it: its stretch of the recording ±3 s, copied as recorded by the service about a minute after it ends (earlier events too, while their recordings last), beside its picture; whole, however long. The details panel plays it (the recording, until it's made). |
| Descriptions | done | A sentence per event, from the Mac's own on-device model (Foundation Models, which takes pictures from macOS 27; tried: "A person is standing in the driveway", 3 s on an M6). On-device only, never Private Cloud Compute. Without Apple Intelligence (`SystemLanguageModel.availability`: not enabled, model not ready, Mac not eligible) everything else works and events show what was found instead; Settings says why, with Open Settings… to Apple Intelligence & Siri when it's only switched off, and sentences are written for earlier events once it's on. |
| Search | done | Plain-language questions ("packages delivered this week") read into filters (by the Mac's own model, or plain rules) and ranked by SigLIP 2 picture embeddings and the sentences; done by the service for the Events view and `pond search`, in well under a second ([search.md](search.md)). SigLIP's converted model is too big for the repository: made by `scripts/convert-siglip.py`; how a release ships it (built in, or downloaded) is for the signed release. |
| Left items | done | Something carried and put down (a bag, a suitcase, an umbrella) that stays 30 s with nobody over it: an event of its own. Works with the items the model knows. |
| Zones in the app | done | Drawn on the camera's latest picture in its settings (Detection › Edit Zones): watched zones, with the kinds each takes, and ignored ones. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done (the changelog has them then).

| Fix | Notes |
| --- | --- |
| (none open) | |

