# Reolink

Reolink cameras are supported best. Besides RTSP, Pond uses their HTTP API (`api.cgi`) to learn what a camera is, to watch its motion detection for HomeKit Secure Video, to watch a doorbell's button, and for its controls; what the API doesn't do, Pond does over ONVIF.

Tried: **E1 Pro** and **Video Doorbell WiFi**. Other models with RTSP and the HTTP API should work the same way; reports are welcome.

## Adding one

Pond finds Reolink cameras on your network by Reolink's own discovery (a broadcast they answer with the name they were given), since they don't answer ONVIF discovery; Add Camera lists them.


```sh
pond camera add porch --host 192.168.1.20 --name "Front porch"
```

or **Add Camera** in the app, with the camera's address. Pond fills in the stream addresses:

| Stream | Address |
|---|---|
| Main | `rtsp://HOST:554/h264Preview_01_main` |
| Sub | `rtsp://HOST:554/h264Preview_01_sub` |

(`h265Preview_01_main` returns the same H.264 stream on cameras set to H.264.) Advice in the app names "the Reolink app" where something needs changing on the camera.

## Settings on the camera

In the Reolink app:

- **RTSP**: Settings › Network › Advanced › Server settings › RTSP on.
- **Encoding**: H.264 on both streams (Settings › Display or Stream, depending on the model).
- **Interframe Space** (the keyframe interval): twice the frame rate, so a keyframe every 2 seconds.
- **Motion detection** on, for HomeKit Secure Video: Pond takes the camera's motion (and, on models with it, person, vehicle and animal detection) as HomeKit's motion sensor.

## What Pond reads from the API

| What | Calls | Used for |
|---|---|---|
| Model, serial number, firmware, doorbell or not | `GetDevInfo` | The camera's details in the app and in HomeKit, and recognising a doorbell. |
| Motion and smart detection | `GetEvents`, else `GetMdState` | HomeKit's motion sensor, which starts HomeKit Secure Video recordings. |
| Doorbell presses | `GetEvents` | Ringing in the Home app. |
| What it can do | `GetAbility` | Which controls to offer: only those it lists with a version. |
| Moving it | `PtzCtrl` | The pad: one direction at a time (the diagonals included) at a speed, or zoom; then `Stop`. |
| Positions | `GetPtzPreset`, `SetPtzPreset` | The kept positions (the enabled ones), keeping and removing them, and going to one. |
| Day and night | `GetIsp`, `SetIsp` | Auto, Color or Black&White. |
| Speaker volume | `GetAudioCfg`, `SetAudioCfg` | The volume slider. |
| IR lights | `GetIrLights`, `SetIrLights` (ability `ledControl`) | Auto or Off, under Light. |
| Status light | `GetPowerLed`, `SetPowerLed` (ability `powerLed`) | On or off, under Light. |
| Mirror and flip | `mirroring` and `rotation` in `GetIsp`, `SetIsp` (`ispMirror`, `ispFlip`) | For a camera on a ceiling or a wall, under Device. |

Talking back, brightness, contrast, saturation and sharpness go over ONVIF, which Reolink cameras speak too (turn it on in the Reolink app: Settings › Network › Advanced › Server settings).

Pond keeps one login per camera and shares it between everything that asks, logging out when the service stops. The API is polled about once a second while the camera is in HomeKit. It is tried over HTTPS first: Reolink cameras use a certificate they made themselves, which Pond accepts for the camera's own address only. Older firmware answers only on plain HTTP, where the login crosses the network in clear; Pond falls back to it, so keep such cameras on a trusted network.

## Reolink's own protocol (Baichuan)

Besides RTSP and the HTTP API, Pond keeps one connection per camera on TCP port 9000 in the protocol Reolink's apps use, Baichuan (as Home Assistant's integration does; Pond's follows reolink_aio). Over it:

- **Privacy mode, both ways.** Made private in Pond, the camera's own privacy mode turns on (it stops sending video and closes its HTTP API, as it does from the Reolink app); turned on or off in the Reolink app, Pond follows within a second. The HTTP API has no privacy-mode command.
- **What it notices, pushed.** Motion, a person, vehicle or animal, and a doorbell's visitor arrive as they happen, rather than Pond asking the HTTP API every second. A camera that doesn't answer on 9000 is asked over HTTP as before.

The connection logs in with the camera's password (hashed with the camera's nonce, then encrypted) and takes one of its logins. `pond camera baichuan ID` logs in and says what the camera is and whether it's private; `pond camera baichuan ID watch` prints what it pushes; `pond camera baichuan ID privacy-on|privacy-off` switches it.

## Quirks

What Reolink's RTSP server does, all of which Pond copes with:

- **Privacy mode** looks like a broken stream: the camera answers every request and then sends no video, with sender reports saying 0 packets. Pond reports it as privacy mode and retries slowly; turn it off in the Reolink app.
- **Few connections**: an E1 serves only a few RTSP clients at once, and the next one gets no answer, or the video stalls about a minute in. Close the Reolink app and other viewers if a camera keeps dropping.
- **Uneven timestamps**: steps between frames vary a lot; Pond keeps each frame's own time.
- **The sub-stream's description** sometimes leaves out the codec parameters; Pond reads them from the video instead.
- **Over ONVIF**, an E1 Pro answered everything but the stream-address request, which it never answered; Pond asks Reolink cameras through their own API, so this doesn't matter for adding them.
- **Privacy mode closes the stream**: while private, an E1 Pro closes the RTSP connection and says it has no stream at the address (rather than sending nothing); Pond knows it's private from Baichuan, so this isn't counted as a problem. Its HTTP API is off too, so settings changed while it's private wait until it's back. Turned off, video returns in about 10 s; Pond waits up to 45 s (`BaichuanPrivacy.wakeTime`) before a failure to connect counts. Now and then it doesn't come back: privacy off, its HTTP API and Baichuan answer but its RTSP port refuses connections (RTSP still enabled in its settings) until it's restarted. The doctor reports it.
- **Few logins**: a camera allows only a few API logins at once, and answers "max session" after; Reolink's apps and other software count too. Pond shows the control as busy and tries again; close other apps if it stays busy.
- **The guard position**: with a guard position set and on (in the Reolink app's PTZ settings), a PTZ camera goes back to its guard position after a while unmoved (a minute by default), so it can look as if it moved on its own. Pond's positions are the camera's own presets and are left as they are.
- **Volume over ONVIF** is fixed (an E1 Pro gives a range of 50 to 50); Pond sets it through the API instead.
- **A busy camera**: a Wi-Fi model streaming both its streams can run its processor near full, and then answers the API slowly or not at all, and its video stalls. A stronger Wi-Fi signal, or a lower main-stream bitrate, helps.
- **Doorbells** send a 4:3 sub-stream that looks small in the Home app; choose re-encoding for the Home app's picture in the camera's HomeKit settings for a sharper one.
