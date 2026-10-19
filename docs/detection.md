# Detection models

Pond finds people, vehicles, animals and packages in what its cameras see with a detection model, run on the Mac's Neural Engine. One is built in: **Ultralytics YOLO26 small** (COCO's 80 classes, 640×640, FP16; AGPL-3.0). Any other Core ML detection model can be used instead, added beside it and swapped while Pond runs.

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

An event begins once a person, vehicle, animal or package has been seen moving twice, and ends after 6 s with none. It's named for the most important thing in it (a person before a vehicle before an animal, then a package), lists everything else seen, and keeps the surest sighting as its picture: `<events>/events/<camera>/<YYYY-MM-DD>/<HH-MM-SS>-<id>.jpg` (UTC), with the event itself in Pond's database. Both are kept for `retention.events.days`. Nothing is watched while a camera is private.

```sh
pond events                 # the last 24 hours, every camera
pond events doorbell --hours 2
```

### Zones

Without zones, the whole picture counts. A camera's zones, drawn on its picture in its settings (Detection › Edit Zones), narrow that:

- **Watched zones**: once a camera has one, events come only from what's in a watched zone, and only of the kinds it takes (people and packages on the steps, say, but not the neighbour's cat). An event lists the zones it was in.
- **Ignored zones**: nothing there counts, and nothing moving there (a busy road, a tree in the wind) starts the model.

Something is in a zone by where it stands: the bottom middle of its box (someone's feet, a car's wheels), so a person on the pavement whose head is in front of the steps isn't on the steps. Changing a camera's zones starts only its watcher again.

The watchers share one model, and the camera connection that recording and live view already use. Decoding is done by the media engine, so watching costs little until something moves.

## Trying a model

`pond detect` runs a model over recordings, a frame every second (or `--every S`), and says how fast it ran and what it found; `--pictures DIR` keeps some of the frames, boxes drawn:

```sh
pond detect models                                   # the models there are
pond detect /Volumes/NVR/recordings/continuous/doorbell/2026-10-18/18-55-38.mp4 --pictures ~/Desktop/found
pond detect clip.mp4 --model my-model --compute ane  # all (default), ane, gpu or cpu
```

On an M-series Mac the built-in model takes 5–11 ms a frame, so a few frames a second from every camera costs little.

## Exporting a model

Ultralytics models export with their own tool:

```sh
pip install ultralytics coremltools
yolo export model=yolo26s.pt format=coreml imgsz=640 nms=False half=True
```

The built-in model is `models/yolo26s.mlpackage` in the repository, compiled into the app by `make app`.
