# Detection models

Pond finds people, vehicles, bikes, animals and packages in what its cameras see with a detection model, run on the Mac's Neural Engine. One is built in: **Ultralytics YOLO26 small** (COCO's 80 classes, 640×640, FP16; AGPL-3.0). Any other Core ML detection model can be used instead, added beside it and swapped while Pond runs.

## Adding a model

A model is a Core ML model (`.mlpackage`, or compiled `.mlmodelc`) with a manifest of the same name beside it, in Pond's Models folder:

```
~/Library/Application Support/Pond/Models/
    my-model.mlpackage
    my-model.json
```

The manifest says what it is and how to read it:

```json
{
  "name": "RF-DETR small",
  "license": "Apache-2.0",
  "source": "https://github.com/roboflow/rf-detr, exported to Core ML",
  "inputSize": [640, 640],
  "output": "detr",
  "minimumConfidence": 0.4,
  "categories": { "parcel": "package" }
}
```

- **`output`** is how its answers come out:
  - `end-to-end`: final boxes, `[1, N, 6]` of x1, y1, x2, y2 (input pixels), score, class. Ultralytics YOLO26 and YOLOv10 exported with `nms=False`.
  - `yolo-raw`: raw candidates, `[1, 4 + classes, anchors]` (centre, size, then each class's score); Pond removes the overlaps. YOLOv8, YOLO11 and YOLOv9 exported without NMS.
  - `vision`: a model with its own suppression in its Core ML pipeline, whose objects Vision gives as they are. Ultralytics exports with `nms=True`, Create ML object detectors.
  - `detr`: queries, boxes `[1, Q, 4]` (centre and size as fractions) and logits `[1, Q, classes]`. RF-DETR, D-FINE, RT-DETR.
- **`labels`** names its classes in order; left out, they're read from the model (Ultralytics writes them in its metadata).
- **`categories`** puts labels Pond doesn't know in its terms (`person`, `vehicle`, `animal`, `package`, `other`); the common ones (COCO's) are known.
- **`license`** is shown where the model is chosen. A model's terms are its maker's, and travel with its file.

Pictures are letterboxed into the model's input (scaled to fit, centred), and its boxes mapped back. A package is compiled the first time it's used and kept compiled in `~/Library/Caches/Pond/Models`.

## Events

The service watches every camera (unless its `detection` is `false`): it decodes the sub-stream, looks for motion five times a second (brightness on a coarse grid against a slowly changing background), and while something moves, and for 2 s after, runs the model up to four times a second. What the model finds is followed from picture to picture, so someone walking past is one sighting, not forty. Only something seen moving counts, so a car parked in view never starts an event; a person walking past it does.

An event begins once a person, vehicle, bike, animal or package has been seen moving twice. It goes on while that's in view (or something as telling: cars passing while someone's at the door are listed in the event, but don't keep it going once they've gone), moving or not: while something is followed, the model looks every 2 s though nothing moves, so a dog that walks in and lies down is one event. It ends when nothing has been seen for 10 s, or when what's there has been still for 2 minutes (a car that parked). If the same thing moves again later (followed all along), or the same kind of thing moves within 30 s of the end, the event takes up again instead of a new one beginning. It counts what was seen at once (the most people in any one picture: one person who walks past is "a person", even if the model found them twice in a frame, whole and from the waist up, or lost and found them again), each by the word the model gave it most surely (a cat it called a dog for a moment is "a cat"). It's named for the most important thing in it (a bike before a person, as a moving bike has a rider; then a vehicle, an animal, a package), lists everything else seen, and keeps the surest sighting as its picture: `<events>/events/<camera>/<YYYY-MM-DD>/<HH-MM-SS>-<id>.jpg` (UTC), with the event itself in Pond's database. Both are kept for `retention.events.days`. Nothing is watched while a camera is private.

```sh
pond events                 # the last 24 hours, every camera
pond events doorbell --hours 2
```

### Doorbell presses

A doorbell's press is an event of its own ("doorbell pressed"), with the picture at that moment (the next frame the watcher decodes; none while the camera is private). Kept whether the doorbell is in HomeKit (where it also rings) or not (then the service watches its button just for this), and whether or not detection is on.

### Left items

Something a person carries and puts down (a backpack, a handbag, a suitcase, an umbrella: COCO's carried things, which the built-in model knows) is watched from when it arrives. Still there 30 s later, in the same place, with nobody standing over it, it's an event of its own: "backpack left", with its picture. One already in view when Pond started, one carried past, and one picked up again within a few seconds make none; one left isn't told again while it stays. While one waits, the model looks every 5 s though nothing moves.

Packages are a category of their own, but the built-in model doesn't know them (COCO has no box or parcel class): a model that does, added to the Models folder, finds them; Pond's own is planned ([roadmap](roadmap.md)).

### Zones

Without zones, the whole picture counts. A camera's zones, drawn on its picture in its settings (Detection › Edit Zones), or from a right-click on its tile in Live or on one of its events (Edit Zones…; on an event, Ignore This Area… opens them with that event's box drawn as an ignored zone for its kind), narrow that:

