# ONVIF and other RTSP cameras

Any camera that sends H.264 over RTSP can be recorded, watched live and added to the Home app. What Pond can learn from a camera beyond its video depends on what else it speaks.

## ONVIF cameras

Many cameras (Hikvision, Dahua, Amcrest, Axis, TP-Link Tapo and others) speak ONVIF. Pond uses it to find the camera's stream addresses (its media profiles: the largest H.264 one is the main stream, the smallest the sub-stream) and to read its maker, model, serial number and firmware. It logs in with a WS-Security password digest, so the password itself is not sent, allowing for a camera whose clock is off. Its **events** drive HomeKit: Pond subscribes to them (a pull-point subscription, renewed as it goes), and any motion detector the camera reports, plain motion or its person, vehicle and animal detection, turns HomeKit's motion sensor on, which starts HomeKit Secure Video recordings. A doorbell's button press, reported under a topic such as `Visitor` or `Doorbell`, rings in the Home app.

Its **controls** come from ONVIF too, each only if the camera has it:

| What | ONVIF | In the app |
|---|---|---|
| Pan, tilt, zoom | PTZ `ContinuousMove`, `Stop` | the move pad, zoom buttons |
| Positions | PTZ `GetPresets`, `SetPreset`, `GotoPreset`, `RemovePreset` | the positions in the dock |
| Home | PTZ `GotoHomePosition`, `SetHomePosition` (if the node says `HomeSupported`) | Home in the dock; Set Home in Adjustments |
| Preset tours | PTZ `GetPresetTours`, `OperatePresetTour` | a switch per tour, in the dock |
| Day and night | Imaging: the IR cut filter (`AUTO`, `ON` for day, `OFF` for night) | Day & Night |
| Brightness, contrast, saturation, sharpness | Imaging `GetOptions` (their ranges), `SetImagingSettings` | Adjustments |
| Speaker volume | Media: the audio output configuration's level | the speaker slider (not if its range is fixed) |
| Restart | Device `SystemReboot` | Adjustments › Device, asking first |
| Relays | DeviceIO (or the device service) `GetRelayOutputs`, `SetRelayOutputState` | Adjustments: a switch if it stays as set, a button (asking first) if it springs back |
| Talking back | The RTSP backchannel: `Require: www.onvif.org/ver20/backchannel`, then G.711 (µ-law or A-law, as the camera asks) | the microphone button on its tile and in the dock |

An ONVIF user may need the **Operator** or **Administrator** role for PTZ and imaging; a **User** can usually only watch.

`pond camera onvif ID --events [SECONDS]` prints the camera's events as they come, with what Pond makes of them (`→ motion`, `→ still`, `→ pressed`), to see what a camera reports.

## Adding one

**Add Camera** in the app, or `pond camera add`, asks the camera for its stream addresses before checking it: through its make's own API if Pond knows it (Reolink), else through ONVIF. The addresses are shown under **Stream addresses** in Add Camera, and can be changed later in the camera's settings (Advanced).

```sh
pond camera add garden --host 192.168.1.30 --name "Garden"   # finds the stream addresses, checks the camera
pond camera onvif garden                                       # what the camera says over ONVIF, step by step
```

`pond camera onvif ID` shows where the camera's ONVIF service is, whether its clock agrees, what it is, its services and media profiles, and the stream addresses Pond would choose (`--trace` shows each request and how long the camera took). It changes nothing; it says how to use the addresses if they differ from the camera's settings.

A camera that doesn't say where its streams are gets Reolink's addresses; give them yourself with `--main` and `--sub` (or in the app), from the camera's manual or its own app. They often look like `rtsp://HOST:554/stream1` and `…/stream2`, or `rtsp://HOST:554/Streaming/Channels/101` and `…/102`. The addresses are kept without a login; the password is kept in the Keychain.

## Settings on the camera

- **RTSP on**, and **ONVIF on** if the camera has a switch for it (some need an ONVIF user of their own).
- **H.264** on both streams; turn off "H.264+", "smart codec" or similar, which some cameras use to stretch keyframes far apart.
- **A keyframe every 2 seconds** or so.
- **No B-frames** if the camera offers the choice (live cameras rarely use them); Pond's re-encoding for the Home app doesn't take them.

## Cameras without ONVIF

A camera with RTSP but no ONVIF works the same way, without its details: add it with its stream addresses (Add Camera's **Stream addresses**, or `--main` and `--sub`). The app then names "the camera's own app" where something needs changing.
