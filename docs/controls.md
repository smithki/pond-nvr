# Camera controls

What Pond can do to a camera besides watching it: move it (pan, tilt, zoom), keep and go to positions, switch day and night, change its picture, set its speaker's volume, talk through it, and work its relays. This page is how that's built, for adding a make or a control; what each make offers is on its page in [cameras](cameras/README.md).

## Providers

A **provider** is one way of talking to cameras: `ReolinkProvider` (Reolink's HTTP API) and `ONVIFProvider` (any camera with ONVIF). Each implements `CameraProvider` (`Devices/CameraProvider.swift`), and offers what it can for a given camera:

| Control | Protocol | Shape |
|---|---|---|
| PTZ | `PTZControl` | move at a velocity, stop, presets (list, go to, keep, remove); says whether it pans and tilts, zooms, and how many presets it keeps |
| Talking back | `TalkControl` | opens a connection to the speaker that takes 16-bit samples |
| Everything else | `ItemControl` | a declared **item**, below |

Each answer is an `Offer`: **yes** (here it is), **no** (this camera hasn't it, or not this way), or **unknown** (the camera couldn't be asked just now: no answer, or every login it allows in use). The difference between no and unknown matters: a no passes the provider over for good, an unknown only until it's asked again a minute later, so a moment's trouble doesn't leave a camera on a lesser protocol.

## Items

Most controls are items (`Config.Controls.Item`), declared rather than drawn, so the app shows any make's controls without knowing them:

- **id**: the same for a control whatever serves it (`dayNight`, `brightness`, `speakerVolume`, `home.go`, `tour.TOKEN`, `relay.TOKEN`), so it's always in the same place.
- **group**: Move, Picture, Sound or Device; and an **order** within it.
- **kind**: a toggle, a choice of a few (with a symbol each), a slider (a range and step), or an action (with words to confirm it first, for a siren or a door).
- **provider**: which one serves it, for the CLI and the log.

The dock shows the everyday items in fixed places for every camera (day and night, speaker volume, home, tours); every other item goes in the Adjustments sidebar, by group. A new item from a provider appears there without changes to the app.

## Which provider serves what

`CameraControls` (`Devices/Controls.swift`) holds one camera's controls in the service. Its providers, in order (`CameraProviders.order(for:)`):

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

A provider that can switch a camera's own privacy mode offers a `PrivacyControl`; the service then has the camera follow Pond's privacy as well (none does yet: Reolink's privacy mode is in its own Baichuan protocol). In the app: **Privacy** in the dock, **Make Private** in a camera's menu in the list, and **Private** in its settings; `pond camera privacy ID [on|off]` from a terminal.

## Connections

`CameraSessions` keeps one connection per camera and protocol in the service, shared by every control: one ONVIF client (its services and profile, asked once) and one Reolink login. Cameras allow only a few logins at once (a Reolink answers "max session" when they're used up, shown as busy), so logins are shared, made one at a time, and logged out when the service stops; CLI commands log out when done.

The app never talks to a camera itself: it asks the service over the control socket (`controls.sock` beside the settings; `ControlServer`, `ControlClient`), one JSON line per request (`ptz.move`, `ptz.presets`, `items.values`, `item.set`, `talk`, …), so passwords stay with the service and the logins stay shared. Talking back sends the microphone's sound over the same socket after a `talk` request.

## Adding a make

A provider for another make, or another protocol for one (Reolink's own Baichuan, say), is a file in `Devices/Providers/` and an entry in `CameraProviders.all`:

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
