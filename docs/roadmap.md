# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done.

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

What comes first: that people can trust what Pond tells them, and that it's plainly working when it is (and says
so when it isn't), before more for it to do. An event that wasn't anything, or a night not recorded without a
word, costs more than any feature earns; each new surface is one more thing that can quietly break.

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
| Signing the CLA | next | The contributor agreement process CLA.md's section 14 names, run by CI on every pull request: each commit's author is checked against the signatures kept in the repository (a GitHub Action, such as CLA Assistant Lite's); one who hasn't signed is asked, in a comment, to read the CLA and reply with the statement that signs it (a comment of its own, not a review or approval), and the check stays red (required before merging) until they have. Each signature records the GitHub account, the CLA's version and the SHA-256 of the exact text shown (each version kept unchanged, tagged in the repository), the date and the pull request; a materially revised CLA is signed again for later contributions. A contributor's earlier commits, made before signing, are named in the pull request where they sign, so they're covered too. A company's contributions go through a corporate agreement, by email. Comes before the repository takes outside pull requests; the CLA reviewed by a lawyer first, as its own note asks. |
| A beta beyond one home | next | Before a public release, a small beta of people with other homes: other makes of camera (ONVIF ones of several brands, H.265 ones, battery and Wi-Fi ones), other Macs (a base Mac mini to a Studio), other HomeKit hubs, remote access over real tailnets and real home routers, and someone who isn't technical. Reports come with the doctor's report or a demo scenario; what's learnt goes into the camera compatibility list and the fixes before the release. |
| First run without a guide | later | Someone who downloads Pond finds their way alone: a first window that says what's needed and does it (a drive, Local Network access, the first camera found on the network and added, the recorder started), with demo mode offered for those with no camera yet. Judged by watching: a fresh install timed with someone who isn't technical, each place they stall a fix. |
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

## Finding one's way

How the app is laid out: what's where, and whether it's where one looks for it. The main window's three views
(Live, Timeline, Events) are the core; around them, what's about the home day to day should be in the main window,
and Settings kept for what one sets once.

| Goal | Status | Notes |
|---|---|---|
| Health where one looks | in progress | Noticing in the main window, working out why in the doctor's own window. Done: the toolbar's state says what needs attention, from one list (the recorder, its drive and room, each camera not recorded or with the doctor's problems and warnings, other Ponds gone quiet or out of reach), and opens an overview of it: each thing with its fix, the cameras kept private (each to make public), the cameras that need attention to show alone, and which Ponds to show. The menu bar item and the camera rail's filter use the same list. The doctor is a window of its own (⌥⌘D), out of Settings: the recorder and each camera down its side, to keep open beside the live view or the timeline. Next: a camera's incidents on a strip drawn like the timeline's, and other Ponds' cameras in the doctor. |
| Events as an inbox | in progress | Events new since one last looked, and those one has seen. Done: an event is seen once it's been on screen in Events a moment with the window in front (or opened); new ones carry a dot, the Events view and the menu bar item count them, and the day rail has Mark All Seen. Kept per Mac (a demo's apart); nothing from before it first counted is new. Each event goes to its moment on the Timeline (double-click) and Back returns. Next: other Ponds' new events counted while Events isn't open, and seen per viewer once there are phones. |
| A camera from where one sees it | in progress | A camera's settings and zones reached from where one sees it, not only from Settings › Cameras. Done: a right-click on its tile in Live (on the stage and in the rail) or on one of its events: Camera Settings…, Edit Zones… (the zone editor over the main window), Doctor…; and on an event, Ignore This Area…, the zone editor with the event's box drawn as an ignored zone for the event's kind, to adjust and keep. Next: "this wasn't anything" (Events worth trusting), which teaches the camera without drawing. |
| Notifications that fit the home | later | What tells one, and when, set where it belongs: per camera, per zone and per kind (people at the front door after 10 pm, not cars on the driveway), with quiet hours and the household's away and home (from HomeKit). One set of rules for this Mac's notifications, the Home app's and, later, the phone's. |
| Fewer settings | later | Settings for what's set once: General, Cameras, Storage (with retention: how much room, and how long), Remote Access. The doctor and the recorder (its service, the media engine, its log) have left for the doctor's window; Storage and Retention are still two. |
| HomeKit at a glance | later | One place that shows which cameras are in the Home app, what each sends there (live, Secure Video, motion) and whether the hub is reaching them, rather than a page in each camera's settings. |

## Staying up

Pond is a server that looks like an app: it's only as good as the nights it doesn't miss.

| Goal | Status | Notes |
|---|---|---|
| Knowing when it isn't working | next | What stops recording said plainly, as it happens and wherever one is: the Mac asleep or restarted for an update, the recordings drive full, missing or slow, the service stopped, a camera gone for long; and after the fact ("not recorded 03:12–06:40: the drive was full"), on the timeline and in the doctor. On this Mac, notifications (done); away, on one's phone: through the Home app (Pond's own HomeKit sensor going off, which the Home app can notify about, with no server of Pond's), and later push alerts through the hosted service. A quiet daily "all well" check one can glance at, rather than silence that could mean either. |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Events worth trusting | in progress | Fewer events that weren't anything, and none missed. A set of recorded scenes Pond is measured against with every change to detection: a parked car through a night (noise, infrared, passing headlights), rain and snow, swaying trees, insects at an infrared lamp, birds, a person standing still, a delivery; what each should and shouldn't make. Labels that don't fit a home camera (the model's "train" or "boat" for a car in the street) read as what they likely are, or not counted. Each camera's sensitivity in plain words, with what it would have caught yesterday at each setting. Done: "this wasn't anything" on an event, and events like those dismissed quieted (still made, marked "probably nothing" and left out of Events by default): by a rule learnt from several in one spot of one kind in one part of the day, or by their pictures' likeness (search's embeddings) near the spot; "it was something" outweighs either; what's learnt shown and forgotten in the camera's settings. Next: the recorded scenes it's all measured against, quieting at the source (HomeKit's notifications spared) once it's judged well, and fitted models from what's been said (Models). |
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done.

| Fix | Notes |
| --- | --- |
| (none open) | |

