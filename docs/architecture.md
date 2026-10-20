# Architecture

## The pieces

```
camera ──RTSP──► Ingest (StreamHub: one connection per stream) ──┬──► Recorder ──► 1-minute MP4 segments on disk
 main + sub                                                      ├──► Pond NVR.app's live views (through the service's StreamRelay)
                                                                 ├──► HomeKit live view (SRTP to each viewer)
                                                                 └──► prebuffer (last few seconds) ──► HKSV (fMP4 over HomeKit Data Stream)
camera's motion (Devices) ──► HomeKit motion sensor ──► the home hub asks for a recording
                               later: Detection ──► events ──► Understanding ──► Search
```

One SwiftPM package, `src/`, with a module per responsibility:

| Module | Responsibility | Builds on Linux | Status |
|---|---|---|---|
| `NVRCore` | Settings and `ConfigStore`, storage folders (`StorageLocation`), the retention rules, the `CredentialStore` interface | yes | done for phase 0 |
| `NVRMac` | macOS-only pieces: the Keychain (`KeychainCredentialStore`) | no | done |
| `NVRCLI` | The `pond` command's logic: settings, storage, retention, cameras, `run`, and the launchd agent (`pond service`). Its outside world (settings file, Keychain, camera, terminal) is passed in, so it is tested with fakes | yes | done |
| `Ingest` | RTSP client (TCP interleaved, Digest login, keepalive), SDP, H.264 SPS and AAC config, RTP depacketizing (H.264 single/STAP-A/FU-A, AAC-hbr), RTCP sender reports to wall time, one shared connection per stream (`StreamHub`, which replays the video since the latest keyframe to a late reader), and `StreamRelay`, the service's local socket for the app's live views | yes | done |
| `Media` | fMP4 muxer (`MP4`, `FragmentWriter`: fragments cut at keyframes) | yes | done |
| `Recorder` | Packets to MP4: `StreamRecorder` puts video and audio on one timeline from the first keyframe (RTCP sender reports keep sound in step) and cuts 1-minute segments at keyframes; `SegmentFiles` writes them (`.partial` until complete, never to a missing drive); `CameraWorker` records one camera on its own thread and reconnects with backoff; `RetentionSweeper` deletes by the retention rules; `RecordingIndex` lists what was recorded when; `RecordingService` runs it all (`pond run`); `FileLog` writes the service's log | yes | done |
| `HAP` | HomeKit Accessory Protocol: TLV8, `BigUInt` and SRP-6a (3072-bit group, SHA-512; in M1, N and g are hashed unpadded, as HomeKit does), pair setup and pair verify, `FrameCipher` sessions, HTTP with timed writes, the accessory database (`Accessory`, `Service`, `Characteristic`), `AccessoryServer` (routing, events, `/pairings`, `/resource`, `/prepare`), `HAPListener` (Bonjour), and the HomeKit Data Stream (`DataStream`: HKDF keys from the session, ChaCha20-Poly1305 frames, `Opack` messages). One standalone accessory per camera, not a bridge. Uses CryptoKit | no | done |
| `HAPCamera` | A camera as an accessory (`CameraAccessory`: stream management, microphone, motion sensor, doorbell), snapshots (`Snapshotter`), the Keychain record (`HomeKitRecord`), `HomeKitHost`; live view: stream setup (`StreamManagement`), RTP packets (`RTPPacketizer`), SRTP, sound (`AudioTranscoder`: AAC-LC to AAC-ELD), optional re-encoding (`VideoTranscoder` on VideoToolbox, steered by `RateControl` from the viewer's RTCP reports) and the stream itself (`LiveSession`); HKSV: the recording services and selection (`RecordingController`), the prebuffer (`Prebuffer`) and one recording sent to the hub (`RecordingSession`) | no | done |
| `Devices` | What a camera is (maker, model, serial, firmware, doorbell), its events (motion, doorbell presses) and its controls (PTZ, talking back, and declared items: day and night, image settings, volume, home, tours, relays), behind `CameraProvider`: `ReolinkProvider` (HTTP API) and `ONVIFProvider`; `DeviceReader` asks them in turn, `CameraControls` resolves each control to the first provider that offers it, `CameraSessions` shares one login per camera, and `ControlServer` serves the app over a socket (see [controls.md](controls.md)) | no | done |
| `Control` | Shared by the CLI and the app: the login service (`ServiceControl`, `LaunchAgent`, launchd), its log (`LogReader`) and the wording of camera checks (`CameraCheck`) | yes | done |
| `NVRApp` | The SwiftUI app (`Pond NVR.app`, built by `make app`). The main window has Live (`LiveStream`: the RTSP client and H.264 depacketizer feeding an `AVSampleBufferDisplayLayer` through a render synchronizer), Timeline (`TimelineModel`: segments at their recorded times in an `AVMutableComposition`) and Events. The Settings window has Cameras, Storage, Retention and Recorder over `AppModel`, which saves through `ConfigStore` and leaves reading passwords to `pond` | no | done but Events |
| `Storage` | SQLite index of segments, events, descriptions and embeddings | yes | later |
| `Detection` | Motion gate, YOLO in Core ML, Vision, a multi-object tracker, zones, event lifecycle | no | later |
| `Understanding` | Event descriptions (`Describer`: Foundation Models, image input, on-device only), SigLIP 2 embeddings of pictures and words (`SigLIP`, `BPETokenizer`), and questions read (`QuestionReader`: Foundation Models, guided; `PlainReader`; `TimeWords`). SigLIP rather than MobileCLIP: Apple's MobileCLIP weights are licensed for research | no | done |
| Search (in `Watch`) | `Understander` (the service: each event described and embedded, older ones too), the understanding table in `EventStore`, and `EventSearch` (filters, then ranking by picture match and sentence words). See [search.md](search.md) | yes | done |

The models sit behind small protocols (`DescriptionModel`, the query parser), so an MLX or cloud model could replace Apple's without touching the rest. The default is on-device only.

## Phases

The order of the work; [roadmap.md](roadmap.md) has each goal's status and plan, including audio and ONVIF.

0. **Scaffold and camera check.** The settings file, the `pond` command, TLV8. Done.
1. **Ingest and recording.** RTSP, fMP4 segments, retention, the app's live view and timeline. Done (the SQLite index waits for events).
2. **HAP core.** Pairing with the Home app; each camera appears with a motion sensor and snapshots. Done.
3. **Live view.** Stream setup, SRTP video, AAC-ELD audio, several viewers, optional re-encoding. Done.
4. **HKSV.** HomeKit Data Stream, recording settings, fMP4 from the prebuffer. Done.
5. **Detection and events.** The motion sensor switches from raw motion to "a relevant object in a zone".
6. **Understanding.** Descriptions and embeddings, including for older events.
7. **Search.** Plain-language questions, results that open the clip.

## What Reolink's RTSP server does

Seen on a Reolink E1 Pro (RTSP server "BC Streaming Media v2022.10.01"); `Ingest` copes with all of it:

- **Digest authentication** on DESCRIBE, SETUP and PLAY (realm `BC Streaming Media`).
- **Interleaved data before the PLAY reply:** an RTCP sender report can arrive on channel 1 before the `200 OK` for PLAY, so the reader must accept `$` frames while waiting for any RTSP reply.
- **Privacy mode:** every request succeeds but no RTP arrives, and the sender reports say 0 packets sent. Treat "connected, no video for 10 s, sender reports at 0" as *camera in privacy mode*, report it as that, and retry slowly instead of reconnecting in a loop. HomeKit can later show it through the camera's operating mode.
- **Uneven RTP timestamps:** the steps between frames vary (20 fps averages 4500 ticks at 90 kHz, but single steps range from about 100 to over 6000). The muxer must take each frame's own timestamp, not assume a fixed frame rate.
- **A slightly malformed SPS on the sub-stream** (`ffmpeg`: "Overread VUI by 8 bits"). Harmless for stream copy, and VideoToolbox accepts it.
- **The description does not always carry the codec parameters.** The sub-stream's SDP sometimes has an `a=fmtp` line with the SPS and sometimes none at all, from one connection to the next. The SPS also comes inside the video before each keyframe, so the resolution must be read from there when the description leaves it out (`FlowAnalyzer` does).
- Video first arrives 1–4 s after PLAY, with SPS and PPS before every keyframe.

## Recording format

Each recording is a fragmented MP4: an init segment (`ftyp` + `moov` with an `avc1`/`avcC` video track at 90 kHz and an `mp4a` AAC track at the camera's sample rate), then a `moof` + `mdat` fragment for every keyframe interval of at least 2 s. The video is the camera's own H.264, never re-encoded; SPS and PPS go in `avcC` and are taken out of the samples. A file cut off by a crash or an unplugged drive plays up to its last whole fragment.

Timing: video times are the camera's RTP timestamps from the first keyframe. Audio has its own RTP clock with an unrelated starting value; the first RTCP sender report on each track gives that clock's wall time, so audio is placed by wall time once and then follows its own clock. The same wall time dates the recording. Before any sender report (Reolink sends one at once), arrival time stands in.

Recordings decode completely in ffmpeg and open in AVFoundation (QuickTime's engine). A camera's frame timestamps can be uneven (gaps from 1 ms to 100 ms around a 50 ms average); they are kept as they are, so players show each frame when the camera says it was taken.

## Recording loop

`pond run` starts a `CameraWorker` thread per camera and a retention sweep every 5 minutes (and once at start). A worker connects, records, and on any failure (connection lost, the camera silent for 10 s, the drive gone) closes the current segment and connects again after 1, 2, 4 … up to 30 s. Each distinct problem is logged once, not on every retry. Privacy mode (the camera connected but its sender reports at 0 packets) is retried every 30 s. Ctrl-C or SIGTERM finishes the current segments cleanly; that is also how launchd stops the login service. While it runs, `pond run` holds a PreventUserIdleSystemSleep assertion (`pmset -g assertions` shows "pond is recording cameras").

**A camera with too many viewers** may stall: about a minute into a connection its video falls to almost nothing for 20–30 s, or thins out (fewer frames, gaps in the sound). `ffmpeg` sees the same, so it is the camera. The worker turns each stall into a short gap: it ends the segment, reconnects, and records again. Pond shares one connection per stream for this reason (see [cameras](cameras/README.md#connections)).

## HomeKit Secure Video

When the home hub wants a recording (on the motion sensor), it opens a `dataSend` stream over the HomeKit Data Stream. `RecordingSession` takes the prebuffer from the latest keyframe before the time the hub asked for, then the live frames, and re-encodes them (`VideoTranscoder`, not in real time) to the hub's chosen size, bitrate and frame rate, at a constant frame rate with a keyframe exactly at the start of each fragment: the hub treats its fragment length as a maximum. `FragmentWriter` writes them as fMP4, sent in chunks of at most 256 KB until the hub closes the stream. The camera's AAC-LC goes along unchanged when the hub chose AAC-LC at its sample rate.

## HomeKit references

There is no public specification for HKSV: it is reverse-engineered. The HomeKit layers are written from:
- **HAP-NodeJS** (Apache 2.0): camera controller, recording management, the data stream server and parser.
- **HomeKitADK** (Apache 2.0): HAP core, pairing, test vectors.

Code ported from these keeps a comment naming the source file.
