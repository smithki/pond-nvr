# Camera controls

What Pond can do to a camera besides watching it: move it (pan, tilt, zoom), keep and go to positions, switch day and night, change its picture, set its speaker's volume, talk through it, and work its relays. This page is how that's built, for adding a make or a control; what each make offers is on its page in [cameras](cameras/README.md).

## Providers

A **provider** is one way of talking to cameras: `ReolinkProvider` (Reolink's HTTP API) and `ONVIFProvider` (any camera with ONVIF). Each implements `CameraProvider` (`recorder/Sources/Devices/CameraProvider.swift`), and offers what it can for a given camera:

| Control | Protocol | Shape |
|---|---|---|
| PTZ | `PTZControl` | move at a velocity, stop, presets (list, go to, keep, remove); says whether it pans and tilts, zooms, and how many presets it keeps |
| Talking back | `TalkControl` | opens a connection to the speaker that takes 16-bit samples |
| Everything else | `ItemControl` | a declared **item**, below |

Each answer is an `Offer`: **yes** (here it is), **no** (this camera hasn't it, or not this way), or **unknown** (the camera couldn't be asked just now: no answer, or every login it allows in use). The difference between no and unknown matters: a no passes the provider over for good, an unknown only until it's asked again a minute later, so a moment's trouble doesn't leave a camera on a lesser protocol.

## Items

Most controls are items (`Config.Controls.Item`), declared rather than drawn, so the app shows any make's controls without knowing them:

- **id**: the same for a control whatever serves it (`dayNight`, `brightness`, `speakerVolume`, `home.go`, `tour.TOKEN`, `relay.TOKEN`), so it's always in the same place.
- **group**: Move, Picture, Light, Sound or Device; and an **order** within it.
- **kind**: a toggle, a choice of a few (with a symbol each), a slider (a range and step), or an action (with words to confirm it first, for a siren or a door).
- **provider**: which one serves it, for the CLI and the log.

The dock shows the everyday items in fixed places for every camera (day and night, speaker volume, home, tours); every other item is an adjustment, by group: in a sidebar beside the stage in a wide window, or in a narrow one as the dock's second frame, a page per group. A new item from a provider appears there without changes to the app. The dock is for what's changed while watching; setting a camera up (its streams, schedules, zones) belongs in its settings.

## Which provider serves what

`CameraControls` (`recorder/Sources/Devices/Controls.swift`) holds one camera's controls in the service. Its providers, in order (`CameraProviders.order(for:)`):

1. the one the camera was chosen to be talked to through (its settings' **Talks through**);
2. the others that fit it: its make's own, if Pond has one;
3. ONVIF.

A camera set to **Video only** has none. Each control is resolved on its own:

- **PTZ and talking back**: the first provider that offers it.
- **Items**: each item from the first provider that declares it, so one camera can mix them: a Reolink E1 Pro's day and night and volume come from Reolink's API, its brightness and contrast from ONVIF.
- **Used and refused**: a control whose provider says it can't when used (`ControlFailure.notSupported`) is passed over for the next that offers it, there and then; the request is retried with it.

What a camera has is worked out when it's identified (or with `pond camera controls ID --save`) and kept in its settings (`device.controls`), so the app shows only what works without asking the camera first.

## Privacy

A camera made **private** isn't recorded, shown live or served to HomeKit until it's made public again: Pond's own privacy, so it works for every camera. The service keeps which cameras are private in `privacy.json` beside the settings and applies a change at once, without a restart:

- the recorder closes the camera's segment and lets go of its connection;
- live views in the app end, and new ones aren't served (`StreamRelayServer` asks again while a stream is read);
- the sub-stream held ready for instant live view, and HomeKit Secure Video's prebuffer, let go too;
- in HomeKit there are no live views, snapshots, motion or recordings, and the Home app shows the camera as off. A doorbell still rings: someone is at the door.

The link with HomeKit is one way. The Home app's own camera on and off stays HomeKit's: the hub writes it again whenever it reconnects, and with home and away modes, so it never changes Pond's privacy. Pond keeps the Home app's setting, and when privacy ends the camera goes back to it.

A provider that can switch a camera's own privacy mode offers a `PrivacyControl`, and the camera then follows Pond's privacy, both ways. Reolink's does, over its own protocol (Baichuan): made private in Pond, the camera's privacy mode turns on; turned on or off in the Reolink app, Pond follows (`CameraPrivacySync`), so for these cameras the two are one state. A change made in Pond is *untold* (kept in `privacy.json`) until the camera is seen in that state. Connecting again (after a restart, the camera's or the network's), a camera that disagrees with Pond is put right only if Pond's change never reached it; otherwise it was changed on the camera while Pond wasn't connected, and Pond follows. A camera without one that goes into its own privacy mode is seen by the recorder (it answers but sends nothing) and shown as private on the camera, which Pond can't turn off. In the app: **Privacy** in the dock, **Make Private** in a camera's menu in the list, and **Private** in its settings; `pond camera privacy ID [on|off]` from a terminal.

**Waking.** A camera whose own privacy mode was on takes a while to start its video again once it's off: its `PrivacyControl` says how long at most (`wakeTime`; Reolink's 45 s, about 10 s in practice). Until its video flows, it's *waking* (kept in `privacy.json`): the recorder tries it every 2 s without counting its failures as problems, the tile says **Waking up**, and live view retries every second. The first video ends it (`PrivacyState.awake`). A camera still without video when its time is up is recorded as such (`wakeFailed`), and the doctor says so until its video comes back: *Its video didn't come back after privacy mode*, with a restart as the fix.

**Controls while private.** What's done to the camera now (moving it, its positions, talking through it, actions like Home or a restart, a picture) is off while it's private or waking, with a tooltip saying why: what it shows can't be seen, and a camera in its own privacy mode can't be reached. Its settings (day and night, lights, volume, the picture's) can still be changed: a camera that's only private in Pond is set at once; one that's dark (its own privacy mode on) or waking can't be told, so the service keeps the latest value of each (`pending` in `privacy.json`, across restarts), marks it in the dock with a clock, and sets them once its video is back. They're set gently: 3 s after the video returns, one at a time, 0.6 s apart, on the connections the service already keeps; a setting the camera can't take yet (no answer, too many logins) waits and is tried again 30 s later, up to three times, and one it refuses is let go and logged. What waited wins over anything changed on the camera meanwhile, and anything set anew in Pond meanwhile wins over what waited. A setting already as the camera has it isn't queued (and one set back no longer waits): the service keeps each camera's settings as last read or set in `camera-values.json`, beside its socket, so it knows them after a restart and the dock shows them while the camera can't be asked.

## Connections

`CameraSessions` keeps one connection per camera and protocol in the service, shared by every control: one ONVIF client (its services and profile, asked once) and one Reolink login. Cameras allow only a few logins at once (a Reolink answers "max session" when they're used up, shown as busy), so logins are shared, made one at a time, and logged out when the service stops; CLI commands log out when done.

The app never talks to a camera itself: it asks the service over the control socket (`controls.sock` beside the settings; `ControlServer`, `ControlClient`), one JSON line per request (`ptz.move`, `ptz.presets`, `items.values`, `item.set`, `talk`, …), so passwords stay with the service and the logins stay shared. Talking back sends the microphone's sound over the same socket after a `talk` request.

The Home app talks back too. A camera that can be talked through has a Speaker in HomeKit, and the Home app's talk button then sends its microphone during a live view: AAC-ELD over the stream's audio port, with the same SRTP keys as the sound sent to it (`Talkback`). The service decodes it, resamples it to the rate the camera's speaker takes and sends it through the same `TalkControl` as the app's button. The camera's speaker opens with the first sound (what arrives meanwhile is held, so the first words aren't lost) and closes after 2 s without any, so a live view alone doesn't hold it. The Home app's Speaker mute and volume apply; a private camera isn't talked through.

## Adding a make

A provider for another make, or another protocol for one (Reolink's own Baichuan, say), is a file in `recorder/Sources/Devices/Providers/` and an entry in `CameraProviders.all`:

1. `maker`: the make it's for, matched against what the camera says it is, so it's offered for that make's cameras.
2. `identify`, and stream addresses if it knows them.
3. Whatever controls it can do: `ptz`, `talk`, `items`. Return **no** for what the camera hasn't and **unknown** when it couldn't be asked; reuse ids for the standard controls (`dayNight`, `speakerVolume`), new ids for its own.
4. Its connection in `CameraSessions` if it logs in, shared and logged out on `forgetAll`.

Everything it doesn't do is still served by ONVIF. `pond camera controls ID --via PROVIDER` shows what one provider offers alone.

## Trying controls by hand

```sh
pond camera controls ID [--save]          # which way each control goes, as the service would choose
pond camera ptz ID presets                # or: goto PRESET | move PAN TILT [ZOOM] [--for SECONDS] | stop
pond camera item ID                       # every item and its value; ID ITEM VALUE sets one, ID ITEM do does one
pond camera night-mode ID [auto|day|night]
pond camera talk ID --tone 2              # a quiet tone through the camera's speaker
pond camera abilities ID                  # everything the camera says it can do, every way Pond asks
```

They go through the service when it's running (sharing its logins), else straight to the camera. `--via reolink|onvif` uses only that provider.
