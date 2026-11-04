# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done; the build phases are in [architecture.md](architecture.md#phases).

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

## Recording and the app

| Goal | Status | Notes |
|---|---|---|
| The service, watched | next | Saying so when Pond isn't recording and nobody's looking: after a restart or a login, the app (and later a small login item of its own, with the window closed) checks that the service is installed and running, and recording; if not, a notification says what's wrong and offers the fix (Install, Start, plug in the drive). A Mac that restarts unattended (a power cut, a panic) is the case: the service gone or stuck stays unseen until someone opens the app. With remote access, a paired device is told when its Pond goes quiet. |
| A budget for the media engine | later | One budget for all of Pond's video decoding and encoding, each job weighed by its cost (a 4K decode more than a sub-stream's, an encode on top), in order: HomeKit Secure Video recordings, then live views (the Home app's and Pond's), then detection on the sub-streams, then closer looks (today's `TapSlots`, which only covers those). Continuous recording decodes nothing and is never touched. When it's full, the least goes first: closer looks pause, detection looks less often, a HomeKit recording re-encodes from the sub-stream instead of the main stream, and only then is a new live view turned down, with the reason given. Detection keeps only its latest picture, never a backlog. Not needed yet: `scripts/soak.sh` with 16 4K cameras, all recording to HomeKit at once, kept up on a base M6 with the decoder service flat at about 1.3 GB. It's for live views on top of that, 30 fps, and H.265. |
| Narrow windows | later | Rethink the timeline (and the app around it) at small window sizes: today the video, controls, filters and lanes squeeze together and the whole interface gets janky on narrow windows. Likely a compact layout: fewer controls inline (the rest in a menu), filters folded into one control, the hint text dropped, lanes shorter. |
| Recording the sub-stream instead | later | For a camera that doesn't fit at full resolution: keep the main stream for live view and HomeKit, record the sub-stream. |
| Live frames in transitions | later | When tiles change rows quickly, the fading stand-in shows the camera's latest recorded still, up to a minute old. It should show the tile's last live frame (`AVSampleBufferVideoRenderer.copyDisplayedPixelBuffer()` with the clock briefly paused, or decoding in the app and keeping the last frame). |
| H.265 cameras | later | Recording as is (`hvc1`), and re-encoding to H.264 for HomeKit live view. |
| Demo mode | in progress | Pond with made-up cameras, to explore without any and to try what one home doesn't have. Built: scenes drawn by time of day (infrared at night) and encoded as a camera's stream (`demo://`), so they're recorded, watched and found in like real ones; a demo make's controls (PTZ, day and night, brightness, restart) and doorbell presses; what's drawn told to detection; scenarios (a home with a second home to reach, many cameras, trouble, first run, a slow or unreachable second home), each a world of its own (settings, recordings, log, secrets in a file, never the Keychain); `pond demo`, and `make demo` (a copy of the app running its scenario's services itself). Left: Settings › General › Open the Demo…; the trouble scenario's full drive; first run's Add Camera finding the demo's cameras; a few hours of history made on a scenario's first start; sound; `POND_MOCK_EVENTS` removed (demo replaces it); the relayed second home (needs a relay in the demo, or dropped). |
| A menu bar item | later | Pond at a glance without its window: whether it's recording, each camera's state (the doctor's mark, private, waking), privacy on and off per camera, and opening the live view or a camera's doctor. Optional, in Settings › General. |
| A signed, notarized release | later | Today Pond is built from source; a release needs a Developer ID, notarization and an app bundle identifier of its own. It also settles how search's picture model reaches users (about 390 MB: in the app, or downloaded on first use). |


## ONVIF

Many cameras speak ONVIF (SOAP over HTTP, with WS-Security username-token login). It brings a standard way to do what Pond now does per brand, and more:

| Goal | Status | Notes |
|---|---|---|
| More of a make's own controls | later | Reolink's IR lights, status light, mirror and flip are done (and restarting any ONVIF camera); its siren, chime volume and spotlight are next. |

Not every camera speaks ONVIF, and some do two-way audio only through their own protocol; the camera check says what a camera supports, so the app shows only the controls that work.

## Camera health

A doctor for each camera: what's going wrong, since when, and what to try. First from what Pond sees itself, the same for every make; then from what cameras report about themselves.

| Goal | Status | Notes |
|---|---|---|
| What cameras say about themselves | later | Through the providers, gently (every few minutes, more often while a problem is open): ONVIF's device information, clock and monitoring events (last reboot, processor use); Reolink's CPU, Wi-Fi signal, connected users and SD card. They feed the same rules ("CPU at 96% while video stalls: the camera is overloaded"). |

## Away from home

Pond stays open source; what's paid for is convenience, as with Home Assistant Cloud.

| Goal | Status | Notes |
|---|---|---|
| Remote access | in progress | The Mac reached from outside, peer to peer, on Pond's own WebRTC-style stack (STUN connection checks through NAT, IPv4 and IPv6; SRTP video and an encrypted control channel keyed from Pond's own pairing); no relay by default, and a diagnosis when no path is found. Built: pairing; paths (direct, a relay of one's own, or only a mesh), found again as networks change; the encrypted session and its API (cameras, events, pictures, clips, search, controls); fast resumable clips; Settings › Remote Access; and in the app, other Ponds beside this Mac: their cameras live (one session per Pond, several streams over it; their controls and latest pictures), their events in the Events view (pictures fetched as shown, clips playing as they arrive), chosen with the recorder's button. Tried across two networks (a MacBook on an iPhone's hotspot). Left: search across Ponds; the docs gone over (remote.md, security.md's table of what listens); tried between two real homes. |
| Mesh mode | in progress | "Only over my mesh": with Tailscale or Headscale, connections are made over the tunnel alone (candidates from its interface only, no STUN, no relay), so no public address is ever exchanged. Built and tested on a made-up network; still to try on a real tailnet (Tailscale's, or Headscale from `deploy/`). |
| The iPhone app | later | A separate program (an App Store–friendly licence for the protocol it shares, which the CLA allows), on the same protocol: live, events, clips, search. |
| A hosted service | later | Signaling, an opt-in relay and push alerts with a snapshot (APNs needs a sender of Pond's) run for those who'd rather not, for a small fee (a few dollars a month); open source too, to deploy oneself. Video stays end-to-end encrypted through the relay. |
| Models | later | Detection models beyond the built-in one (packages, or fitted to a home's own scenes), perhaps from others, from an official Pond model marketplace. Any model's terms are its maker's and travel with its file; the built-in one is Ultralytics YOLO26 (AGPL-3.0, as Pond is). Should Pond need other terms one day (a commercial or App Store version), the ways out: Ultralytics' enterprise licence, another built-in model, or YOLO26 as an optional download from the marketplace. |
| Shared work between Ponds | later | A paired Pond with power to spare (a Mac Studio, a MacBook Pro at home) takes on another's work that can wait: describing events (the language model), embedding their pictures for search, and running a new detection model back over weeks of recordings. The inputs are small (a picture, a short clip) and so are the answers (a sentence, an embedding), sent over the same sealed connection as remote access, and on the Macs of whoever owns them, so nothing leaves their own devices. A Pond hands work over when its backlog grows or it can't do the work itself (no Apple Intelligence), and does it itself whenever the other is asleep or away. Live work stays where the cameras are: recording to HomeKit, live views and detection on live video aren't sent anywhere (the video would cross the network twice, against HomeKit's deadlines, and across homes, upload speeds can't carry it). A home with more cameras than one Mac can watch splits its cameras between Ponds instead (see sites). Comes after remote access. |
| Camera groups and sites | in progress | One app showing every location while each site's footage stays on its own Mac. Built: other Ponds as sites in Live and Events (see remote access): their cameras and events mixed with this Mac's, a section each in the rail (folding away, reordered here), the Events camera filter grouped by Pond (one not shown still listed, and shown when chosen), each Pond named here. Left: other Ponds on the Timeline as lanes of their own, with their events on them and their clips playing, but not their recordings (too big for a home's upload to play back well; the lanes say so, briefly); groups of cameras within a Pond (Front of house, Garage), named and ordered, for the grid, the lanes and the filters (distinct from zones); one-way sites (a cabin seen from home, not home from the cabin). |
| Sponsorship | later | Donations and sponsors (GitHub Sponsors, Open Collective). |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done (the changelog has them then).

| Fix | Notes |
| --- | --- |
| (none open) | |

