# The camera doctor

In Settings › Cameras, each camera's **Doctor** says how it's doing: what's going wrong, since when, the evidence, and what to try. It works the same for every make, from what Pond already sees of a camera while recording it. The doctor asks nothing more of a camera unless you run a check.

## What it's built from

The service records two things for each camera in Pond's database (`pond.sqlite`, on the internal disk by default; `storage.database` in [configuration.md](configuration.md)):

- **Incidents**: its video starting and stopping, being unreachable, a login refused, its own privacy mode, being made private or public, a control failing, not waking from privacy mode, being restarted by Pond, its recordings drive failing (full, missing, not writable) and coming back; and this Mac's side: the service starting and stopping, the Mac going to sleep and waking, and the Mac starting up (at its boot time).
- **Five-minute samples** of its video: frames, packets lost, bytes, keyframes, and the camera's clock against the Mac's.

A week is kept, pruned hourly, apart from recording retention; what explains a gap in recordings (privacy, this Mac's side, the drive) is kept a year, as recordings may be. The app reads the database off the main thread and works out the findings itself (`HealthDiagnosis`), so the service only records.

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

## This Mac

Pond records only while this Mac is on, awake and logged in, so the doctor also reads its power and login settings (every five minutes, with no administrator rights; nothing is changed: `MacReadiness`). Listed under **This Mac** on the **Every camera** page, each with **Open Settings…** where it's changed; problems and warnings also in the toolbar's overview:

| Finding | Severity | When |
|---|---|---|
| This Mac may go to sleep | problem | It sleeps when idle, and the running recorder isn't holding that off. |
| Running on its UPS | problem | The power's out; it runs on its backup battery. |
| Running on battery | warning | A laptop unplugged: it sleeps when the battery runs low. |
| Stays off after a power cut | warning | "Start up automatically after a power failure" is off. |
| A laptop | notice | Closing its lid puts it to sleep. |
| Records only once you've logged in | notice | Automatic login is off, or FileVault is on (which prevents it): after a restart, Pond waits at the login screen. A security trade-off, said rather than flagged. |
| Low Power Mode is on | notice | Detection and HomeKit's video may fall behind. |

The display going to sleep makes no difference: the Mac keeps running, and so does Pond. Not read in demo mode.

## Gaps in recordings

Where a camera's recordings stop for two minutes or more (not while it's private, which is shown as private), Pond says why, from what was recorded at the time (`RecordingGaps`), the first that fits:

1. This Mac was asleep, or off or restarting (it started up during the gap).
2. Pond's recorder was stopped.
3. The recordings drive was full, wasn't there, or couldn't be written to.
4. What the camera did as the gap began: it didn't answer (or every camera at once: this Mac lost the network), refused its login, its own privacy mode, its video stopped, didn't come back after privacy mode, or Pond was restarting it.
5. Pond's recorder wasn't running (it started again during the gap with no stop recorded: it quit, or the power went).

Otherwise it's "Not recorded", with nothing to say why. On the **Timeline**, a gap is an orange dashed stretch of the lane, why on hover; on a camera's doctor page, the last 24 hours' gaps (or "Recorded without a gap"); and in **Copy Report**.

## Where findings show

- **The toolbar's state** says when anything needs attention, and its overview lists it with the fix (Doctor, for a camera, opens it here).
- **Settings › Cameras** (⇧⌘C: Pond › Cameras…, the main window's Cameras button, *Cameras…* in the overview and *Open Cameras…* in the menu bar; Cameras in Settings' sidebar slides its list over to them) lists the recorder and every camera with its state, down its side (drag cameras to put them in order; Add Camera… under the list), to keep open beside the live view or the timeline while working something out. A camera's own page shows its findings, its last 24 hours as charts (frame rate, and interruptions each hour), and what happened to it. That list shows problems by default and **Everything** on request, as the recorder's log does.
- **A camera's tile and its row in the camera list** carry a mark (a stethoscope, red for a problem, orange for a warning). Hovering says what's wrong, and clicking opens the doctor at the camera. Notices don't get a mark, and neither do findings you've ignored.
- **Ignore** on a finding keeps it in the doctor, dimmed, but takes it off the camera's tile and row. It's per camera, for findings you know about and can't fix.

## Run Check

On a camera's Doctor tab, **Run Check…** checks it once, only when asked, in a sheet: its progress, then what it found in a word, the details, and the fix (**Enter Password…** or **Change Address…** opens its Settings tab with the cursor in that field). It's the one check of a camera in the app (its Settings tab has none; Save checks a new password itself):

1. It logs in to both streams and watches 6 s of video, done by `pond`, which holds the passwords. A camera reached that hasn't said what it is yet is asked.
2. It reads the camera's controls through the service, timed.

The last check stays on the page as one line (how it went, and when), with **Details…** for the sheet again; **Check All Cameras** on the All Cameras page checks each in turn, each one's line on its page.

A private or waking camera isn't checked, because there's nothing to watch and it may not answer.

## HomeKit Secure Video

For a camera that records to HomeKit Secure Video, a camera's page also says when Pond last sent the home hub a clip. Whether the hub keeps it, Pond can't see: the hub analyses each clip (its notifications come from that) and stores it or not.

If clips are sent but never appear in the Home app, while another camera's do, the home hub's recording setup for that camera may be stuck. It happened with a doorbell: the hub took valid clips, notified about them, and kept none. The fix is to give the camera a fresh HomeKit identity:

1. In Pond, **Camera Settings…** on its tile (or its Settings tab in Settings › Cameras) › **Remove from HomeKit…** (or `pond homekit reset ID`).
2. In the Home app, remove the accessory too.
3. In Pond, **Add to the Home App…**, and add it with its new setup code. Its Home app settings (room, notifications, Recording Options, automations) are set up again.

To look at exactly what the hub is sent, make a folder named `hksv-dump` beside the settings (`~/Library/Application Support/Pond/hksv-dump`): while it exists, each recording is also written there whole, as a playable MP4 named `<camera>-<time>-<stream>.mp4`. Remove the folder when done; nothing is written without it.

## Copy Report

**Copy Report** puts a camera's state on the clipboard as text for a bug report: its make, model and firmware, its findings, its last day's video figures and incidents. It leaves out the camera's address and password.
