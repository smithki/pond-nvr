# Pond

A network video recorder for the Mac, written in Swift ([pond.camera](https://pond.camera)). It records IP cameras around the clock to a drive of your choice, plays them back on a timeline, shows them live, and serves each one to Apple's Home app with live view and HomeKit Secure Video. It needs no bridge such as Homebridge or Scrypted. Everything runs on the Mac; nothing is sent to a cloud service of its own.

Work in progress. What works today:

- **Continuous recording** of every camera's main stream (or its sub-stream, to save room), H.264 or H.265 as it sends it, in 1-minute MP4 files, with retention by age, size and free space. It reconnects when a camera drops, and stops writing (and says so) when the drive is unplugged instead of filling the startup disk.
- **Pond NVR.app**: a live view of every camera with sound, a timeline to play back any day, the events seen, and settings for everything; in the menu bar, whether Pond is recording, and a notification when it stops.
- **HomeKit**, implemented natively (the HomeKit Accessory Protocol in Swift): each camera you choose is a camera in the Home app, with snapshots, live video and sound, several viewers at once, and **HomeKit Secure Video** recording on the camera's own motion detection. Doorbells are supported as video doorbells.
- **Camera controls**: under a camera watched on its own, a dock to move it, keep and go to positions, switch day and night, talk through its speaker and change its picture and volume, through its make's own API where Pond knows one (Reolink) and ONVIF otherwise.
- **Events, on the Mac alone**: people, vehicles and animals found in each camera's video (Core ML), with zones; each event described in a sentence and found again by plain-language search ("a courier at the front door this week"), with Apple's on-device models only.
- **Camera health**: a doctor for each camera, saying what's going wrong, since when, and what to try.
- **The `pond` command** does all the setup from a terminal and runs the recorder as a login service.
- **Other Ponds, from away**: a second home's Pond (or a friend's) paired with this one, peer to peer and end to end encrypted, introduced by Pond's signaling service or one of your own; its cameras, events and timeline beside this Mac's, and told when it stops recording ([docs/remote.md](docs/remote.md)).
- **Demo mode**: made-up cameras to explore Pond with, before having any ([docs/demo.md](docs/demo.md)).

Next: an iPhone app on the same protocol, and a signed release. See [docs/roadmap.md](docs/roadmap.md).

## Requirements

- A Mac with Apple silicon and macOS 27, with Xcode to build (Swift 6, Swift Testing).
- Cameras that serve H.264 or H.265 over RTSP. Reolink cameras are supported best: Pond reads their model and doorbell presses through their API, and knows their stream addresses. Others work through ONVIF and their RTSP addresses; see [docs/cameras](docs/cameras/README.md).
- For continuous recording, an external drive or a NAS share: about 32 GB per camera per day at 2560×1440.
- For HomeKit Secure Video, a home hub (Apple TV or HomePod) and an iCloud+ plan.

## Build and run

```sh
make signing                # once per Mac, if you have no Apple Development certificate: see docs/development.md
make app && open "dist/Pond NVR.app"
```

In the app, **Settings › Storage** chooses the recordings folder, **Add Camera** in the toolbar (or in **Settings › Cameras**, ⇧⌘C) adds a camera by its address (it logs in, checks the streams and keeps the password in your Keychain), and **Start** in the toolbar's overview (it says *Not recording* until then) starts the background recorder. Closing the app does not stop recording.

The same from a terminal:

```sh
make install                                      # pond into /usr/local/bin (asks for your password)
pond init                                          # the settings file, with defaults
pond storage recordings /Volumes/Pond/recordings    # a folder on the external drive; prepared for pond
pond retention continuous 14                       # days of continuous recording
pond retention events 60                           # days to keep event clips
pond camera add porch --host 192.168.1.20 --name "Front porch"   # asks for the password, checks the camera, saves
pond check                                         # settings, folders, passwords
pond service install                               # record whenever you are logged in
```

`pond help` lists every command; [docs/configuration.md](docs/configuration.md) explains each setting.

## The app

`Pond NVR.app` has three views, chosen in the toolbar (Back and Forward, ⌘[ and ⌘], move between them):

- **Live**: a rail of every camera beside a stage showing the chosen cameras live, as large as the window allows. Click a camera to add it or take it off, double-click it to watch it alone, drag to reorder. Large tiles play the main stream, small ones the sub-stream; one camera is heard at a time. A camera that is offline, sends no picture or has stopped being recorded is marked, and a tile without a picture says why.
- **Timeline**: the recordings of any day, a lane per camera. Click or drag to move, space to play or pause, ← and → for 10 seconds, ½× to 16×, zoom from a whole day to 15 minutes; scroll back across midnight into earlier days. **LIVE** (L) shows the selected camera as it is now.
- **Events**: what the cameras saw, a card each, by day, beside a rail of every day kept; details in a panel. **Search** in plain words ("a man in a red jacket last night"), on the Mac only ([docs/search.md](docs/search.md)).

The toolbar's state says whether all's well (or what needs attention, with an overview of it and the fixes), and **Settings** (⌘,) is where everything is set up and looked into: a sidebar of this Pond's settings (General, Storage, Remote Access, HomeKit, Cameras, Advanced; HomeKit shows every camera in the Home app at once, how each is doing there and what it sends, with what to do), and from Cameras (⇧⌘C, or the toolbar's Cameras button) the recorder (whether it runs, its log) and each camera, with its Doctor (findings, day and record) and its Settings as tabs. Drag cameras in its list to put them in order. A camera's everyday settings are also a right-click away wherever it's shown: **Camera Settings…** on its tile or an event opens them in a panel over the main window, with **All Settings…** for the rest.

