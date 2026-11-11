# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done.

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

What comes first: that people can trust what Pond tells them, and that it's plainly working when it is (and says
so when it isn't), before more for it to do. An event that wasn't anything, or a night not recorded without a
word, costs more than any feature earns; each new surface is one more thing that can quietly break.

## Release

Pond is released (signed, notarized and updating itself: [done.md](done.md#release)); what comes before inviting
people to it, in this order (decided 2026-11-09): knowing when it isn't working (Staying up, in progress); first run
without a guide, watched with someone who isn't technical; a beta beyond one home, with the website and its
downloads page; Ready for others before outside pull requests are many. Events worth trusting goes on alongside,
learning from the beta's homes.

What it takes for anyone to use Pond without building it, find out what it does, and support it.

| Goal | Status | Notes |
|---|---|---|
| The website | in progress | At pond.camera: a landing page with Pond's story (an NVR that's yours, on your Mac, nothing sent to anyone), what it does, and pictures of it (demo mode makes them, with no one's own cameras in them); a **downloads** page for the notarized release (and older ones, with their notes and checksums); and a **privacy** statement saying what Pond and the site collect (nothing, and no analytics). Done: a first draft of the landing page (its story, the three views, search, HomeKit, camera health, what stays home, a drive-size calculator, the spec sheet), with screenshots from demo mode only; the site under `web/`, built and served by Vercel at pond.camera, with what Pond downloads by (search's model manifest, `/api/search-model`, and the appcast). Next: its design reworked (the draft isn't liked yet), a real picture of Live, then the downloads and privacy pages (what Pond asks pond.camera for: the appcast daily, the model manifest weekly, nothing about the asker). |
| User documentation | later | Everything from a user's side, on the website: getting started (a Mac, a drive, cameras), each view and setting, cameras by make, HomeKit, remote access, the doctor's findings, troubleshooting, and the questions people ask. Written from `docs/` and the app, kept in the repository and published from it, so it changes with the code. |
| Advanced documentation | later | For people who run their own services or work on Pond: the signaling service, a relay and a mesh (Tailscale, Headscale) set up; how Pond works inside (the architecture, how video moves, remote access's protocol, the security model); building, testing and contributing (signing off, conventions, demo mode for bug reports). Also published from the repository. |
| Donations | later | One-off and monthly, through GitHub Sponsors (and perhaps Open Collective, whose books are public), linked from the app's About, the website and the README; no features held back for donors. |
| Open books | later | What Pond has cost to make, published and kept up to date: development (from the repository: commits, lines, and time spent, kept in a ledger beside it), AI assistance (from the providers' usage exports), the services it runs on (the signaling server, the domain, the Developer Program), and what donations brought in. A page on the website, built from those files, so supporters see where money goes. |
| Ready for others | next | What a public project needs beside the code (the repository is public since 2026-11-10). Done: `SECURITY.md` (reported privately, through GitHub's private vulnerability reporting), `main` protected (changes through pull requests, code owners' review), secret scanning and Dependabot, and contributions under each part's own licence with a DCO sign-off instead of a CLA (CONTRIBUTING.md, checked on every pull request). Next: a code of conduct, issue templates (a bug report names a demo scenario, or attaches the doctor's report), CI on macOS for every pull request (tests and the release build, not only the Linux part), the camera compatibility list open to additions, and a trademark policy (the name, logo and icon are kept, outside the code's licences: NOTICE; the logo is `brand/Logo.af`), with a clearance search for the name. |
| A beta beyond one home | next | Before inviting people to Pond, a small beta of people with other homes: other makes of camera (ONVIF ones of several brands, H.265 ones, battery and Wi-Fi ones), other Macs (a base Mac mini to a Studio), other HomeKit hubs, remote access over real tailnets and real home routers, and someone who isn't technical. Reports come with the doctor's report or a demo scenario; what's learnt goes into the camera compatibility list and the fixes before the release. |
| First run without a guide | next | Someone who downloads Pond finds their way alone. Planned ([first-run.md](first-run.md), 2026-11-11): a wizard in the main window holding their hand to the minimum (a name, a drive, the first camera found and added, the recorder started), each of macOS's questions explained before it's asked, the rest (the Home app, notifications, search's 350 MB model, Pond's sensor) offered after, each skippable; the demo an escape hatch for looking around, not the way in. Judged by watching: a fresh install timed with someone who isn't technical, each place they stall a fix. |
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
| The iPhone app | later | A separate program (the protocol it shares is MIT, `protocol/`, so the app's licence is its own), on the same protocol: live, events, clips, search. |
| A hosted service | later | An opt-in relay and push alerts with a snapshot (APNs needs a sender of Pond's), run for those who'd rather not run them, for a small fee (a few dollars a month); open source too, to deploy oneself. Video stays end-to-end encrypted through the relay. (Signaling is hosted already, free: `signal.pond.camera`, in [done.md](done.md).) |
| Models | later | Detection models beyond the built-in one (packages, or fitted to a home's own scenes), perhaps from others, from an official Pond model marketplace. Pond already has a way to ship them: published in pond-models and named in a manifest pond.camera serves, signed with Pond's own key (as search's model is, [search.md](search.md#published-versions)). Any model's terms are its maker's and travel with its file; the built-in one is Ultralytics YOLO26 (AGPL-3.0, as Pond is). Should Pond need other terms one day (a commercial or App Store version), the ways out: Ultralytics' enterprise licence, another built-in model, or YOLO26 as an optional download from the marketplace. |
| Shared work between Ponds | later | A paired Pond with power to spare (a Mac Studio, a MacBook Pro at home) takes on another's work that can wait: describing events (the language model), embedding their pictures for search, and running a new detection model back over weeks of recordings. The inputs are small (a picture, a short clip) and so are the answers (a sentence, an embedding), sent over the same sealed connection as remote access, and on the Macs of whoever owns them, so nothing leaves their own devices. A Pond hands work over when its backlog grows or it can't do the work itself (no Apple Intelligence), and does it itself whenever the other is asleep or away. Live work stays where the cameras are: recording to HomeKit, live views and detection on live video aren't sent anywhere (the video would cross the network twice, against HomeKit's deadlines, and across homes, upload speeds can't carry it). A home with more cameras than one Mac can watch splits its cameras between Ponds instead (see sites). Comes after remote access. |
| Camera groups | later | Groups of cameras within a Pond (Front of house, Garage), named and ordered, for the grid, the lanes and the filters (distinct from zones). |
| One-way sites | later | A Pond seen from another without seeing back (a cabin seen from home, not home from the cabin): pairing that grants one direction only. Other Ponds as sites in Live, Events and the Timeline are done (remote access, in [done.md](done.md)). |

## Finding one's way

How the app is laid out: what's where, and whether it's where one looks for it. The main window's three views
(Live, Timeline, Events) are the core; around them, what's about the home day to day should be in the main window,
and Settings kept for what one sets once.

| Goal | Status | Notes |
|---|---|---|
| Other Ponds' new events | later | Other Ponds' new events counted while Events isn't open, and seen per viewer once there are phones. |
| Notifications that fit the home | later | What tells one, and when, set where it belongs: per camera, per zone and per kind (people at the front door after 10 pm, not cars on the driveway), with quiet hours and the household's away and home (from HomeKit). One set of rules for this Mac's notifications, the Home app's and, later, the phone's. |

## Staying up

Pond is a server that looks like an app: it's only as good as the nights it doesn't miss.

| Goal | Status | Notes |
|---|---|---|
| Knowing when it isn't working | in progress | What stops recording said plainly, as it happens and wherever one is: the Mac asleep or restarted for an update, the recordings drive full, missing or slow, the service stopped, a camera gone for long; and after the fact ("not recorded 03:12–06:40: the drive was full"), on the timeline and in the doctor. On this Mac, notifications (done); away, on one's phone: through the Home app (Pond's own HomeKit sensor going off, which the Home app can notify about, with no server of Pond's), and later push alerts through the hosted service. A quiet daily "all well" check one can glance at, rather than silence that could mean either. Done: gaps in recordings with why ([doctor.md](doctor.md#gaps-in-recordings)): the service records this Mac sleeping, waking and starting up, its own stops, and the drive failing; the timeline marks each gap, the doctor lists the day's. Pond's own HomeKit sensor (Settings › HomeKit: a contact sensor, open while recording isn't going as it should, the Mac going to sleep included; its Activity Notifications reach one's phone). This Mac's settings in the doctor ([doctor.md](doctor.md#this-mac): sleep, a power cut, the login screen, a battery). The daily summary (Settings › General: every day, only when something wasn't recorded, or off; at an hour of one's choosing): "All well", or what wasn't recorded and why, a gap every camera shared said once; the latest in the doctor and the menu bar. Next: all of it tried on a real home (the sensor opening as the Mac sleeps and the notification reaching a phone away; a day's summary with a real gap), then moved to done.md. |

## Detection, events, search

| Goal | Status | Notes |
|---|---|---|
| Events worth trusting | in progress | Fewer events that weren't anything, and none missed. A set of recorded scenes Pond is measured against with every change to detection: a parked car through a night (noise, infrared, passing headlights), rain and snow, swaying trees, insects at an infrared lamp, birds, a person standing still, a delivery; what each should and shouldn't make. Labels that don't fit a home camera (the model's "train" or "boat" for a car in the street) read as what they likely are, or not counted. Each camera's sensitivity in plain words, with what it would have caught yesterday at each setting. Done: "this wasn't anything" on an event, and events like those dismissed quieted (still made, marked "probably nothing" and left out of Events by default): by a rule learnt from several in one spot of one kind in one part of the day, or by their pictures' likeness (search's embeddings) near the spot; "it was something" outweighs either; what's learnt shown and forgotten in the camera's settings. Next: the recorded scenes it's all measured against, quieting at the source (HomeKit's notifications spared) once it's judged well, and fitted models from what's been said (Models). |
| Test scenes | in progress | Each Pond's own, on its Mac, from what its owner already does: events said not to be anything ("nothing"), said to be something or seen and kept ("real"), their clips kept beside its database; `pond advanced scenes` replays them through a build (the recorder's own pipeline) and says how many dismissed it keeps out of sight and how many real it shows, each judged by what was learnt from all the rest. Done: the pipeline shared with the recorder, the library and its limits, the check and its scores-only report. Next: testers' homes sending those scores for a change (no footage), and checking with them the parked-car rule (chosen from one home's camera); per camera, quieting tuned from its owner's own scenes; public footage (licensed for it, downloaded, never kept here) for what no home's scenes can show, the detector's blind spots. |
| Package detection | later | The built-in model (COCO) has no package class. Fine-tune YOLO26 with a `package` class: an open parcel dataset (Roboflow's parcel-detect, CC BY 4.0) plus doorbell footage of real deliveries, trained on a Mac; shipped built in, or as the first model of the Pond model marketplace. Pond already reads a model's `package` label into its Packages category, so no other change is needed. |

## Small fixes

A backlog: small, contained problems seen in use, each worth a fix but not a goal of its own. Taken up between larger pieces of work, and removed from here when done.

| Fix | Notes |
| --- | --- |
| (none open) | |

