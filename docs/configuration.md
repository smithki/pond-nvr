# Configuration

Settings are changed in the app or with the `pond` command; both go through the same code. They are kept in one JSON file, `~/Library/Application Support/Pond/config.json`, which can also be read or edited by hand. `POND_CONFIG` or `--config FILE` names another file. Check it with:

```sh
pond check
```

(`pond init` creates the file) which reports every problem in the settings, whether the storage folders are ready (and how much space is free), and whether each camera has a password in the Keychain.

`pond` and the app save only settings without problems, write the file atomically and keep it readable only by you. A file written by a newer pond is refused rather than half understood (`version`).

## Example

```json
{
  "version": 1,
  "storage": {
    "recordings": "/Volumes/Pond/recordings",
    "database": "~/Library/Application Support/Pond/pond.sqlite"
  },
  "retention": {
    "continuous": { "days": 7 },
    "events": { "days": 30 },
    "minFreeGB": 25
  },
  "cameras": [
    {
      "id": "porch",
      "name": "Front porch",
      "main": "rtsp://192.168.1.20:554/h264Preview_01_main",
      "sub": "rtsp://192.168.1.20:554/h264Preview_01_sub",
      "username": "admin",
      "zones": [
        { "id": "steps", "name": "Steps", "points": [[0.30, 0.55], [0.70, 0.55], [0.75, 1.0], [0.25, 1.0]],
          "categories": ["person", "package"] },
        { "id": "road", "name": "Road", "points": [[0, 0.1], [1, 0.1], [1, 0.3], [0, 0.3]], "kind": "ignore" }
      ]
    }
  ]
}
```

Only `storage` is required; everything else has the defaults shown.

## This Pond

| Setting | Default | What it is |
|---|---|---|
| `name` | this Mac's name | How this Pond is shown beside others paired with it (in the Recording button's menu, the camera rail, the Timeline), and the name devices pairing with it see. In the app: Settings › General. |
| `testFeatures` | off | Beta and test features: features tried before they're finished, each turned on of its own in `testFeaturesOn`. Off, none is on, whatever `testFeaturesOn` says. In the app: Settings › Advanced. |
| `testFeaturesOn` | none | The beta and test features turned on: `testScenes`, test scenes kept from this Pond's events (beside its database, on this Mac only, past event retention) for checking a new version with `pond advanced scenes`. |

## Storage

| Setting | Command | What it is |
|---|---|---|
| `storage.recordings` | `pond storage recordings PATH` | Folder for continuous recording: on an external drive or a NAS share. |
| `storage.events` | `pond storage events PATH\|same` | Optional. Left out (the default, and all the app offers), event clips and snapshots go in their own `events` folder beside `continuous` in `recordings`. Set by hand, they go to another folder, e.g. on a different drive. |
| `storage.database` | `pond storage database PATH` | The SQLite index. Keep it on the internal disk. |

Paths are full paths; `~` is allowed.

**What goes where.** Continuous recording is one MP4 per camera per minute, named by the UTC time of its first frame:

```
<recordings>/continuous/<camera>/<YYYY-MM-DD>/<HH-MM-SS>.mp4
```

A minute being written ends in `.mp4.partial` and gets its final name when complete; retention never touches it. After a crash the `.partial` file is still playable up to its last 2 s, and `pond run` renames it at the next start. Each file is a complete MP4 that starts on a keyframe, so any one plays on its own (QuickTime, VLC, ffmpeg). Each event's clip is in `<events>/events/<camera>/<YYYY-MM-DD>/`, beside its picture and named like it: its stretch of the recording and 3 s either side, copied as recorded (no re-encoding) about a minute after it ends, once the minute it ended in is complete. Events from before clips existed get one too, while their recordings are still there. A clip is the whole event, however long.

**Prepared folders.** A storage folder is used only while it holds a marker file, `.pond-storage`, written when the folder is chosen (`pond storage recordings`, `pond init --recordings`, or the app). If the SSD is unplugged or the NAS share is not mounted, its folder under `/Volumes` disappears. Without the marker check, recording would create that folder again on the boot disk and fill it. Instead pond stops recording to it and says the folder was not found. For the same reason a new folder directly in `/Volumes` is refused: choose a folder *on* the drive, such as `/Volumes/Pond/recordings`.

**Moving to a NAS.** Mount the share (Finder, or a login item), choose a folder on it (`pond storage recordings /Volumes/share/pond`), and the new folder is prepared. Recording already made stays where it is until retention removes it. For a NAS, put `storage.database` on the internal disk: SQLite over SMB is unreliable.

## Retention