- **Watched zones**: once a camera has one, events come only from what's in a watched zone, and only of the kinds it takes (people and left items on the steps, say, but not the neighbour's cat). An event lists the zones it was in.
- **Ignored zones**: nothing there counts, and nothing moving there (a busy road, a tree in the wind) starts the model.

Something is in a watched zone by where it stands: the bottom middle of its box (someone's feet, a car's wheels), so a person on the pavement whose head is in front of the steps isn't on the steps. An ignored zone also leaves out what's nearly all inside it (three quarters of its box), whatever it stands on: a person on a TV is cut off at the screen's edge, where the zone drawn round the screen may stop just short. Zones apply from when they're saved; events already made stay as they were. Changing a camera's zones starts only its watcher again.

### Boxes on the timeline

The service keeps what each look of the model found (things that matter: people, vehicles, bikes, animals, packages, items), with how sure, where, the track it was followed as, and whether the camera's zones counted it: a few looks a second, only while something moves, kept as long as events. The timeline's boxes button (or B; *Draw Boxes Around Identified Objects* in its ⋯ menu in a narrow window) draws them over the recording: each in its kind's colour, labelled with what it is and how sure; what the zones ignored (someone on a TV) dimmed and dashed. They're never drawn into the recording itself (it stays as the camera sent it) nor into the Home app's picture (its hub does its own detection, which boxes would get in the way of, and its clips are kept as sent).

### In the Home app

A camera's motion sensor in the Home app follows its events: on when one begins (or takes up again), off a few seconds after it ends. So HomeKit Secure Video records, and the Home app notifies, for a person, vehicle, bike or animal in the camera's zones, not for leaves, shadows or headlights. A doorbell's button rings as before. A camera can use its own motion instead (its settings › HomeKit › Motion in the Home app; `homekitMotion: "camera"`), and does when it isn't watched. With detection, a video-only camera (Pond doesn't talk to it beyond its video) records to HomeKit Secure Video too.

### A closer look

The model sees the whole picture squeezed to 640×640, so something small in it (a cat across the room, someone at the end of the drive) is a few dozen pixels. Where something moves, the watcher also gives the model a close-up: the moving area with room around it, at least 640 pixels square, cut from the main stream at full resolution. The main stream is decoded only while something moves (through the recorder's own connection, from its latest keyframe, so a picture is at hand at once) and let go a few seconds after. What the close-up finds is put back in the whole picture's terms and merged with the rest. One more run of the model (about 10 ms) for each of up to two moving areas, only while something moves. `pond detect FILE --camera ID --closer` replays a recording this way.

The watchers share one model, and the camera connection that recording and live view already use. Decoding is done by the media engine, so watching costs little until something moves.

## What you say of events

**This Wasn't Anything** (an event's menu, on its card or in its details) tells Pond an event wasn't worth one, and later events like it are *quieted*: still recorded and made (and HomeKit hears of them as ever), but marked "probably nothing" with why, left out of Events and of the new count. The **Quieted** chip in Events shows them; **It Was Something** on one undoes it for what's like it. An event is quieted when it's:

- **one you dismissed**;
- **under a learnt rule**: three or more of one kind dismissed in one spot (their boxes' middles within an eighth of the picture, their sizes within twice each other) in one part of the day (night is 7 p.m. to 7 a.m.), and none of that kind said to be something there: another of the kind in that spot then ("vehicles here at night");
- **like one you dismissed**: of the kind, near its spot, its picture's embedding (the one search uses, of its subject) very like that one's (cosine 0.9 or more), and more like it than like any said to be something there: a shadow, a flag, a reflection, called a person again.

What's said is kept in Pond's database (its `feedback` table: the event's camera, kind, box and time, the verdict, and a copy of its embedding, so it outlasts the event). A camera's settings say what it's learnt (Detection › Learnt from your feedback), and **Forget…** clears it.

## Trying a model

`pond detect` runs a model over recordings, a frame every second (or `--every S`), and says how fast it ran and what it found; `--pictures DIR` keeps some of the frames, boxes drawn:

```sh
pond detect models                                   # the models there are
pond detect /Volumes/NVR/recordings/continuous/doorbell/2026-10-18/18-55-38.mp4 --pictures ~/Desktop/found
pond detect clip.mp4 --model my-model --compute ane  # all (default), ane, gpu or cpu
pond detect clip.mp4 --camera living-room           # with that camera's zones: where each thing stands, and whether it counts
```

On an M-series Mac the built-in model takes 5–11 ms a frame, so a few frames a second from every camera costs little.

## Exporting a model

Ultralytics models export with their own tool:

```sh
pip install ultralytics coremltools
yolo export model=yolo26s.pt format=coreml imgsz=640 nms=False half=True
```

The built-in model is `models/yolo26s.mlpackage` in the repository, compiled into the app by `make app`.
