# Smoothness: the benchmark

How smoothly each view moves, measured: where it started, where it is, and what's left. The goal: every motion drawn
within a frame at 60 Hz, at least: no frame over 16 ms, on the Mac it's measured on (an M6), with what's seen exactly as
it was. What's left to do for it is in the roadmap ([roadmap.md](roadmap.md#smoothness)); how things should move, the rules
every change is held to, in [motion.md](motion.md).

## How it's measured

The snapshot steps drive each view as someone would and time the main thread while it moves: a thread asks it
every 4 ms whether it's free, and each late answer is a frame at risk. For each kind of change: how many answers were
over 16 ms (a frame missed at 60 Hz), how many over 33 ms (two missed: a visible stutter), and the slowest. Fewer is
better. A few answers over 16 ms come even with nothing moving (the Mac's own work, the window drawn behind
others): that's the floor. **Met** means none over 33 ms and those over 16 ms down near the floor; **close**, a stutter
or two left in a whole run. How to run them is in [development.md](development.md).

- `transitions` and `panels`: the Events view (far jumps, arrow steps, the detail panel opened and closed), on the
  demo with 20,000 events (`POND_DEMO_EVENTS=20000`).
- `live`: the Live view, every kind of change three times over, on the demo's ten cameras.
- `timeline`: the Timeline (playing, a seek's glide, zooming, a two-finger pan, another day or camera, a kind of event
  hidden and shown), on the same demo.

Each step in a launch of its own, never the first launch after a build (it runs slower), and builds compared back to
back: the demo's scenes follow the clock and its events fill the day, so figures from another time of day differ.
The counts depend on the step's length (how many answers it collected), so compare a row with itself, before and
after, not one view's numbers with another's.

All figures: an M6 Mac at 60 Hz. What makes a frame late is work on the main thread (SwiftUI pieces built as they
appear, a drawing redone); motion run by Core Animation (the Events grid, Live's tiles, rail and dock) leaves it little to
do.

## Where each view stands

Each cell: answers over 16 ms / over 33 ms (slowest). **Before**: the view as it was in SwiftUI; **now**: 2026-11-14.

### Events (AppKit and Core Animation since 2026-11-13)

| Change | Before (SwiftUI) | Now | At 60 Hz on M6 |
|---|---|---|---|
| Far jump | 6 / 0 (32 ms) | 3 / 0 (31 ms) | met |
| Arrow step | 12 / 0 (29 ms) | 6 / 0 (31 ms) | met |
| Panel open | 8 / 6 (44 ms) | 9 / 2 (37 ms) | close: one slow frame as the panel's content is built |
| Panel close, near the top | 3 / 3 (43 ms) | 3 / 0 (33 ms) | met |
| Panel close, far down | 3 / 3 (35 ms) | 3 / 1 (36 ms) | close: one stutter in three rounds |
| Panel opened and closed, 40 times (`panels`) | 40 / 36 (55 ms) | 37 / 2–5 (39–44 ms) | close: one frame over 16 ms per opening |

### Live (AppKit and Core Animation since 2026-11-14)

| Change | Before (SwiftUI) | Now | At 60 Hz on M6 |
|---|---|---|---|
| Add a camera | 8 / 3 (51 ms) | 2 / 0 (23 ms) | met |
| Remove a camera | 13 / 6 (53 ms) | 0 / 0 (12 ms) | met |
| Two changes in quick succession | 9 / 6 (50 ms) | 0 / 0 (13 ms) | met |
| One camera for another (swap) | — | 1 / 0 (18 ms) | met |
| Show all | 100 / 10 (103 ms) | 10 / 6 (55 ms) | not yet: new tiles build their badges at once |
| Focus (one grown to fill the stage) | 14 / 3 (56 ms) | 8 / 1 (49 ms) | not yet: the dock built as it opens |
| Crossfade (one not on the stage) | 40 / 4 (83 ms) | 8 / 1 (38 ms) | not yet: the new tile and the dock built |
| Rail hidden / shown | 14 / 1, 17 / 0 (35 ms) | 2 / 0, 2 / 0 (24 ms) | met |
| Dock opened / closed | 4 / 0, 0 / 0 (31 ms) | 0 / 0, 0 / 0 (9 ms) | met |

(The rail and dock's "before": the SwiftUI rail and dock around the AppKit stage, 2026-11-14.)

### Timeline (SwiftUI; its drawing made cheaper 2026-11-14)

| Change | Before | Now | At 60 Hz on M6 |
|---|---|---|---|
| Seek (the lanes glide to it) | 58 / 2 (38 ms) | 1 / 0 (17 ms) | met |
| Zoom | 146 / 6 (36 ms) | 0 / 0 (16 ms) | met |
| Playing | 149 / 3 (35 ms) | 1 / 0 (17 ms) | met |
| Two-finger pan | 3 / 0 (19 ms) | 1 / 0 (20 ms) | met (it was already) |
| Another day | 15 / 6 (44 ms) | 8 / 3 (39 ms) | not yet: the day loaded on the main thread |
| Another camera | 0 / 0 (13 ms) | 0 / 0 (12 ms) | met |
| A kind of event hidden / shown | 0 / 0, 2 / 1 (220 ms) | 1 / 0, 0 / 0 (16 ms) | met |

The Timeline's seeks, zooms and playing were within 60 Hz with little to spare (the 95th percentile 14 ms); its lanes'
move to Core Animation (docs/timeline-lanes.md) is for room to spare, with no frame over 16 ms in any change.
