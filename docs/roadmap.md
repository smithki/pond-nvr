# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done; the build phases are in [architecture.md](architecture.md#phases).

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

## Recording and the app

| Goal | Status | Notes |
|---|---|---|
| A signed, notarized release | later | Today Pond is built from source; a release needs a Developer ID, notarization and an app bundle identifier of its own. It also settles how search's picture model reaches users (about 390 MB: in the app, or downloaded on first use). |


## ONVIF

Many cameras speak ONVIF (SOAP over HTTP, with WS-Security username-token login). It brings a standard way to do what Pond now does per brand, and more:

| Goal | Status | Notes |
|---|---|---|
| More of a make's own controls | later | Reolink's IR lights, status light, mirror and flip are done (and restarting any ONVIF camera); its siren, chime volume and spotlight are next. |

Not every camera speaks ONVIF, and some do two-way audio only through their own protocol; the camera check says what a camera supports, so the app shows only the controls that work.

## Camera health

A doctor for each camera: what's going wrong, since when, and what to try. First from what Pond sees itself, the same for every make; then from what cameras report about themselves.

| Goal | Status | Notes |
|---|---|---|
| What cameras say about themselves | later | Through the providers, gently (every few minutes, more often while a problem is open): ONVIF's device information, clock and monitoring events (last reboot, processor use); Reolink's CPU, Wi-Fi signal, connected users and SD card. They feed the same rules ("CPU at 96% while video stalls: the camera is overloaded"). |

## Away from home

Pond stays open source; what's paid for is convenience, as with Home Assistant Cloud.

| Goal | Status | Notes |
|---|---|---|
| The iPhone app | later | A separate program (an App Store–friendly licence for the protocol it shares, which the CLA allows), on the same protocol: live, events, clips, search. |
| A hosted service | later | Signaling, an opt-in relay and push alerts with a snapshot (APNs needs a sender of Pond's) run for those who'd rather not, for a small fee (a few dollars a month); open source too, to deploy oneself. Video stays end-to-end encrypted through the relay. |
| Models | later | Detection models beyond the built-in one (packages, or fitted to a home's own scenes), perhaps from others, from an official Pond model marketplace. Any model's terms are its maker's and travel with its file; the built-in one is Ultralytics YOLO26 (AGPL-3.0, as Pond is). Should Pond need other terms one day (a commercial or App Store version), the ways out: Ultralytics' enterprise licence, another built-in model, or YOLO26 as an optional download from the marketplace. |
| Shared work between Ponds | later | A paired Pond with power to spare (a Mac Studio, a MacBook Pro at home) takes on another's work that can wait: describing events (the language model), embedding their pictures for search, and running a new detection model back over weeks of recordings. The inputs are small (a picture, a short clip) and so are the answers (a sentence, an embedding), sent over the same sealed connection as remote access, and on the Macs of whoever owns them, so nothing leaves their own devices. A Pond hands work over when its backlog grows or it can't do the work itself (no Apple Intelligence), and does it itself whenever the other is asleep or away. Live work stays where the cameras are: recording to HomeKit, live views and detection on live video aren't sent anywhere (the video would cross the network twice, against HomeKit's deadlines, and across homes, upload speeds can't carry it). A home with more cameras than one Mac can watch splits its cameras between Ponds instead (see sites). Comes after remote access. |
| Camera groups | later | Groups of cameras within a Pond (Front of house, Garage), named and ordered, for the grid, the lanes and the filters (distinct from zones). |
| One-way sites | later | A Pond seen from another without seeing back (a cabin seen from home, not home from the cabin): pairing that grants one direction only. Other Ponds as sites in Live, Events and the Timeline are done (remote access, in [done.md](done.md)). |
| Sponsorship | later | Donations and sponsors (GitHub Sponsors, Open Collective). |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done (the changelog has them then).

| Fix | Notes |
| --- | --- |
| (none open) | |

