# Security

## Camera passwords

The settings file holds only usernames, and `pond check` refuses addresses with a login in them. Each password is a generic password in the login Keychain, service `pond`, account the camera's ID, and is sent only to that camera (RTSP Digest authentication, so it never crosses the network in clear). The settings file is written readable only by its owner. The cameras speak plain RTSP, so the video itself is not encrypted: keep them on a trusted network or VLAN.

**Only `pond` reads the passwords.** The app never does: it hands a password to `pond camera password ID --password-stdin` to save it (on standard input, never in arguments, where other programs could see it), has `pond` move or remove it, runs checks of a saved camera through `pond camera test ID --json`, and gets live video through the service's local socket (`streams.sock`, next to the settings file, readable only by you). To show whether a camera has a password, it asks the Keychain whether the item exists, which reads no secret and so never asks for access. One program reading the items is what keeps the Keychain from asking you to let another in, camera by camera; a password just typed into Add Camera is tried by the app directly, before it is saved.

To learn what a camera is (model, serial number, firmware, doorbell or not), pond also logs in to the camera's own API when it is added or checked (`pond camera identify`), and doorbells' to watch their button:

- **Reolink**: the HTTP API (`api.cgi`), over HTTPS first. Reolink cameras use a certificate they made themselves; pond accepts it for the camera's own address only. Older firmware answers only on plain HTTP, where the login (username and password, as JSON) crosses the network in clear; pond falls back to it, so on such cameras the network matters as much as for the video.
- **ONVIF**: the WS-Security username token with a password digest (SHA-1 of a nonce, the time and the password), so the password itself is not sent.

## HomeKit

- Each camera is a HomeKit accessory with its own Ed25519 identity. The keys of the controllers that paired with it (your devices and the home hub) are kept in the Keychain. Losing them means pairing every camera again and losing its HKSV history.
- A camera is served to HomeKit only once chosen (in the app, or `pond camera set ID --homekit on`). Its setup code is generated with its HomeKit identity and kept in the Keychain (service `pond-homekit`), which only the service reads. While the camera is not yet in a home, the service also puts the code in `homekit-status.json` (readable only by you) for the app to show; once added, it is taken out.
- Everything after pairing is encrypted (ChaCha20-Poly1305 sessions, SRTP for video, encrypted data streams for HKSV), as HAP requires.

## What listens on the network

| Port | What | Who can use it |
|---|---|---|
| One TCP port per camera in HomeKit | The HAP server, advertised over Bonjour | paired devices only |
| UDP ports per live stream | SRTP to the viewing device | the device that set up the stream |
| One TCP port per camera recording to HKSV | HomeKit Data Stream | the home hub, with keys from its HAP session |
| A Unix socket, `streams.sock` | Live video for the app (`StreamRelay`) | this user only (next to the settings file) |

The app's own UI is local only; there is no web server. macOS asks once for Local Network access: for `pond` the first time the login service connects to a camera (until it is allowed, connections fail with "No route to host" and are retried), and again when the HAP servers start.

## The login service

`pond service install` writes `~/Library/LaunchAgents/camera.pond.recorder.plist`, which runs `pond run` as you, in your login session. It has your rights and nothing more: the Keychain items it reads are the camera passwords, and it writes only to the storage folders and `~/Library/Logs/Pond/`. A build signed with another certificate (or ad hoc) may make macOS ask again before it reads the Keychain; see [development.md](development.md#build-check-test).
