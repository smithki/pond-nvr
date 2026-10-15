# Reolink

Reolink cameras are supported best. Besides RTSP, Pond uses their HTTP API (`api.cgi`) to learn what a camera is, to watch its motion detection for HomeKit Secure Video, and to watch a doorbell's button.

Tried: **E1 Pro** and **Video Doorbell WiFi**. Other models with RTSP and the HTTP API should work the same way; reports are welcome.

## Adding one

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

The API is polled about once a second while the camera is in HomeKit. It is tried over HTTPS first: Reolink cameras use a certificate they made themselves, which Pond accepts for the camera's own address only. Older firmware answers only on plain HTTP, where the login crosses the network in clear; Pond falls back to it, so keep such cameras on a trusted network.

## Quirks

What Reolink's RTSP server does, all of which Pond copes with:

- **Privacy mode** looks like a broken stream: the camera answers every request and then sends no video, with sender reports saying 0 packets. Pond reports it as privacy mode and retries slowly; turn it off in the Reolink app.
- **Few connections**: an E1 serves only a few RTSP clients at once, and the next one gets no answer, or the video stalls about a minute in. Close the Reolink app and other viewers if a camera keeps dropping.
- **Uneven timestamps**: steps between frames vary a lot; Pond keeps each frame's own time.
- **The sub-stream's description** sometimes leaves out the codec parameters; Pond reads them from the video instead.
- **Doorbells** send a 4:3 sub-stream that looks small in the Home app; choose re-encoding for the Home app's picture in the camera's HomeKit settings for a sharper one.
