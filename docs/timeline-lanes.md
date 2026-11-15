# The Timeline's lanes: how they move

The Timeline's ruler and lanes are drawings (`TimelineLanes.drawRuler`, `drawLanes`): a time axis, and a lane a
camera of what was recorded, its events, privacy, gaps, the present. Until now each was a SwiftUI `Canvas`, redrawn
every frame of a seek's glide, a zoom, playing and panning: within 60 Hz on an M6 after its drawing was made cheaper
(2026-11-14), with little to spare ([smoothness.md](smoothness.md)). This moves the drawing's motion to Core Animation,
as Events and Live were moved, for room to spare on slower Macs and at 120 Hz.

## What stays, what moves

- **Stays SwiftUI:** the labels (cameras, other Ponds' headings, folding, reordering by dragging), hover and its
  callout, scrubbing, the ruler dragged, two-finger panning, the lanes' vertical scroll; and the ruler itself
  (`RulerDrawing`: its ticks and words spaced for each moment of a zoom, light to draw, as it was).
- **Moves to AppKit (`LanesSurface`):** the lanes' drawing and the playhead's line. The drawing is made once, as an
  image, over the stretch in view and as much again either side, and moved by Core Animation; drawn again only when what
  it shows changes.

## Every case, as it was

| Case | The `Canvas` | The surface |
|---|---|---|
| A seek's glide, the view following the playhead, playing, panning | redrawn every frame, the view's start and length sprung (`.snappy(0.35)`) | the image moved through the same sprung start and length (sampled into keyframes), not redrawn |
| Zoom | redrawn every frame at each moment's length | the same: drawn frame by frame through the zoom (a picture scaled isn't the drawing at the lengths between), then an image again |
| Words held to the view's edges ("Private", "Not recorded" at the start of a bar's part in view; a camera's "… added"; "Recording starts" beside its line) | placed for each frame | layers of their own, placed by the same rules for each moment of a move (`EdgeLabel`) |
| What moves with the clock (today's recording growing at 1 h and 15 m; a kind of event fading; other Ponds' lanes waiting) | 30 times a second | the same, the view's stretch drawn 30 times a second while it lasts |
| Another day (a jump), a camera folded, which Ponds are shown | the lanes' crossfade; at once | the same |
| Hover's outline, new events, recordings | redrawn | drawn again |
| The lanes' accent | the app's (the Mac's accent) | the same (drawn apart from the window, given it) |

Checked side by side with the `Canvas` in the demo (`tlprivacy`, `tlponds`, `timeline-loop`), and timed (`timeline`).

## How it's built

- `TimelineLanes` isn't animated by SwiftUI on the surface (its range given as it ends up, with the transaction's
  animation); the surface animates, through SwiftUI's own spring, sampled.
- A drawing is `drawLanes` into an image (`ImageRenderer` of the same `Canvas`), at the window's scale, with
  `withObservationTracking` round it: what it read of the model changing draws it again. What it's given (cameras,
  folded, highlighted, the accent) compared with what it was drawn with.
- Behind a setting (`timelineSurface`) till it's checked against the `Canvas`, case by case.