| Setting | Command | Default | What it does |
|---|---|---|---|
| `retention.continuous.days` | `pond retention continuous DAYS` | 7 | Continuous recording older than this is deleted. |
| `retention.continuous.maxSizeGB` | `pond retention max-size GB\|none` | none | Optional cap on the space continuous recording may use. Above it, the oldest is deleted. |
| `retention.events.days` | `pond retention events DAYS` | 30 | Event clips and snapshots older than this are deleted. Independent of continuous recording: clips are copies, so they outlive the footage they came from. |
| `retention.minFreeGB` | `pond retention reserve GB` | 25 | Space always left free on each storage volume. |

**Overwriting the oldest.** When the drive's free space drops under `minFreeGB`, the oldest continuous recording is deleted until it is back above, whatever `continuous.days` says. So the drive never fills up: when it is too small for the days asked for, it keeps as many as fit, and says how many that is. Event clips are never deleted for space, only by age: if they alone fill the drive, the app warns instead.

GB here are 1,000,000,000 bytes, as drives are sold. One camera recording its 2560×1440 main stream uses about 32 GB a day, so a 2 TB SSD holds roughly 7 weeks for one camera, or 2 weeks for four.

## Remote access

Optional, and off unless set (Settings › Remote Access, or here): reaching this Mac from outside its network, through a signaling service you run (`deploy/`). The two ends find a path between them and connect directly where they can; the signaling service passes on only sealed messages it can't read. How it works, and what to do when it can't connect: [remote.md](remote.md).

