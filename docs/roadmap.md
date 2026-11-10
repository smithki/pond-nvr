# Roadmap

What's left to do: goals under way, next, and later. What's finished is in [done.md](done.md), with how each was done.

Status: **in progress**, **next**, **later**. A goal moves to done.md when it's finished.

What comes first: that people can trust what Pond tells them, and that it's plainly working when it is (and says
so when it isn't), before more for it to do. An event that wasn't anything, or a night not recorded without a
word, costs more than any feature earns; each new surface is one more thing that can quietly break.

## Release

The first public release, in this order (decided 2026-11-09): Knowing when it isn't working finished; a signed,
notarized release (with a Developer ID); first run without a guide, watched with someone who isn't technical; a beta
beyond one home, with the website and its downloads page; the CLA and Ready for others before outside pull
requests. Events worth trusting goes on alongside, learning from the beta's homes.

What it takes for anyone to use Pond without building it, find out what it does, and support it.

| Goal | Status | Notes |
|---|---|---|
| A signed, notarized release | in progress | A Developer ID, notarization and an app bundle identifier of Pond's own, so the app installs like any Mac app. It settles how search's picture model reaches users (about 390 MB: in the app, or downloaded on first use), made once and published with a pinned hash rather than converted by each build (what that needs: [search.md](search.md#published-versions)), and comes with updates (Sparkle, from Pond's own feed, signed), release notes from the changelog, and a release built and notarized by CI from a tag, not on a developer's Mac. The first one made: Pond 0.1.0, 2026-11-09 (not yet published). Done: `make release` (docs/release.md): from a clean commit, the app signed with a Developer ID under the hardened runtime, notarized and stapled, in a signed, notarized disk image, checked as Gatekeeper does; search's model built in; the licences shipped with it. Search's model published once, with a pinned hash: done (pond-models' `siglip2-v1`, `models/search.lock`, signed in pond.camera's manifest, `/api/search-model`), and YOLO26 published there too with its source (`yolo26s-v1`, `models/detection.lock`): builds download both, nothing is converted by a build. CI from a tag: done (`release.yml`, its keys in the `release` environment, docs/ci-security.md), waiting for GitHub's macOS 27 runner to leave preview. Model updates: CI checks monthly and proposes a new version in a pull request (`search-model.yml`). Next: Pond downloading search's model itself (Settings › Search: progress, version, Check for Updates, weekly), then updates (Sparkle). |
| The website | in progress | At pond.camera: a landing page with Pond's story (an NVR that's yours, on your Mac, nothing sent to anyone), what it does, and pictures of it (demo mode makes them, with no one's own cameras in them); a **downloads** page for the notarized release (and older ones, with their notes and checksums); and a **privacy** statement saying what Pond and the site collect (nothing, and no analytics). Done: a first draft of the landing page, a static Next.js site under `site/` (its story, the three views, search, HomeKit, camera health, what stays home, a drive-size calculator, the spec sheet), with screenshots from demo mode only. Next: its design reworked (the draft isn't liked yet), a real picture of Live, then the downloads and privacy pages, and hosting at pond.camera. |
| User documentation | later | Everything from a user's side, on the website: getting started (a Mac, a drive, cameras), each view and setting, cameras by make, HomeKit, remote access, the doctor's findings, troubleshooting, and the questions people ask. Written from `docs/` and the app, kept in the repository and published from it, so it changes with the code. |
| Advanced documentation | later | For people who run their own services or work on Pond: the signaling service, a relay and a mesh (Tailscale, Headscale) set up; how Pond works inside (the architecture, how video moves, remote access's protocol, the security model); building, testing and contributing (the CLA, conventions, demo mode for bug reports). Also published from the repository. |
| Donations | later | One-off and monthly, through GitHub Sponsors (and perhaps Open Collective, whose books are public), linked from the app's About, the website and the README; no features held back for donors. |
| Open books | later | What Pond has cost to make, published and kept up to date: development (from the repository: commits, lines, and time spent, kept in a ledger beside it), AI assistance (from the providers' usage exports), the services it runs on (the signaling server, the domain, the Developer Program), and what donations brought in. A page on the website, built from those files, so supporters see where money goes. |
| Ready for others | next | What a public project needs beside the code: `SECURITY.md` (how to report a vulnerability privately, and what's in scope), a code of conduct, issue templates (a bug report names a demo scenario, or attaches the doctor's report), CI on macOS for every pull request (tests and the release build, not only the Linux part), the camera compatibility list open to additions, and the trademark question settled (whether the name and logo, `assets/Logo.af`, are free to use with the code or kept). |
| Signing the CLA | next | The contributor agreement process CLA.md's section 14 names, run by CI on every pull request: each commit's author is checked against the signatures kept in the repository (a GitHub Action, such as CLA Assistant Lite's); one who hasn't signed is asked, in a comment, to read the CLA and reply with the statement that signs it (a comment of its own, not a review or approval), and the check stays red (required before merging) until they have. Each signature records the GitHub account, the CLA's version and the SHA-256 of the exact text shown (each version kept unchanged, tagged in the repository), the date and the pull request; a materially revised CLA is signed again for later contributions. A contributor's earlier commits, made before signing, are named in the pull request where they sign, so they're covered too. A company's contributions go through a corporate agreement, by email. Comes before the repository takes outside pull requests; the CLA reviewed by a lawyer first, as its own note asks. |
| A beta beyond one home | next | Before a public release, a small beta of people with other homes: other makes of camera (ONVIF ones of several brands, H.265 ones, battery and Wi-Fi ones), other Macs (a base Mac mini to a Studio), other HomeKit hubs, remote access over real tailnets and real home routers, and someone who isn't technical. Reports come with the doctor's report or a demo scenario; what's learnt goes into the camera compatibility list and the fixes before the release. |
| First run without a guide | next | Someone who downloads Pond finds their way alone: a first window that says what's needed and does it (a drive, Local Network access, the first camera found on the network and added, the recorder started), with demo mode offered for those with no camera yet. Judged by watching: a fresh install timed with someone who isn't technical, each place they stall a fix. |
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
| Health where one looks | done | Noticing in the main window, working out why in the doctor's own window. Done: the toolbar's state says what needs attention, from one list (the recorder, its drive and room, each camera not recorded or with the doctor's problems and warnings, other Ponds gone quiet or out of reach), and opens an overview of it: each thing with its fix, the cameras kept private (each to make public), the cameras that need attention to show alone, and which Ponds to show. The menu bar item and the camera rail's filter use the same list. The doctor is a window of its own (⇧⌘C), out of Settings: the recorder and each camera down its side, to keep open beside the live view or the timeline. The doctor's window became the camera window: a camera's page has its Doctor and its Settings as tabs, so Camera Settings… from Live or an event opens there (it's now the Cameras window and Settings has no Cameras tab: cameras are added and dragged into order there, its way in at the top of General, in the toolbar, Pond › Cameras… and the overview; a camera's settings are only on its page, and Save there says it's checking, that it saved, or why not); its last day drawn as a strip (connected, down, private, stalled or restarted); other Ponds' cameras listed under their Pond's name with what this Mac knows (connected, private), their own doctor being on their Mac; each page's toolbar has its action (Show in Live, Check All Cameras, Restart Recorder). The diagnosis no longer blames the Mac for one camera unreachable as the service starts. |
| Other Ponds' new events | later | Other Ponds' new events counted while Events isn't open, and seen per viewer once there are phones. |
| A camera from where one sees it | done | A camera's settings and zones reached from where one sees it, not only from Settings. Done: a right-click on its tile in Live (on the stage and in the rail) or on one of its events: Camera Settings…, Edit Zones… (the zone editor over the main window), Doctor…; and on an event, Ignore This Area…, the zone editor with the event's box drawn as an ignored zone for the event's kind, to adjust and keep. "This wasn't anything" on an event quiets the events like it (Quieted, in Events). |
| Notifications that fit the home | later | What tells one, and when, set where it belongs: per camera, per zone and per kind (people at the front door after 10 pm, not cars on the driveway), with quiet hours and the household's away and home (from HomeKit). One set of rules for this Mac's notifications, the Home app's and, later, the phone's. |
| One Settings window, settings in context | done | Settings is one window of Pond's own, not the system's (too small for it): as big as one likes, its sidebar this Pond's settings (General, Storage, Remote Access, HomeKit, Cameras ›, Advanced), and from Cameras, sliding over, the recorder and each camera with its Doctor and Settings tabs, dragged into order, Add Camera under them. ⌘, opens it where it was, ⇧⌘C at the cameras. Every page's cards keep one margin at any width. A camera's everyday settings are changed where it's seen: Camera Settings… on its tile, an event or its HomeKit badge opens them in a panel over the main window (All Settings… for the rest). |
| Fewer settings | done | Settings for what's set once: General, Cameras, Storage, Remote Access and Advanced. Storage is one page: the recordings folder with how long each kind is kept, the space on its drive (a bar, the most continuous recording may use, the space kept free), the drive's checklist folded into one row that opens when something's wrong, and the index. Advanced has beta and test features (each its own switch), the demo, the version and the settings file. The doctor and the recorder live in the camera window. |
| HomeKit at a glance | done | Settings › HomeKit: every camera in the Home app at once, with how it's doing there (in it, being watched, waiting to be added, a problem with its fix), what it sends (live video, HomeKit Secure Video with its last clip, a doorbell's ring) and one button for what to do (its setup code, its settings, the log); the cameras that aren't in it, to add; and, once, when the recorder that serves them all isn't running. Its sidebar row says how many are in the Home app, or which needs a look. |

## Staying up

Pond is a server that looks like an app: it's only as good as the nights it doesn't miss.

| Goal | Status | Notes |
|---|---|---|
| Knowing when it isn't working | next | What stops recording said plainly, as it happens and wherever one is: the Mac asleep or restarted for an update, the recordings drive full, missing or slow, the service stopped, a camera gone for long; and after the fact ("not recorded 03:12–06:40: the drive was full"), on the timeline and in the doctor. On this Mac, notifications (done); away, on one's phone: through the Home app (Pond's own HomeKit sensor going off, which the Home app can notify about, with no server of Pond's), and later push alerts through the hosted service. A quiet daily "all well" check one can glance at, rather than silence that could mean either. |

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

