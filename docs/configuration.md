# Configuration

Settings are changed in the app or with the `pond` command; both go through the same code. They are kept in one JSON file, `~/Library/Application Support/Pond/config.json`, which can also be read or edited by hand. `POND_CONFIG` or `--config FILE` names another file. Check it with:

```sh
pond check
```

(`pond init` creates the file) which reports every problem in the settings, whether the storage folders are ready (and how much space is free), and whether each camera has a password in the Keychain.

`pond` and the app save only settings without problems, writes the file atomically and keeps it readable only by you. A file written by a newer pond is refused rather than half understood (`version`).

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
        { "id": "steps", "name": "Steps", "points": [[0.30, 0.55], [0.70, 0.55], [0.75, 1.0], [0.25, 1.0]] }
      ]
    }
  ]
}
```

Only `storage` is required; everything else has the defaults shown.

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

A minute being written ends in `.mp4.partial` and gets its final name when complete; retention never touches it. After a crash the `.partial` file is still playable up to its last 2 s, and `pond run` renames it at the next start. Each file is a complete MP4 that starts on a keyframe, so any one plays on its own (QuickTime, VLC, ffmpeg). Event clips will go in `<events>/events/<camera>/<YYYY-MM-DD>/`.

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
| `cameras[].homekitRecording` | `true` to allow HomeKit Secure Video for the camera (in the app: Allow recording in the Home app). The Home app then decides whether it records, in the camera's Recording Options. Needs a home hub and iCloud+. Default `false`. |
| `cameras[].homekitViewers` | How many can watch the camera live in the Home app at once, 1–4 (each iPhone, iPad, Mac or Apple TV takes one; one more is told it is busy). All share one camera connection; Pond's own windows don't count. Default 2. |
| `cameras[].device` | Optional, written by pond: what the camera says it is (`manufacturer`, `model`, `serial`, `firmware`, `isDoorbell`, and `provider`, the brand support that recognised it: `reolink` or `onvif`). HomeKit shows the same. `pond camera identify ID` asks again. |
| `cameras[].zones` | Optional. Polygons in fractions of the frame: `[0, 0]` is top left, `[1, 1]` bottom right; at least 3 points. Zone ids are unique per camera. Edited by hand for now; the app will draw them. |

**HomeKit status.** While it runs, the login service writes `homekit-status.json` next to the settings: each camera's HomeKit state (running, added to a home, viewers, the latest problem as a kind such as `loginRefused`), which the app shows. It holds no keys; a camera's setup code is in it only until the camera is added to a home. The file is readable only by you.

**Passwords** are in the login Keychain, never in the settings file: a generic password with service `pond` and the camera's ID as the account (Keychain Access shows them as "pond camera *id*").
