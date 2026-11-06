# The camera doctor

Settings › **Doctor** says how each camera is doing: what's going wrong, since when, the evidence, and what to try. It works the same for every make, from what Pond already sees of a camera while recording it. The doctor asks nothing more of a camera unless you run a check.

## What it's built from

The service records two things for each camera in Pond's database (`pond.sqlite`, on the internal disk by default; `storage.database` in [configuration.md](configuration.md)):

- **Incidents**: its video starting and stopping, being unreachable, a login refused, its own privacy mode, being made private or public, a control failing, not waking from privacy mode, being restarted by Pond, and the service starting.
- **Five-minute samples** of its video: frames, packets lost, bytes, keyframes, and the camera's clock against the Mac's.

A week is kept, pruned hourly, apart from recording retention. The app reads the database off the main thread and works out the findings itself (`HealthDiagnosis`), so the service only records.

## Findings

Each finding has a severity:

- A **problem** is something wrong with the camera.
- A **warning** is something to change, and always comes with a fix.
- A **notice** is worth knowing but isn't the camera's fault.

A finding lasts while its evidence does, mostly the last hour, so it clears after a calm spell rather than flickering.

| Finding | Severity | When |
|---|---|---|
| Video keeps stopping | problem | Video stops while connected, 3 times in an hour. |
| Drops off the network | problem | Unreachable 3 times in an hour while the other cameras weren't. |
| Restarted by Pond | notice (problem until it's back) | The camera answered, but its video server refused every connection for three minutes while it wasn't private (its video server stuck: it happens after privacy mode, now and then): Pond restarted it, over its make's own protocol where it has one (a Reolink's, which still answers then), else its Restart control (ONVIF). Not again within half an hour; never for a camera that doesn't answer at all (that's its network, which a restart wouldn't reach), nor a private or waking one. |
| Its video didn't come back after privacy mode | problem | Its own privacy mode turned off, and no video within its make's wake time. Lasts until video returns or it's made private again. See [controls.md](controls.md#privacy). |
| Its login is refused | problem | A refused login with no video since. |
| Video is losing packets | warning | Over 1% of its video lost in the last hour. |
| Keyframes are far apart | warning | Over 4 s between keyframes on average: slow to start, in HomeKit too. |
| Its clock is off | warning | Over 30 s from the Mac's. |
| Its controls often fail | warning | Over 20% of at least 5 controls in an hour. |
| This Mac lost the network | notice | Every camera unreachable at once, or right as the service started. Lasts until the camera connects again. |
| Private for a while | notice | Private for over 24 hours. |

Being private is never a problem: a private camera's gap in recordings is explained, not flagged. A camera waking from its own privacy mode isn't flagged either, unless it fails to wake.

The figures above are the defaults. **Thresholds**, under the overview's cameras, changes them for every camera; **Restore Defaults** puts them back. They're kept in the app's preferences.

## Where findings show

- **The toolbar's state** says when anything needs attention, and its overview lists it with the fix (Doctor, for a camera, opens it here).
- **The Doctor window** (⌥⌘D, Window › Doctor, or *Open the Doctor…* in the overview and the menu bar) lists the recorder and every camera with its state, down its side, to keep open beside the live view or the timeline while working something out. A camera's own page shows its findings, its last 24 hours as charts (frame rate, and interruptions each hour), and what happened to it. That list shows problems by default and **Everything** on request, as the recorder's log does.
- **A camera's tile and its row in the camera list** carry a mark (a stethoscope, red for a problem, orange for a warning). Hovering says what's wrong, and clicking opens the doctor at the camera. Notices don't get a mark, and neither do findings you've ignored.
- **Ignore** on a finding keeps it in the doctor, dimmed, but takes it off the camera's tile and row. It's per camera, for findings you know about and can't fix.

## Run Check Now

On a camera's page, **Run Check Now** checks it once, only when asked:

1. It logs in to both streams and watches 6 s of video. This is the same check as Settings › Cameras, done by `pond`, which holds the passwords.
2. It reads the camera's controls through the service, timed.

A private or waking camera isn't checked, because there's nothing to watch and it may not answer.

## HomeKit Secure Video

For a camera that records to HomeKit Secure Video, a camera's page also says when Pond last sent the home hub a clip. Whether the hub keeps it, Pond can't see: the hub analyses each clip (its notifications come from that) and stores it or not.

If clips are sent but never appear in the Home app, while another camera's do, the home hub's recording setup for that camera may be stuck. It happened with a doorbell: the hub took valid clips, notified about them, and kept none. The fix is to give the camera a fresh HomeKit identity:

1. In Pond, Settings › Cameras › the camera › **Remove from HomeKit…** (or `pond homekit reset ID`).
2. In the Home app, remove the accessory too.
3. In Pond, **Add to the Home App…**, and add it with its new setup code. Its Home app settings (room, notifications, Recording Options, automations) are set up again.

To look at exactly what the hub is sent, make a folder named `hksv-dump` beside the settings (`~/Library/Application Support/Pond/hksv-dump`): while it exists, each recording is also written there whole, as a playable MP4 named `<camera>-<time>-<stream>.mp4`. Remove the folder when done; nothing is written without it.

## Copy Report

**Copy Report** puts a camera's state on the clipboard as text for a bug report: its make, model and firmware, its findings, its last day's video figures and incidents. It leaves out the camera's address and password.
