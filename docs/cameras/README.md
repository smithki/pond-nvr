# Cameras

Pond records what a camera sends over RTSP, without re-encoding it, so a camera needs to send **H.264** (H.265 is not supported yet). Each camera has two streams: the **main stream** (full resolution) is recorded and used for large live tiles and HomeKit Secure Video; the **sub-stream** (smaller) is used for small tiles, snapshots, and the Home app's live view unless re-encoding is chosen.

## By brand

| Brand | Stream addresses | Model, serial, firmware | Motion for HKSV | Doorbell presses | Page |
|---|---|---|---|---|---|
| Reolink | filled in | yes | yes | yes | [reolink.md](reolink.md) |
| ONVIF cameras | asked of the camera | yes | ONVIF events | ONVIF events, if the doorbell sends one | [onvif.md](onvif.md) |
| Other RTSP cameras | typed in | no | no | no | [onvif.md](onvif.md#cameras-without-onvif) |

Without motion from the camera (no ONVIF events, or no ONVIF at all), a camera still records continuously, shows live and works in the Home app's live view; HomeKit Secure Video needs motion to start a recording, so it waits for Pond's own detection. Reports of other models are welcome.

## What every camera needs

- **RTSP on**, with a username and password.
- **H.264** on both streams.
- **A keyframe every 2 seconds** or so (often called the I-frame or keyframe interval; set it to twice the frame rate). Live views start at a keyframe, recordings are cut at them, and HomeKit Secure Video wants one at the start of every fragment.

`pond camera add` and `pond camera test` (or Add Camera and Check Connection in the app) log in, read both streams and watch the video for a few seconds, then say what they found and what to change:

```
✓ main stream: H.264 High 5.1, 2560×1440, AAC-LC 16 kHz mono
✓ sub-stream: H.264 (resolution not announced), AAC-LC 16 kHz mono
✓ video arriving: 20.1 fps, a keyframe every 2.0 s, 2.4 Mbit/s
```

## Connections

Many cameras serve only a few RTSP connections at once, and refuse or starve the next one. Pond opens one connection per stream and shares it between the recorder, HomeKit and the app's windows, so other apps watching the camera (its own app, another NVR) are what use up the rest. If a camera's video stalls or thins out every minute or so, close the other apps watching it.

## Checking a camera by hand

With FFmpeg installed, using the camera's stream address:

```sh
ffprobe -rtsp_transport tcp -v error -show_entries stream=codec_name,width,height,r_frame_rate \
  "rtsp://USER:PASSWORD@CAMERA-IP:554/STREAM-PATH"
```

The password is on the command line here only; Pond keeps it in the Keychain and never in the settings file.

## Storage per camera

At 2560×1440 and about 3 Mbit/s, a camera records roughly 32 GB a day. Settings › Storage shows how long the drive holds from what each camera really sends, and Add Camera shows what a new camera adds.