Settings (⌘,) has **General**, **Storage** (where recordings go, how long they're kept, and the room they take), **Remote Access**, **HomeKit**, **Cameras** and **Advanced**. They edit the same settings file as `pond`, and the app carries `pond` inside it, so the recorder can be started from the app alone.

## HomeKit

Add a camera to the Home app from its settings (**Add to the Home App…**) or as the last step of Add Camera; the app shows the setup code and QR code. In the Home app: **+ › Add Accessory**, scan the code, and **Add Anyway** at the uncertified-accessory warning. From a terminal:

```sh
pond camera set ID --homekit on     # serve the camera to HomeKit (--kind doorbell for a doorbell)
pond homekit code                   # setup codes and QR codes for the Home app
```

The background recorder serves the cameras, sharing one connection per camera stream with recording and the app (many cameras serve only a few connections at once). Per camera you can choose:

- **The picture in the Home app**: the camera's own streams as they are (no work for the Mac), or re-encoded by Pond on the Mac's video hardware to the size and bitrate each viewer asks for, adapting to its connection.
- **How many can watch at once** (1–4), and **instant live view** (keeps a stream open so live views and snapshots start at once).
- **Allow recording**: HomeKit Secure Video. The home hub decides what to keep and stores it in iCloud; turn recording on in the Home app, in the camera's Recording Options. Pond records from a few seconds before the motion, re-encoded to what the hub asks for. The HomeKit badge on the camera's tile, its settings and Settings › HomeKit say whether it is recording and why not. Recording Options can differ when you're home and away, and the hub tells Pond only what's so now: a camera set up to record but off for the moment shows as *Not recording right now* (with when it last was), not as off in the Home app, and the recorder's log notes each time the hub turns recording or the camera on or off.

**Pond's own sensor** (Settings › HomeKit › Pond's status, off until added): an accessory of its own, a contact sensor named *Recording*, closed while Pond records and open when a camera that isn't private hasn't recorded for 5 minutes, the recordings drive can't be written to for a minute, or the Mac is going to sleep. Turn on its Activity Notifications in the Home app to hear about it away from home, with no server of Pond's. It can't say that the Mac is off or the recorder isn't running: the Home app shows it as Not Responding then, and doesn't notify.

Each camera's HomeKit identity and pairings are kept in the login Keychain (`pond-homekit`); `pond homekit reset ID` forgets them (`_status` for Pond's sensor). See [docs/security.md](docs/security.md).

## The login service

`pond service install` (or Start Recording in the app) makes `pond run` a launchd agent: it starts at login, restarts if it stops, and keeps the Mac from idle-sleeping while it records (the display can still sleep). It runs in your login session, where the Keychain with the camera passwords is, so the Mac needs a logged-in user; turn on automatic login for a headless Mac.

```sh
pond service status       # running or not, and the last lines of the log
pond service reload       # after changing settings by hand: only the cameras that changed start again
pond service restart      # after installing a new pond, or changing the storage
pond service uninstall    # stop and remove it; recordings and settings stay
```

The log is `~/Library/Logs/Pond/pond.log`, also in Settings › Cameras › Recorder (⇧⌘C). The first time it runs, macOS asks whether pond may find devices on your local network (Allow) and use the camera passwords in your Keychain (Always Allow).

## Documentation

- [docs/cameras](docs/cameras/README.md): which cameras work, and what to set on them: [Reolink](docs/cameras/reolink.md), [ONVIF and other RTSP cameras](docs/cameras/onvif.md).
- [docs/controls.md](docs/controls.md): camera controls, and how each goes through the best way Pond has for a camera.
- [docs/detection.md](docs/detection.md): detection models: the one built in, adding another, `pond advanced detect`.
- [docs/search.md](docs/search.md): searching events in plain words, the sentences and the picture model behind it.
- [docs/doctor.md](docs/doctor.md): the camera doctor: its findings, where they show, and Run Check.
- [docs/demo.md](docs/demo.md): demo mode: made-up cameras to explore with, its scenarios, and using one in a bug report.
- [docs/release.md](docs/release.md): making a release (signed, notarized, in a disk image)
- [web/](web/README.md): pond.camera: the website, and the manifest and appcast Pond downloads by
- [docs/remote.md](docs/remote.md): other Ponds, from away: pairing, how a connection is made, what each party sees; [deploy/](deploy/README.md): the signaling service (and an optional relay or mesh) to run yourself.
- [docs/configuration.md](docs/configuration.md): the settings file and the commands that change it.
- [docs/architecture.md](docs/architecture.md): the modules and how video travels through them.
- [docs/security.md](docs/security.md): credentials, HomeKit keys, what listens on the network.
- [docs/development.md](docs/development.md): building, testing, conventions.
- [docs/roadmap.md](docs/roadmap.md): what comes next; [docs/done.md](docs/done.md): what's been built, and how.
- [CHANGELOG.md](CHANGELOG.md)

## License

GNU Affero General Public License v3.0: see [LICENSE](LICENSE) and [NOTICE](NOTICE). The exceptions, under the MIT License: Pond's network protocol, [`protocol/`](protocol/) ([its LICENSE](protocol/LICENSE)), so that anything can speak it; and the website, [`web/`](web/) ([its LICENSE](web/LICENSE)). It includes Ultralytics YOLO26 (AGPL-3.0) as its built-in detection model; other models can be used in its place ([docs/detection.md](docs/detection.md)).

Issues and pull requests are welcome: see [CONTRIBUTING.md](CONTRIBUTING.md) (each commit signed off, under the
Developer Certificate of Origin). Security problems: [SECURITY.md](SECURITY.md), privately.