| Key | Default | What it does |
| --- | --- | --- |
| `remote.enabled` | `false` | `true` to keep this Mac reachable: the service stays connected to the signaling service, and answers pairing and connections. |
| `remote.signaling` | none | The signaling service's address: `wss://HOST` (or `ws://` on your own network, for testing). |
| `remote.stun` | the signaling host, port 3478 | Where this Mac learns the address the world sees it at: `HOST[:PORT]`. pond-signal answers there (and on the next port, for telling what kind of router this Mac is behind). |
| `remote.port` | any | A fixed UDP port to be reached on: forward it on the router when no other path works (the diagnosis says so). |
| `remote.shareLocalAddresses` | `true` | `false` to offer only the public address the router shows, never this Mac's own (devices on the same network then meet through the router). |
| `remote.mesh` | `false` | `true` to connect only over a mesh (Tailscale or Headscale): only the tunnel's addresses are offered, no public address is learned, no relay is used. |
| `remote.meshSubnets` | Tailscale's | The mesh's ranges, if not `100.64.0.0/10` and `fd7a:115c:a1e0::/48`. |
| `remote.relay` | none | A relay of your own (coturn, `deploy/`'s relay profile), `HOST[:PORT]`, for when no direct path works. Its shared secret is kept in the Keychain: `pond remote relay-secret` (read from standard input). |

From the command line, with the service running: `pond remote pair` shows a code and QR code (good once, for ten minutes); `pond remote devices` lists those paired; `pond remote unpair ID` removes one; `pond remote join CODE` pairs this Mac with another Pond, by the code that one showed; `pond remote connect DEVICE` finds a path to a paired device or Pond and says how it went (or why it couldn't, and what would fix it); `pond remote watch DEVICE CAMERA` watches one of its cameras over an encrypted session, keeps what came as an MP4 and says how it went; `pond remote cameras DEVICE`, `events DEVICE`, `search DEVICE QUESTION`, `picture DEVICE EVENT` and `clip DEVICE EVENT` ask one for its cameras, events, pictures and clips ([remote.md](remote.md)). This Mac's keys and its devices' are kept in the Keychain (service `pond-remote`).

## Cameras

```sh
pond camera list
pond camera add ID --host HOST [--name NAME] [--username USER] [--main URL] [--sub URL] [--password-stdin] [--no-test]
pond camera set ID [--name NAME] [--host HOST] [--username USER] [--main URL] [--sub URL]
pond camera password ID [--password-stdin] [--no-test]
pond camera test ID [--seconds N]
pond camera rename ID NEW-ID
pond camera move ID POSITION|top|bottom
pond camera remove ID [--delete-recordings] [--yes]
```

`add` asks the camera for its stream addresses (Reolink's own, or ONVIF's) unless `--main` and `--sub` give them, and falls back to Reolink's (see [ONVIF and other RTSP cameras](cameras/onvif.md)); `--host` on `set` changes the host in both. `add` and `password` log in to the camera before saving anything, so a wrong password is caught at once; `--no-test` skips that for a camera that is offline. The password is asked for without echo, or read from standard input with `--password-stdin` (for scripts: `security find-generic-password … -w | pond camera password porch --password-stdin`). `move` changes a camera's place in the list (counted from 1): the order is the cameras' priority, which the app follows in the live grid and the timeline, and where the app's drag-to-reorder saves to. `rename` carries the Keychain item over; `remove` deletes the camera and its password, after confirmation, and leaves its recordings to retention; with `--delete-recordings` it deletes its recordings and event clips too (the app's Remove Camera and Recordings).

| Setting | What it is |
|---|---|
| `cameras[].id` | Lowercase letters, digits and dashes, starting with a letter; unique. Used in file paths, the database, the Keychain and the HomeKit identity. Change it only with `pond camera rename` (or the app), which carries the password over; after pairing with HomeKit it should not change. |
| `cameras[].name` | Shown in the app and in the Home app. |
| `cameras[].main`, `cameras[].sub` | `rtsp://` addresses of the main stream and the sub-stream, **without a login**. For Reolink, `rtsp://HOST:554/h264Preview_01_main` and `…_sub`. |
| `cameras[].username` | The camera login. Default `admin`. |
| `cameras[].kind` | `camera` (default) or `doorbell`. A doorbell is a video doorbell in HomeKit, which rings when its button is pressed. Set when the camera says it is one; can be set by hand (`pond camera set ID --kind doorbell`, or the camera's settings in the app). |
| `cameras[].homekit` | `true` to serve the camera to HomeKit (from the login service). Default `false`. |
| `cameras[].homekitVideo` | The picture the Home app gets. `camera` (the default): the camera's sub-stream (or main, for a viewer with the bandwidth) as the camera makes it, no work for the Mac; sharpen it in the camera's own app. `reencoded`: Pond re-encodes the main stream on the Mac's video hardware to the size, bitrate and frame rate each viewer asks for (sharper, fits slow connections; some work per viewer, about 0.1 s later). |
| `cameras[].instantLive` | `true` to keep the sub-stream open in the service, so live views (the Home app's and Pond's) and snapshots start at once from its latest keyframe; one more camera connection and about 0.3 Mbit/s. Default: on for a camera in HomeKit. |
| `cameras[].homekitMotion` | What sets the camera's motion sensor in the Home app (which HomeKit Secure Video records on, and notifies about): `"detection"` (the default, while the camera is watched: Pond's events, a person, vehicle, bike or animal in its zones) or `"camera"` (the camera's own motion). With detection, a video-only camera records to HomeKit Secure Video too. |
| `cameras[].recordsSub` | `true` to record the camera's sub-stream instead of its main stream: less sharp, a fraction of the room. Live view, HomeKit and detection use the streams as before. In the app: camera settings › Recording. Default `false`. |
| `cameras[].detection` | `false` to stop watching the camera for people, vehicles, animals and packages (no events are made for it). Default `true` ([detection.md](detection.md)). |
| `cameras[].homekitRecording` | `true` to allow HomeKit Secure Video for the camera (in the app: Allow recording in the Home app). The Home app then decides whether it records, in the camera's Recording Options. Needs a home hub and iCloud+. Default `false`. |
| `cameras[].homekitViewers` | How many can watch the camera live in the Home app at once, 1–4 (each iPhone, iPad, Mac or Apple TV takes one; one more is told it is busy). All share one camera connection; Pond's own windows don't count. Default 2. |
| `cameras[].device` | Optional, written by pond: what the camera says it is (`manufacturer`, `model`, `serial`, `firmware`, `isDoorbell`, and `provider`, how Pond talks to it: `reolink`, `onvif`, or `video` for its video only, with no logins for its details or events, so its motion and button aren't watched and its HomeKit Secure Video pauses). HomeKit shows the same. `pond camera identify ID` asks again. |
| `cameras[].zones` | Optional. Polygons in fractions of the frame: `[0, 0]` is top left, `[1, 1]` bottom right; at least 3 points. Zone ids are unique per camera. `kind`: `"watch"` (the default) or `"ignore"`; `categories`: what a watched zone takes, of `"person"`, `"vehicle"`, `"animal"`, `"package"`, `"item"` (left out: all). Drawn in the app: camera settings › Detection › Edit Zones ([detection.md](detection.md#zones)). |

**HomeKit status.** While it runs, the login service writes `homekit-status.json` next to the settings: each camera's HomeKit state (running, added to a home, viewers, the latest problem as a kind such as `loginRefused`), which the app shows. It holds no keys; a camera's setup code is in it only until the camera is added to a home. The file is readable only by you.

**Passwords** are in the login Keychain, never in the settings file: a generic password with service `pond` and the camera's ID as the account (Keychain Access shows them as "pond camera *id*").
