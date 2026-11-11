# Architecture

## The pieces

```
camera ──RTSP──► Ingest (StreamHub: one connection per stream) ──┬──► Recorder ──► 1-minute MP4 segments on disk
 main + sub                                                      ├──► the app's live views (through the service's StreamRelay)
                                                                 ├──► HomeKit live view (SRTP to each viewer)
                                                                 ├──► prebuffer (last few seconds) ──► HKSV (fMP4 over HomeKit Data Stream)
                                                                 └──► another Pond's live view (Remote: SRTP over a peer-to-peer session)
camera's sub-stream (Watch) ──► Detection ──► events ──► Understanding ──► Search (the service; the app and pond ask it)
                                                 └──► HomeKit motion sensor (or the camera's own motion, Devices) ──► the home hub asks for a recording
```

Two programs come out of it: `pond`, the command and the background service (`pond run`, a launchd agent), which records, watches, serves HomeKit and answers other Ponds; and `Pond NVR.app`, which shows and sets it all, and asks `pond` for anything that needs a camera's password. A third, `pond-signal`, is the signaling service other Ponds meet through, run on a server of one's own ([deploy/](../deploy/README.md)).

The code is in four SwiftPM packages, one per part, with a module per responsibility ([The repository](#the-repository) says what else is where).

Modules marked Linux build there too (`make test-docker`); the rest need macOS's frameworks.

| Module | Responsibility | Linux |
|---|---|---|
| `PondCore` | Settings and `ConfigStore`, storage folders (`StorageLocation`) and estimates, retention rules, the `CredentialStore` interface, privacy and camera health state shared by the app and the service, demo mode's scenarios (`Demo`) | yes |
| `PondMac` | The Keychain (`KeychainCredentialStore`; a file in a demo's folder instead, in demo mode) | no |
| `PondCLI` | The `pond` command's logic: settings, storage, retention, cameras, `run`, and the login service (`pond service`). Its outside world (settings file, Keychain, camera, terminal) is passed in, so it is tested with fakes | yes |
| `Ingest` | RTSP client (TCP interleaved, Digest login, keepalive), SDP, codec parameters (H.264 and H.265 SPS, AAC config), RTP depacketizing (H.264, H.265, AAC; `VideoDepacketizer` for either video codec), RTCP sender reports to wall time, one shared connection per stream (`StreamHub`, which replays the video since the latest keyframe to a late reader), `StreamRelay` (the service's local socket for the app's live views), and the media engine's budget (`MediaBudget`) | yes |
| `Media` | fMP4 muxer (`MP4`, `FragmentWriter`: fragments cut at keyframes; `avc1` and `hvc1`) | yes |
| `Recorder` | Packets to MP4: `StreamRecorder` puts video and audio on one timeline from the first keyframe (RTCP sender reports keep sound in step) and cuts 1-minute segments at keyframes; `SegmentFiles` writes them (`.partial` until complete, never to a missing drive); `CameraWorker` records one camera on its own thread and reconnects with backoff; `RetentionSweeper` deletes by the retention rules; `RecordingIndex` lists what was recorded when; `RecordingService` runs it all (`pond run`); `FileLog` writes the service's log | yes |
| `Control` | Shared by the CLI and the app: the login service (`ServiceControl`, `LaunchAgent`, launchd), its log (`LogReader`) and the wording of camera checks (`CameraCheck`) | yes |
| `HAP` | HomeKit Accessory Protocol: TLV8, `BigUInt` and SRP-6a (3072-bit group, SHA-512; M1, N and g hashed unpadded, as HomeKit does), pair setup and pair verify, `FrameCipher` sessions, HTTP with timed writes, the accessory database (`Accessory`, `Service`, `Characteristic`), `AccessoryServer` (routing, events, `/pairings`, `/resource`, `/prepare`), `HAPListener` (Bonjour), and the HomeKit Data Stream (`DataStream`: HKDF keys from the session, ChaCha20-Poly1305 frames, `Opack` messages). One standalone accessory per camera, not a bridge. Uses CryptoKit | no |
| `HAPCamera` | A camera as an accessory (`CameraAccessory`: stream management, microphone, motion sensor, doorbell), snapshots (`Snapshotter`), the Keychain record (`HomeKitRecord`), `HomeKitHost`; live view: stream setup (`StreamManagement`), RTP packets (`RTPPacketizer`, `VideoPacketizer`), SRTP, sound (`AudioTranscoder`: AAC-LC to AAC-ELD), re-encoding (`VideoTranscoder` on VideoToolbox, steered by `RateControl` from the viewer's RTCP reports) and the stream itself (`LiveSession`, also what another Pond is sent); HKSV: the recording services and selection (`RecordingController`), the prebuffers (`Prebuffer`) and one recording sent to the hub (`RecordingSession`) | no |
| `Devices` | What a camera is (maker, model, serial, firmware, doorbell), its events (motion, doorbell presses) and its controls (PTZ, talking back, privacy, and declared items: day and night, image settings, volume, home, tours, relays), behind `CameraProvider`: `ReolinkProvider` (its HTTP API and Baichuan protocol) and `ONVIFProvider`; `DeviceReader` asks them in turn, `CameraControls` resolves each control to the first provider that offers it, `CameraSessions` shares one login per camera, discovery finds cameras on the network, and `ControlServer` serves the app over a socket (see [controls.md](controls.md)) | no |
| `Health` | Camera health kept for the doctor (`HealthStore`, in Pond's SQLite database): vitals in 5-minute counts, and incidents | no |
| `Detection` | Detection models (Core ML, with a manifest: `ModelStore`), run on the Neural Engine (`Detector`), their answers in Pond's terms (people, vehicles, bikes, animals, packages, items) | no |
| `Watch` | Each camera's sub-stream watched (`CameraWatcher`: motion first, then the model; a closer look at the main stream for what's small), what's seen followed (`Tracker`) and made into events (`EventBuilder`, `LeftItems`), kept with their pictures (`EventStore`) and clips (`ClipKeeper`); the video decoder's memory watched (`VideoMemoryGuard`); and search: `Understander` (each event described and embedded), `EventSearch` and `SearchService` (see [search.md](search.md)) | no |
| `Understanding` | Event descriptions (`Describer`: Foundation Models, image input, on-device only), SigLIP 2 embeddings of pictures and words (`SigLIP`, `BPETokenizer`), and questions read (`QuestionReader`: Foundation Models, guided; `PlainReader`; `TimeWords`). SigLIP rather than MobileCLIP: Apple's MobileCLIP weights are licensed for research | no |
| `Traversal` (protocol) | Finding a way between two Ponds: STUN, TURN (a relay of one's own), candidates and the checks between them (`PathFinder`), and the UDP socket they use | yes |
| `SignalProtocol` (protocol) | The signaling service's messages (`SignalMessage`) | yes |
| `PondProtocol` (protocol) | Identities (`RemoteIdentity`, `RemotePeer`), sealed envelopes (`Envelope`), pairing codes and messages (`PairingCode`, `PairingGuest`), session keys (`SessionKeys`) and the encrypted control channel (`SecureChannel`). Uses CryptoKit | no |
| `Signal` (signaling) | `pond-signal`: a blind courier for sealed envelopes between paired devices, over WebSockets, and a STUN responder | yes |
| `Remote` | Remote access, over the protocol: identities kept (`RemoteKeys`, in the Keychain), pairing hosted (`PairingHost`), paths and sessions (`PathSessions`), live video over them (`RemoteVideo`), the remote API (`RemoteAPI`), and other Ponds' cameras for this Mac's app (`RemoteViewing`). See [remote.md](remote.md) | no |
| `Demo` | Demo mode's made-up cameras: scenes drawn and encoded as a camera's stream (`DemoStream`), their controls (`DemoProvider`), sound, and history made on first start. See [demo.md](demo.md) | no |
| `PondApp` (macos) | The SwiftUI app (`Pond NVR.app`, built by `make app`). The main window has Live (`LiveStream`: the RTSP client and video depacketizer feeding an `AVSampleBufferDisplayLayer` through a render synchronizer), Timeline (`TimelineModel`: segments at their recorded times in an `AVMutableComposition`) and Events (`EventGrid`, `EventRail`, `EventCard`, `EventDetail`; search asked of the service), with other Ponds beside this Mac's; the Settings window; and the menu bar item, which watches the recorder (`ServiceWatch`). `AppModel` saves through `ConfigStore` and leaves reading passwords to `pond` | no |

The models sit behind small protocols (`DescriptionModel`, the query parser), so an MLX or cloud model could replace Apple's without touching the rest. The default is on-device only.

## The repository

Four parts, each a SwiftPM package of its own, under its own licence (NOTICE says the same):

| Package | What it is | Licence |
|---|---|---|
| [`protocol/`](../protocol/) | Pond's network protocol: what Ponds and their devices say to each other and to the signaling service (`Traversal`, `SignalProtocol`, `PondProtocol`) | MIT |
| [`signaling/`](../signaling/) | `pond-signal`, the signaling service (`Signal`) | AGPL-3.0 |
| [`recorder/`](../recorder/) | Everything Pond does on the Mac, and the `pond` command: every module from `PondCore` to `Demo` | AGPL-3.0 |
| [`macos/`](../macos/) | The Mac app (`PondApp`), its bundle's files (`app/`: Info.plist, entitlements, icon) and Sparkle | AGPL-3.0 |

They depend on each other one way only, so a part can't reach into one that depends on it:

```
macos/ ──────────────► recorder/ ─────────────► protocol/
  │                       │                         ▲
  │  (pond-signal,        │  (its remote tests      │
  │   bundled for         │   run the service)      │
  │   demo mode)          ▼                         │
  └──────────────────► signaling/ ──────────────────┘
```

`protocol/` uses nothing of Pond's. That's what lets it be MIT, and lets an app that speaks Pond's protocol (an iPhone app, say) use it without the AGPL parts. Code that both sides of a connection need belongs there; what only a Mac does (the Keychain, the API's answers, live video from a camera) stays in `recorder/`.

`make app` builds everything from `macos/` (its build folder has all four); `make check` and `make test` go through each package. Each package keeps its own build folder (`<package>/.build`); Xcode opens `macos/Package.swift`, or a part's own.

Everything else:

| Folder | What's there |
|---|---|
| [`deploy/`](../deploy/README.md) | Running `pond-signal`, a relay (coturn) and a mesh (Headscale) on a server of one's own, with Docker |
| [`scripts/`](../scripts/) | What `make` and CI run: releases, the models (fetching, converting, packaging, signing), the footage guard, CI's secrets |
| [`models/`](../models/) | The lock files naming the models builds download (`detection.lock`, `search.lock`) and the search model's signing key; the models themselves are downloaded here, never committed |
| [`web/`](../web/README.md) | pond.camera: the site, Sparkle's appcast, and the search model's signed manifest |
| [`docs/`](./) | How Pond works and how it's made |
| [`tests/`](../tests/README.md) | The Linux container `make test-docker` runs the tests in (the tests are in each package's `Tests/`) |
| [`third-party/`](../third-party/) | Licence texts of what's built in or followed (copied into the app as `Licenses/`) |
| [`brand/`](../brand/) | The logo. The name, logo and icon aren't under the code's licences (NOTICE) |
| [`.github/`](../.github/) | CI's workflows ([ci-security.md](ci-security.md)) and CODEOWNERS |

## What Reolink's RTSP server does

Seen on a Reolink E1 Pro (RTSP server "BC Streaming Media v2022.10.01"); `Ingest` copes with all of it:

- **Digest authentication** on DESCRIBE, SETUP and PLAY (realm `BC Streaming Media`).
- **Interleaved data before the PLAY reply:** an RTCP sender report can arrive on channel 1 before the `200 OK` for PLAY, so the reader must accept `$` frames while waiting for any RTSP reply.
- **Privacy mode:** every request succeeds but no RTP arrives, and the sender reports say 0 packets sent. Pond treats "connected, no video for 10 s, sender reports at 0" as *camera in privacy mode*, says so, and retries slowly instead of reconnecting in a loop.
- **Uneven RTP timestamps:** the steps between frames vary (20 fps averages 4500 ticks at 90 kHz, but single steps range from about 100 to over 6000). The muxer must take each frame's own timestamp, not assume a fixed frame rate.
- **A slightly malformed SPS on the sub-stream** (`ffmpeg`: "Overread VUI by 8 bits"). Harmless for stream copy, and VideoToolbox accepts it.
- **The description does not always carry the codec parameters.** The sub-stream's SDP sometimes has an `a=fmtp` line with the SPS and sometimes none at all, from one connection to the next. The SPS also comes inside the video before each keyframe, so the resolution must be read from there when the description leaves it out (`FlowAnalyzer` does).
- Video first arrives 1–4 s after PLAY, with SPS and PPS before every keyframe.

## Recording format

Each recording is a fragmented MP4: an init segment (`ftyp` + `moov` with an `avc1`/`avcC` video track (H.264), or `hvc1`/`hvcC` (H.265), at 90 kHz and an `mp4a` AAC track at the camera's sample rate), then a `moof` + `mdat` fragment for every keyframe interval of at least 2 s. The video is the camera's own, never re-encoded; its parameter sets (SPS and PPS, and H.265's VPS) go in `avcC` or `hvcC` and are taken out of the samples. A file cut off by a crash or an unplugged drive plays up to its last whole fragment.

Timing: video times are the camera's RTP timestamps from the first keyframe. Audio has its own RTP clock with an unrelated starting value; the first RTCP sender report on each track gives that clock's wall time, so audio is placed by wall time once and then follows its own clock. The same wall time dates the recording. Before any sender report (Reolink sends one at once), arrival time stands in.

Recordings decode completely in ffmpeg and open in AVFoundation (QuickTime's engine). A camera's frame timestamps can be uneven (gaps from 1 ms to 100 ms around a 50 ms average); they are kept as they are, so players show each frame when the camera says it was taken.

## Recording loop

`pond run` starts a `CameraWorker` thread per camera and a retention sweep every 5 minutes (and once at start). A worker connects, records, and on any failure (connection lost, the camera silent for 10 s, the drive gone) closes the current segment and connects again after 1, 2, 4 … up to 30 s. Each distinct problem is logged once, not on every retry. Privacy mode (the camera connected but its sender reports at 0 packets) is retried every 30 s. Ctrl-C or SIGTERM finishes the current segments cleanly; that is also how launchd stops the login service. While it runs, `pond run` holds a PreventUserIdleSystemSleep assertion (`pmset -g assertions` shows "pond is recording cameras").

**A camera with too many viewers** may stall: about a minute into a connection its video falls to almost nothing for 20–30 s, or thins out (fewer frames, gaps in the sound). `ffmpeg` sees the same, so it is the camera. The worker turns each stall into a short gap: it ends the segment, reconnects, and records again. Pond shares one connection per stream for this reason (see [cameras](cameras/README.md#connections)).

## The media engine's budget

Everything of Pond's that decodes or encodes video shares the Mac's media engine, so each job claims its share from one budget (`MediaBudget`, in `Ingest`): pixels a second (a decode's width × height × frame rate; an encode's weighed half again). The capacity is the chip's, estimated by its name (2.5 Gpx/s for a base chip, about what the soak showed it keeps up with; twice that for a Pro, four times for a Max, eight for an Ultra), or `POND_MEDIA_CAPACITY` to try a small one. In order, most important first:

| Job | When it doesn't fit |
|---|---|
| HomeKit Secure Video recordings | Never turned down. A new one is re-encoded from the sub-stream instead (a second prebuffer is kept on it, packets only, so it still starts from before the motion). |
| Live re-encoding (the Home app's, another Pond's) | A new one is turned down: the camera's own stream is sent as it is, which costs nothing. |
| Live views in the app | Counted (the app says what its tiles decode, `media.app`), never shed. |
| Detection on the sub-streams | Shed to keyframes only (a picture every couple of seconds), and given back when there's room. |
| Closer looks | Closed first, and opened again when there's room. |

Continuous recording decodes nothing and isn't in it. What's shed and given back is logged; the hourly video-decoding line adds the budget, and The doctor's Recorder page shows it (`media.budget`).

## HomeKit Secure Video

When the home hub wants a recording (on the motion sensor), it opens a `dataSend` stream over the HomeKit Data Stream. `RecordingSession` takes the prebuffer from the latest keyframe before the time the hub asked for, then the live frames, and re-encodes them (`VideoTranscoder`, not in real time) to the hub's chosen size, bitrate and frame rate, at a constant frame rate with a keyframe exactly at the start of each fragment: the hub treats its fragment length as a maximum. `FragmentWriter` writes them as fMP4, sent in chunks of at most 256 KB until the hub closes the stream. The camera's AAC-LC goes along unchanged when the hub chose AAC-LC at its sample rate.

## HomeKit references

There is no public specification for HKSV: it is reverse-engineered. The HomeKit layers are written from:
- **HAP-NodeJS** (Apache 2.0): camera controller, recording management, the data stream server and parser.
- **HomeKitADK** (Apache 2.0): HAP core, pairing, test vectors.

Code ported from these keeps a comment naming the source file.
