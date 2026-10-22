# Security

## Camera passwords

The settings file holds only usernames, and `pond check` refuses addresses with a login in them. Each password is a generic password in the login Keychain, service `pond`, account the camera's ID, and is sent only to that camera (RTSP Digest authentication, so it never crosses the network in clear). The settings file is written readable only by its owner. The cameras speak plain RTSP, so the video itself is not encrypted: keep them on a trusted network or VLAN.

**Only `pond` reads the passwords.** The app never does: it hands a password to `pond camera password ID --password-stdin` to save it (on standard input, never in arguments, where other programs could see it), has `pond` move or remove it, runs checks of a saved camera through `pond camera test ID --json`, and gets live video and works the cameras' controls through the service's local sockets (`streams.sock` and `controls.sock`, next to the settings file, usable only by you). To show whether a camera has a password, it asks the Keychain whether the item exists, which reads no secret and so never asks for access. One program reading the items is what keeps the Keychain from asking you to let another in, camera by camera; a password just typed into Add Camera is tried by the app directly, before it is saved.

To learn what a camera is (model, serial number, firmware, doorbell or not), pond also logs in to the camera's own API when it is added or checked (`pond camera identify`), and doorbells' to watch their button:

- **Reolink**: the HTTP API (`api.cgi`), over HTTPS first. Reolink cameras use a certificate they made themselves; pond accepts it for the camera's own address only. Older firmware answers only on plain HTTP, where the login (username and password, as JSON) crosses the network in clear; pond falls back to it, so on such cameras the network matters as much as for the video.
- **ONVIF**: the WS-Security username token with a password digest (SHA-1 of a nonce, the time and the password), so the password itself is not sent.

## HomeKit

- Each camera is a HomeKit accessory with its own Ed25519 identity. The keys of the controllers that paired with it (your devices and the home hub) are kept in the Keychain. Losing them means pairing every camera again and losing its HKSV history.
- A camera is served to HomeKit only once chosen (in the app, or `pond camera set ID --homekit on`). Its setup code is generated with its HomeKit identity and kept in the Keychain (service `pond-homekit`), which only the service reads. While the camera is not yet in a home, the service also puts the code in `homekit-status.json` (readable only by you) for the app to show; once added, it is taken out.
- Everything after pairing is encrypted (ChaCha20-Poly1305 sessions, SRTP for video, encrypted data streams for HKSV), as HAP requires.

## Remote access

Off unless set (`remote.enabled`). See [remote.md](remote.md) for how a connection is made.

- **Keys.** This Mac has an Ed25519 key to sign with and an X25519 key to receive sealed messages, kept in the Keychain (service `pond-remote`), as are the keys of each device or Pond paired with it.
- **Pairing.** Only with a code this Mac showed (`pond remote pair`): good once, for ten minutes, proved with an HMAC of the device's keys under the code's secret, never sent. Paired devices can be removed (`pond remote unpair`).
- **The signaling service** (one's own, `deploy/`) passes on sealed envelopes between mailboxes and keeps nothing. Each envelope is encrypted to its recipient (HPKE: X25519, HKDF-SHA256, ChaCha20-Poly1305) and signed by its sender inside, within five minutes of being sent, never accepted twice. The service sees mailbox ids (hashes) and sizes, never what's in them: not the offers, the addresses or the credentials of a connection. Only paired devices' offers are answered; anyone else's go unopened.
- **Connections** are checked with STUN signed with a password each side made for that attempt and sent the other sealed, so nobody else can answer them. Only this Mac's temporary IPv6 addresses are offered, never its stable one, and its own addresses can be left out (`remote.shareLocalAddresses`). The public address it learns comes from the signaling host's own STUN, not a third party's. A relay (coturn, one's own) sees the two ends' public addresses and passes their packets on; credentials for it are made from a shared secret kept in the Keychain, and last a day.
- **What a connection carries** is, so far, only its checks and a few pings to time it; the encrypted session for video and control comes next (M4 on the roadmap).

## What listens on the network

| Port | What | Who can use it |
|---|---|---|
| One TCP port per camera in HomeKit | The HAP server, advertised over Bonjour | paired devices only |
| UDP ports per live stream | SRTP to the viewing device | the device that set up the stream |
| One TCP port per camera recording to HKSV | HomeKit Data Stream | the home hub, with keys from its HAP session |
| (Outgoing) TCP 9000 to each Reolink camera | Baichuan, Reolink's own protocol: privacy mode, events pushed | the camera's login, hashed and encrypted |
| (Outgoing) a WebSocket to the signaling service, while remote access is on | Sealed envelopes to and from paired devices | (it can't read them) |
| A UDP port per remote connection (any, or `remote.port`), while one is being made or used | Connection checks signed with that connection's password; then its traffic | the paired device or Pond it was offered to |
| A Unix socket, `streams.sock` | Live video for the app (`StreamRelay`) | this user only (next to the settings file) |
| A Unix socket, `controls.sock` | Camera controls for the app and the CLI (`ControlServer`): moving, positions, settings, privacy, talking through a camera's speaker | this user only (next to the settings file) |

A camera made private (`privacy.json`, next to the settings file) is neither recorded, served live, nor served to HomeKit until made public; recordings made before stay as they are. See [controls.md](controls.md#privacy).

The app's own UI is local only; there is no web server. macOS asks once for Local Network access: for `pond` the first time the login service connects to a camera (until it is allowed, connections fail with "No route to host" and are retried), and again when the HAP servers start.

## The login service

`pond service install` writes `~/Library/LaunchAgents/camera.pond.recorder.plist`, which runs `pond run` as you, in your login session. It has your rights and nothing more: the Keychain items it reads are the camera passwords, and it writes only to the storage folders and `~/Library/Logs/Pond/`. A build signed with another certificate (or ad hoc) may make macOS ask again before it reads the Keychain; see [development.md](development.md#build-check-test).
