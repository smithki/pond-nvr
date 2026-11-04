# Demo mode

Pond with made-up cameras: to explore it without any, to try what one home doesn't have (a doorbell, PTZ, many cameras, a second home to reach, things going wrong), and to show a problem without sharing your own cameras. Demo cameras aren't pretend screens. Their pictures are drawn and encoded as a camera's stream (`demo://`), so Pond itself records them, watches them, finds events in them, serves them live and over remote access, as it does real ones.

## Opening one

- **From the app:** Settings › General › *Open the Demo…*, then a scenario. A second copy of Pond opens in it, beside yours. Its toolbar says *Demo: Home* (or whichever), and its menu switches to another scenario.
- **From the source:** `make demo` builds a copy of the app in `dist/demo` and opens it (`make demo SCENARIO=trouble` for another). Building it never restarts your real Pond.
- **From the command line:** `pond demo list` lists the scenarios. `pond demo prepare NAME` makes one's world and prints its settings file, for `pond run --config`. Add `--fresh` to start it over.

A demo never touches your real setup. Each scenario is a world of its own, in `~/Library/Application Support/Pond Demo/NAME/`: its settings, recordings, database, events, log, and its secrets (in a file there, never the Keychain). HomeKit is off for every demo camera, so nothing is advertised on your network. The demo's services (its `pond run`, any other Pond's, and the signaling service between them) are run by the demo's app, in place of the login service. They stop when it quits, or if it's killed.

## The scenarios

| Scenario | What it's for |
|---|---|
| `home` | Six cameras: a doorbell, a driveway, a backyard PTZ, a garage, a living room that starts private, a side gate. A busy day, and a second home (the Lake House, four cameras) paired with it, to reach from the first. |
| `many` | Sixteen cameras, for the layout and the Mac's video work. |
| `trouble` | A camera that keeps dropping, one with keyframes 12 s apart, one whose clock runs ahead, and a drive nearly full (3 GB free). |
| `first-run` | No cameras yet: setting up, and Add Camera finding the six cameras on the demo's network. |
| `remote-slow` | The Lake House over a slow, lossy link (300 kB/s, 120 ms there and back, 2% lost). |
| `remote-unreachable` | The Lake House gone quiet (its Pond isn't running). |

## What's in a demo

- **Pictures:** each scene is drawn for the time of day. Dawn and dusk come with the clock, and after dark the scene is in infrared grey. The timestamp is burned in, as cameras do. People, cars, bikes, animals and couriers come and go on a script, the same for the same scenario and time.
- **Sound:** wind, birds by day, crickets at night, a car's rumble as it passes, and the doorbell's chime. It's AAC-LC, mono, 16 kHz, as a camera's microphone gives it.
- **Controls:** the demo make's own:
  - PTZ that moves and zooms what the scene shows, with positions kept;
  - day and night, brightness and the status light;
  - privacy, both ways;
  - restart, which drops the streams for 20 s;
  - doorbell presses from the script.
- **Detection:** what each scene draws is told to detection, so events are made from what's really in the picture, without a model. Sentences and search work as usual: by the Mac's own model and SigLIP, where there are.
- **History:** on a scenario's first start, its last three hours are made as if Pond had been recording them. They're encoded faster than real time at the sub-stream's size, a quarter of an hour at a time, the latest first. Their events come too, with pictures, clips and sentences, so the timeline and Events have something to show within a minute or two.

## In a bug report

A demo is a way to show a problem anyone can see for themselves. Name the scenario, what you did, and what happened, and attach its log (`pond.log` in its folder). Each scenario is the same for anyone at the same time of day, so the steps are usually enough. To start again from nothing: `pond demo prepare NAME --fresh`.
