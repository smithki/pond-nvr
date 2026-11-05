# What's been built

The roadmap's finished goals, by area, with how each was done. What's left is in [roadmap.md](roadmap.md); the changes, newest first, in [CHANGELOG.md](../CHANGELOG.md).

## Recording and the app

| Goal | Notes |
|---|---|
| H.265 cameras | A camera that sends H.265 (HEVC) recorded as it is (`hvc1`), played live and on the Timeline, watched by detection and closer looks, its snapshots taken, and passed to another Pond as it is; re-encoded to H.264 only for the Home app (live view and Secure Video), which takes nothing else. ONVIF's streams chosen with H.265 allowed (H.264 preferred between two the same size). Tried with demo cameras that send H.265; not yet with a real one. |
| Live frames in transitions | When tiles change rows quickly, the fading stand-in left at a tile's old place shows the tile's own live picture at that moment (the frame on screen, read from its renderer), not its latest recorded still (up to a minute old); the recorded still only while it isn't playing. |
| A budget for the media engine | One budget for all of Pond's video decoding and encoding (`MediaBudget`), each job weighed by its cost (pixels a second), in order: HomeKit Secure Video recordings, live re-encoding, the app's live views, detection, closer looks. When it's full the least goes first: closer looks close, detection looks at keyframes only, a new HomeKit recording is made from the sub-stream, a new live re-encode is turned down (the camera's own stream sent); given back when there's room, and said. Settings › Recorder shows it. ([architecture.md](architecture.md#the-media-engines-budget)) |
| The service, watched | The app watches the recorder while it runs, window open or not: not installed, stopped, its drive gone, or cameras writing nothing for a few minutes; a notification says what's wrong and where it's fixed, and goes once it is. The other Ponds paired with it too, every five minutes: one not recording (it says why: a drive gone, cameras offline), or gone quiet (not connected for two checks running, while this Mac is: off, or its internet down). With the menu bar item and Open at Login, an unattended Mac that restarts is watched. |
| A menu bar item | Pond at a glance without its window (Settings › General, on by default): recording, or what's wrong; each camera's privacy; Live, Events, the doctor and Settings. While it's shown, closing the window leaves Pond running, watching the recorder; Open at Login starts it there quietly. |
| Recording the sub-stream instead | Per camera (`recordsSub`, camera settings › Recording): the sub-stream recorded instead of the main stream, for a camera whose full resolution isn't worth the room; live view, HomeKit and detection use the streams as before. |
| Continuous recording | 1-minute MP4 segments per camera, the camera's own video and sound, retention by age, size and free space. |
| Live view | Every camera, main or sub-stream by tile size, sound for one camera at a time, health badges. |
| Timeline | Any day, a lane per camera, scrubbing, speeds, zoom (remembered), sound, live mode. Plays the minute being written, a few seconds behind live. Real events with their pictures, filters for the kinds there are, private stretches. |
| One connection per camera stream | `StreamHub` in the service, shared with the app's windows through `StreamRelay`; many cameras serve only a few connections. |
| Storage and retention settings | Days the drive holds from real rates, the drive as a bar, a checklist (startup disk, Spotlight, format), a new camera's impact. |
| The recorder's log in the app | Settings › Recorder: filters by source and kind, reads only what it shows. |
| Narrow windows | The Timeline and Events down to the window's smallest: the Timeline's bar keeps its playback controls on one row, the rarer ones (skipping, speed, boxes, sound, then the zoom) going into a menu as it narrows, and its filters fold from named chips to symbols to one menu; Events' filters do the same, the search's example shortened to "Search". The activity rail goes when there's no room for it, or when the details panel opening would leave the cards too cramped (it slides back as the panel closes); in the narrowest window the panel covers the cards until closed (rising from the bottom, the cards fading behind it). Only going from one of these size classes to another animates; resizing within one lays the grid out at once. |
| Demo mode | Pond with made-up cameras, apart from the real setup ([demo.md](demo.md)): scenes drawn by time of day (infrared at night) with sound, encoded as a camera's stream (`demo://`), so they're recorded, watched and found in like real ones; a demo make's controls (PTZ, day and night, brightness, privacy, restart) and doorbell presses; what's drawn told to detection. Scenarios (a home with a second home to reach, many cameras, trouble with a nearly full drive, a first run whose Add Camera finds the demo's cameras, a slow or unreachable second home), each a world of its own with its services run by its app, and the last three hours made on its first start. Opened from Settings › General, `make demo` or `pond demo`. |

## HomeKit

| Goal | Notes |
|---|---|
| Pairing, accessory database, Bonjour | Native HAP in Swift (`HAP`), one standalone accessory per camera. |
| Snapshots | A sub-stream keyframe through VideoToolbox, or the running live stream's latest. |
| Live video and sound | The camera's H.264 as is over SRTP (sub-stream, or main for a viewer that allows 1.5 Mbit/s), switching on a mid-stream reconfigure; AAC-LC → AAC-ELD at the asked packet time. |
| Several viewers at once | 1–4 per camera (default 2), all on one camera connection. |
| Re-encoding for the Home app | Optional per camera: sized and encoded per viewer on the Mac's video hardware, steered by each viewer's RTCP reports (`RateControl`). Not for cameras that send B-frames. |
| Fast start | `StreamHub` replays the video since the latest keyframe; `instantLive` keeps the sub-stream open. |
| HomeKit Secure Video | Recording on the camera's motion, from a prebuffer, re-encoded to the hub's choice; status and "Allow recording" in the app. Needs a home hub and iCloud+. |
| Doorbells | A video doorbell accessory that rings on a press (Reolink's API, or ONVIF events) and records to HomeKit Secure Video on motion or a ring. A 4:3 doorbell is recorded fitted inside the size the hub chooses. Tried with a Reolink Video Doorbell WiFi. |
| Motion from ONVIF cameras | A pull-point subscription to the camera's events: any motion, person, vehicle or animal detector drives the motion sensor, and a doorbell's visitor event rings. Tried end to end over ONVIF with a Reolink doorbell. |
| Talkback | The Home app's microphone to the camera's speaker, for a camera that can be talked through (it then has a Speaker in HomeKit): the Home app's AAC-ELD back over the live view's audio port, decoded, resampled and sent through the camera's own way of talking (the ONVIF backchannel). The camera's speaker opens with the first sound and closes after 2 s of silence. |

The Home app on a Mac without a microphone plays no live sound from any camera; that is the Home app's behaviour, not Pond's.

## ONVIF

| Goal | Notes |
|---|---|
| Device information | `GetDeviceInformation` for any camera Reolink's API doesn't answer. |
| Discovery | ONVIF discovery, Reolink's own discovery (Reolinks don't answer ONVIF's), and a look at the local network's addresses for RTSP (554) or ONVIF (8000), all at once; on opening, daily, and in Add Camera. Add Camera lists what it finds; the toolbar offers new cameras until added or ignored. `pond camera discover`. |
| Stream addresses | Media `GetProfiles`, then `GetStreamUri` (Media2's when there is one); asked when a camera is added, editable in its settings. `pond camera onvif ID` shows what a camera says. |
| Camera events | Motion, person, vehicle and animal detection, and doorbell presses (see HomeKit above). |
| PTZ | Continuous move, zoom and presets (kept, removed, gone to), home and preset tours. In the app: a pad and the positions, each with a picture of what it shows, in the live view's dock. |
| Two-way audio | The ONVIF backchannel (RTSP with `Require: www.onvif.org/ver20/backchannel`, then G.711 RTP to the camera): push-to-talk in the app and `pond camera talk`. |
| Imaging | Day/night (IR cut filter), brightness, contrast, saturation, sharpness; speaker volume; relay outputs. The everyday ones in the dock, the rest in its Adjustments sidebar. |
| Controls through a make's own API | Providers per make, ONVIF the fallback: each control is resolved on its own, from the camera's chosen provider, then any that fit, then ONVIF. Reolink's HTTP API for PTZ, day/night and volume. |
| HomeKit talkback | Through the same backchannel: see Talkback under HomeKit. |
| Privacy | Per camera, for every camera: not recorded, shown live or served to HomeKit (shown as off in the Home app), applied at once by the service; in the dock, the list's menu, its settings and `pond camera privacy`. |
| Privacy on the camera itself | Two-way through a provider: Pond's privacy switches the camera's own mode, and its changes are pushed to Pond (Reolink: Baichuan's 574 to read, 575 to set, 623 pushed); a change made on the camera while Pond wasn't connected stands. Coming back, a camera is waking (its make's time) and its settings wait until its video returns. A camera without a provider for it that goes into its own privacy mode is seen by the recorder and shown as private on the camera. |
| Reolink's own protocol (Baichuan) | A provider over TCP 9000, as Home Assistant's integration does (following reolink_aio, MIT): one lasting connection per camera. Privacy mode both ways, and motion, detections and doorbell presses pushed (HTTP polling only for a camera that doesn't answer there). Talking back over it, for cameras without an ONVIF backchannel, is later. |

## Camera health

| Goal | Notes |
|---|---|
| Vitals from the service | Per camera, from what Pond already sees, with no extra requests to the camera: connections (how long they last, reconnects, stalls, refusals, network errors, telling the Mac's own network trouble from the camera's), video (frame rate against what was promised, lost packets, keyframe spacing, bitrate, jitter), clock drift, gaps in recordings, and the controls' answers (failures and how long they took). Kept for a week in Pond’s SQLite database (`pond.sqlite`, on the internal disk; its first use), as 5-minute counts and each incident; pruned by age, apart from recording retention. |
| Diagnosis | Rules turning vitals into findings with a severity, the evidence, how long and how often, and what to try: unstable video, dropping off the network, the Mac's network, frames missing, keyframes far apart, clock drifting, controls failing, recording gaps, privacy mode. A finding clears after a calm spell, so nothing flickers. |
| The doctor in Settings | Every camera with its state; a camera's findings, its vitals over the day, Run Check Now (a short test stream and a control read, only when asked), and Copy Report (without passwords or addresses). |
| In the live view | A mark on a camera's tile and in the rail for a problem, or a warning with a fix to make (not for notices), its headline on hover, and a click opens the doctor. Never a pop-up. |
| Thresholds | Fixed defaults (stalls an hour, packet loss, keyframe spacing, clock drift, control failures), shown with the actual figures; changeable as an advanced setting in the doctor (Thresholds, under the cameras), and **Ignore** per finding per camera. See [doctor.md](doctor.md). Privacy is never a problem: a private camera's gaps are explained, not flagged. |

## Away from home

| Goal | Notes |
|---|---|
| Remote access | The Mac reached from outside, peer to peer, on Pond's own WebRTC-style stack (STUN connection checks through NAT, IPv4 and IPv6; SRTP video and an encrypted control channel keyed from Pond's own pairing); no relay by default, and a diagnosis when no path is found. Pairing with a code or QR; paths (direct, a relay of one's own, or only a mesh), found again as networks change; the encrypted session and its API (cameras, events, pictures, clips, search, controls, recorded stretches); fast resumable clips; Settings › Remote Access. In the app, other Ponds beside this Mac in Live, Events (with search) and the Timeline (their lanes and events, not their recordings), chosen with the Recording button. Tried across two networks (a MacBook on an iPhone's hotspot), and end to end in demo mode. ([remote.md](remote.md)) |
| Mesh mode | "Only over my mesh": with Tailscale or Headscale, connections are made over the tunnel alone (candidates from its interface only, no STUN, no relay), so no public address is ever exchanged. The mesh is the user's own; Settings shows whether this Mac is in it, and takes other ranges. `deploy/`'s `mesh` profile runs Headscale behind Caddy's HTTPS. Tested on a made-up network; not yet tried on a real tailnet. ([remote.md](remote.md#using-a-mesh)) |
| Signaling, self-hosted | `pond-signal`, a blind courier: it passes sealed, signed envelopes between paired devices' mailboxes and can read none of them (offers, answers and candidates are encrypted to the other device's key); it answers STUN too, so no third party learns addresses. Runs anywhere Docker does (`deploy/docker-compose.yml`), with optional profiles for coturn (a relay of one's own, kept to itself) and Headscale (a private WireGuard mesh). The NVR itself stays on the Mac. Deployed and used: Docker on a small VPS, Caddy for `wss://` with a Let's Encrypt certificate, STUN on UDP 3478–3479, `/health` for checking it's up. |

## Detection, events, search

| Goal | Notes |
|---|---|
| Detection | Models: done. Any Core ML detection model with a manifest, built in (Ultralytics YOLO26 small) or added to the Models folder, swapped while running; four output formats read (end-to-end, raw YOLO, Vision, DETR); `pond detect` tries one on recordings ([detection.md](detection.md)). Events: done. Every camera's sub-stream watched (motion, then the model), what's seen followed and made into events with a picture, kept in the database (`pond events`). Zones: done (watched and ignored, drawn in the app). Events hold together (one per thing that comes and stays, counted at once, the surest word for each); bikes, left items and doorbell presses are kinds of their own; on the timeline: done. The HomeKit motion sensor: done (Pond's events set it by default; a video-only camera records to HomeKit Secure Video again). Packages wait for a model that knows them (below). |
| The Events view | Every event as a card (its picture, its subject boxed, its sentence), by day, filtered by camera and kind, new ones glowing in as they come; laid out by Pond, so opening the details panel moves the grid as one animation. Beside it, the activity rail: every day kept, an hour a cell shaded by how much happened, the hours on screen outlined, a click away. Details in a panel: the recording looping with its boxes, what was seen, where, when and how sure, the way to the timeline; arrows step through. Events can be deleted (the recording stays); removing a camera with its recordings removes its events too. |
| Event clips | Each event's own clip, kept as long as events are (event retention), not only as long as the continuous recording around it: its stretch of the recording ±3 s, copied as recorded by the service about a minute after it ends (earlier events too, while their recordings last), beside its picture; whole, however long. The details panel plays it (the recording, until it's made). |
| Descriptions | A sentence per event, from the Mac's own on-device model (Foundation Models, which takes pictures from macOS 27; tried: "A person is standing in the driveway", 3 s on an M6). On-device only, never Private Cloud Compute. Without Apple Intelligence (`SystemLanguageModel.availability`: not enabled, model not ready, Mac not eligible) everything else works and events show what was found instead; Settings says why, with Open Settings… to Apple Intelligence & Siri when it's only switched off, and sentences are written for earlier events once it's on. |
| Search | Plain-language questions ("packages delivered this week") read into filters (by the Mac's own model, or plain rules) and ranked by SigLIP 2 picture embeddings and the sentences; done by the service for the Events view and `pond search`, in well under a second ([search.md](search.md)). SigLIP's converted model is too big for the repository: made by `scripts/convert-siglip.py`; how a release ships it (built in, or downloaded) is for the signed release. |
| Left items | Something carried and put down (a bag, a suitcase, an umbrella) that stays 30 s with nobody over it: an event of its own. Works with the items the model knows. |
| Zones in the app | Drawn on the camera's latest picture in its settings (Detection › Edit Zones): watched zones, with the kinds each takes, and ignored ones. |
