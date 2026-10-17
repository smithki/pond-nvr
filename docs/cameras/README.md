# Cameras

Pond records what a camera sends over RTSP, without re-encoding it, so a camera needs to send **H.264** (H.265 is not supported yet). Each camera has two streams: the **main stream** (full resolution) is recorded and used for large live tiles and HomeKit Secure Video; the **sub-stream** (smaller) is used for small tiles, snapshots, and the Home app's live view unless re-encoding is chosen.

## By brand

| Brand | Stream addresses | Model, serial, firmware | Motion for HKSV | Doorbell presses | Controls | Page |
|---|---|---|---|---|---|---|
| Reolink | filled in | yes | yes | yes | its own API, ONVIF for the rest | [reolink.md](reolink.md) |
| ONVIF cameras | asked of the camera | yes | ONVIF events | ONVIF events, if the doorbell sends one | what the camera offers over ONVIF | [onvif.md](onvif.md) |
| Other RTSP cameras | typed in | no | no | no | none | [onvif.md](onvif.md#cameras-without-onvif) |

**Talks through.** Each camera's settings (Device) say how Pond talks to it, and switch it: its make's own way (Reolink), ONVIF, or **Video only**, where Pond logs in only for the video, never for details or events (for an account limited to video, a camera whose own motion detection is too noisy, or one whose events another system already watches). Video only pauses HomeKit Secure Video, keeping the setting for when you switch back.

Without motion from the camera (no ONVIF events, video only, or no ONVIF at all), a camera still records continuously, shows live and works in the Home app's live view; HomeKit Secure Video needs motion to start a recording, so it waits for Pond's own detection. Reports of other models are welcome.

## Controls

Watching one camera on its own, **Controls** under it opens a dock of what the camera can do, and only that: a pad to move it, its kept positions (each with a picture of what it shows), day and night, a picture saved to Pictures › Pond, talking through its speaker and its volume. Its other settings (brightness, contrast, saturation, sharpness, setting home, relays, and any its make adds) are in the **Adjustments** sidebar, opened from the dock's right edge. **Privacy** in the dock (or **Make Private** in its menu in the list) stops Pond recording it, showing it and serving it to HomeKit until turned off, for any camera. ⌥⌘L shows and hides the dock; a camera's menu in the list has **Control This Camera**.

Each control goes through the best way Pond has for that camera: its make's own API where Pond knows one, ONVIF for everything else. [controls.md](../controls.md) has how that's chosen; `pond camera controls ID` shows it for a camera.

## Finding cameras

Add Camera lists the cameras on your network that aren't set up, and **Find Cameras** in the main window's toolbar looks whenever you like. When it finds cameras that aren't set up, it turns into **Cameras Found** with a count until you add or ignore them. Ignored cameras are listed apart in its card, each with **Show Again**, and Add Camera leaves them out unless you choose **Show Ignored**. Pond looks every way at once, none needing a login:

- **ONVIF discovery**: cameras that answer it say their name and model (most makes with ONVIF switched on).
- **Reolink's own discovery**: Reolink cameras don't answer ONVIF discovery, but answer this, with the name given in the Reolink app.
- **A look at this Mac's own network** for addresses that take video (RTSP, port 554) or answer ONVIF on port 8000, for cameras that answer neither; they're named as your router names them.

It looks each time Pond opens, once a day while it stays open, and each time Add Camera opens. A camera on another network or VLAN can't be found; add it by its address. `pond camera discover` shows the same from a terminal.

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
