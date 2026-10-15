# ONVIF and other RTSP cameras

Any camera that sends H.264 over RTSP can be recorded, watched live and added to the Home app. What Pond can learn from a camera beyond its video depends on what else it speaks.

## ONVIF cameras

Many cameras (Hikvision, Dahua, Amcrest, Axis, TP-Link Tapo and others) speak ONVIF. Today Pond uses it to read the camera's maker, model, serial number and firmware (`GetDeviceInformation`, logging in with a WS-Security password digest, so the password itself is not sent). The stream addresses still have to be given by hand, and motion events are not read yet, so HomeKit Secure Video does not start recordings for these cameras. Both are next on the [roadmap](../roadmap.md#onvif).

## Adding one

Find the camera's RTSP addresses in its manual or its own app; they often look like `rtsp://HOST:554/stream1` and `…/stream2`, or `rtsp://HOST:554/Streaming/Channels/101` and `…/102`. Then:

```sh
pond camera add garden --host 192.168.1.30 --name "Garden" --no-test
pond camera set garden --main rtsp://192.168.1.30:554/stream1 --sub rtsp://192.168.1.30:554/stream2
pond camera test garden                         # log in, read both streams, watch the video
pond camera identify garden --provider onvif    # the camera's details, through ONVIF
```

Add these cameras from the terminal for now: the app's Add Camera assumes Reolink's stream addresses, and the camera's settings show the addresses (under Advanced) without editing them yet. Once added, the app does everything else. The addresses are kept without a login; the password is kept in the Keychain.

## Settings on the camera

- **RTSP on**, and **ONVIF on** if the camera has a switch for it (some need an ONVIF user of their own).
- **H.264** on both streams; turn off "H.264+", "smart codec" or similar, which some cameras use to stretch keyframes far apart.
- **A keyframe every 2 seconds** or so.
- **No B-frames** if the camera offers the choice (live cameras rarely use them); Pond's re-encoding for the Home app doesn't take them.

## Cameras without ONVIF

A camera with RTSP but no ONVIF works the same way, without its details: add it, set its stream addresses, and check it. The app then names "the camera's own app" where something needs changing.
