# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done.

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

## Release

What it takes for anyone to use Pond without building it, find out what it does, and support it.

| Goal | Status | Notes |
|---|---|---|
| A signed, notarized release | next | A Developer ID, notarization and an app bundle identifier of Pond's own, so the app installs like any Mac app. It settles how search's picture model reaches users (about 390 MB: in the app, or downloaded on first use), and comes with updates (Sparkle, from Pond's own feed, signed), release notes from the changelog, and a release built and notarized by CI from a tag, not on a developer's Mac. |
| The website | later | At pond.camera: a landing page with Pond's story (an NVR that's yours, on your Mac, nothing sent to anyone), what it does, and pictures of it (demo mode makes them, with no one's own cameras in them); a **downloads** page for the notarized release (and older ones, with their notes and checksums); and a **privacy** statement saying what Pond and the site collect (nothing, and no analytics). |
| User documentation | later | Everything from a user's side, on the website: getting started (a Mac, a drive, cameras), each view and setting, cameras by make, HomeKit, remote access, the doctor's findings, troubleshooting, and the questions people ask. Written from `docs/` and the app, kept in the repository and published from it, so it changes with the code. |
| Advanced documentation | later | For people who run their own services or work on Pond: the signaling service, a relay and a mesh (Tailscale, Headscale) set up; how Pond works inside (the architecture, how video moves, remote access's protocol, the security model); building, testing and contributing (the CLA, conventions, demo mode for bug reports). Also published from the repository. |
| Donations | later | One-off and monthly, through GitHub Sponsors (and perhaps Open Collective, whose books are public), linked from the app's About, the website and the README; no features held back for donors. |
| Open books | later | What Pond has cost to make, published and kept up to date: development (from the repository: commits, lines, and time spent, kept in a ledger beside it), AI assistance (from the providers' usage exports), the services it runs on (the signaling server, the domain, the Developer Program), and what donations brought in. A page on the website, built from those files, so supporters see where money goes. |
| Ready for others | later | What a public project needs beside the code: `SECURITY.md` (how to report a vulnerability privately, and what's in scope), a code of conduct, issue templates (a bug report names a demo scenario, or attaches the doctor's report), CI on macOS for every pull request (tests and the release build, not only the Linux part), the camera compatibility list open to additions, and the trademark question settled (whether the name and logo, `assets/Logo.af`, are free to use with the code or kept). |
| Signing the CLA | next | The contributor agreement process CLA.md's section 11 names, run by CI on every pull request: each commit's author is checked against the signatures kept in the repository (a GitHub Action, such as CLA Assistant Lite's); one who hasn't signed is asked, in a comment, to read the CLA and reply with the sentence that signs it, and the check stays red (required before merging) until they have. Each signature records the GitHub account, the CLA's version, the date and the pull request, and a new version of the CLA is signed again. A company's contributions go through a corporate agreement, by email. Comes before the repository takes outside pull requests; the CLA reviewed by a lawyer first, as its own note asks. |
| First run without a guide | later | Someone who downloads Pond finds their way alone: a first window that says what's needed and does it (a drive, Local Network access, the first camera found on the network and added, the recorder started), with demo mode offered for those with no camera yet. |
| Moving to a new Mac | later | Settings, passwords, HomeKit identities (so cameras stay in the Home app), remote access's keys and pairings, and the index, carried over: an export and an import, or a guide. Recordings stay on their drive. |

## ONVIF

Many cameras speak ONVIF (SOAP over HTTP, with WS-Security username-token login). It's a standard way to do what Pond also does per brand (Reolink's own API), and more:

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

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done.

| Fix | Notes |
| --- | --- |
| (none open) | |

