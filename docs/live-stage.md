# Live's stage: how it moves

What the Live view does on screen, every motion and the reasons behind it, written down before the stage is moved
from SwiftUI to AppKit (as Events was: `EventsShell`), so the AppKit stage can be checked against it, case by case.
Each item names where it lives today (`LiveView.swift`). A reference recording of today's stage is made by the
snapshot step `live` (the window placed on screen at 1240 × 780; every kind of change below, three times over).

## Why

Every change to the stage (a camera added or taken off, one watched alone, all shown) has SwiftUI work out and lay
out every tile, each frame of the move: on the demo's ten cameras, about one frame in each change over 33 ms (show
all: two or three; the worst 100 ms), the main thread's time almost all SwiftUI's graph and layout, almost none the
video's. In AppKit, each tile is layers: its picture and video resized by Core Animation, its badges and buttons
(SwiftUI, hosted, small) carried with its corners, never laid out again; the stage, the rail, the dock and the
adjustments' sidebar moved together, on one clock.

## The layout

- **Tiles**: `Stage.layout(count:in:)`: the number of columns that makes `count` 16:9 tiles largest in the stage's
  area (less its 12 pt padding), 10 pt between; `Stage.centres`: rows from the top, the block centred, a part-filled
  last row centred. Each tile placed by itself (its centre), so a change of layout moves and resizes every tile to its
  new place, rather than rebuilding rows.
- **Which cameras**: `staged(_:)`: those chosen (`liveCameras` in the settings, and `stagedList` in memory), in the
  rail's order; none chosen, the first four (`defaultCount`).
- **A tile's size decides**: its stream (main at 900 pt wide or more, else sub: `mainStreamWidth`), its corner
  (22 pt over 600 wide, else 16), and `compact` (under 200 pt tall: smaller badges and messages).

## The kinds of move (`StageMotion`)

Chosen for each change before it's made (`toggle`, `solo`, `showAll`, `reorder`), drawn with it first (a removed tile
leaves with the transition it was last drawn with: hence `solo` and `showAll` setting the motion, then making the
change 16 ms later).

| Motion | When | Tiles moving to their new places | New tiles arriving | Tiles leaving |
|---|---|---|---|---|
| **lively** | one change on its own | `spring(0.5, bounce 0.3)`, each tile `ripple` 0.025 s after the one before (by its place), after `removeLead` 0.1 s if a tile was taken off | scale 0.6 about its centre + fade, `spring(0.45, bounce 0.35)` after `insertDelay` 0.3 s (the others make room first) | scale 0.9 + fade, ease-out 0.16 s |
| **calm** | a change within 0.45 s of the last (`fastPace`) | `spring(0.46, bounce 0.15)`, no ripple; in SwiftUI's stage, tiles that change rows didn't travel: a still of each faded out where it was while it faded in at its new place (`rowChanges`, stand-ins, smooth 0.32 s). The AppKit stage moves them as every other tile, over the others while they cross: a tile is one thing that moves, never one that goes and comes back | scale 0.9 + fade, `spring(0.25)` after 0.12 s | as lively |
| **reveal** | Show All (and the overview's Show These Cameras) | `smooth(0.4)`; the tiles already on the stage kept in front while they arrive (`inFront`, 0.8 s) | scale 0.92 + fade, `smooth(0.35)` after 0.08 s + 0.015 s each (`revealStagger`) | fade, ease-out 0.16 s |
| **reorder** | dragged into a new order (on the stage, or in Settings) | `snappy(0.3)`, row changes as calm | as calm | as calm |
| **swap** | one camera alone to another alone | at once, no animation | at once | at once |
| **focus** | to one camera that was on the stage | it grows to fill the stage, `smooth(0.4)`, in front (z 2) | — | the others fade, ease-in-out 0.25 s |
| **crossfade** | to one camera not on the stage | — | it grows from 0.98 to whole + fade, `smooth(0.4)` after 0.2 s (`arriveDelay`), as the old stage has nearly gone | the old stage (live tiles kept as they were, `departures`) recedes as one to 0.98 toward the stage's centre (`RecedeEffect`) and fades, `smooth(0.25)`; let go after 0.35 s |

Also, with every motion:
- **Announcing**: a camera added on its own glows (`AddedGlow`) for 1.8 s; in a quick run of changes, one glow for
  the last added, once the run is over (`announceLater`); a newer announcement takes the glow off the last at once
  (`superseded`); taking one off cancels a pending one.
- **In front** (z order): the focused tile 2; `inFront` 2; the one just added 1; leaving tiles −1.
- **Stand-ins** (`standIn`): a still of a tile at a place it's leaving (row changes; the receding stage) shows what it
  showed: its live picture at that moment (`liveStill`), else its latest recorded one, and its status as it was
  (`TileStatuses`), never its live stream.
- **Not clicked** while leaving.
- **The first frame**: `shownLineup` set on appear, so the first layout doesn't animate.

## A tile

Laid out by the stage (no GeometryReader inside: it would report the final size while the tile is still animating,
and the contents slide diagonally); its contents move with its animated size as one (`geometryGroup`).

- **Picture**: black; its last snapshot, whole (`fit`), dimmed to 35% unless it's playing (or a stand-in); not even
  that when private. Its stream's video over it (`VideoLayerView`, the stream's own `AVSampleBufferDisplayLayer`,
  sized with the view in the same step); shown only once playing.
- **Main and sub stream**: the tile growing or shrinking past 900 pt wide starts the other stream *under* the
  current one (drawing all along, all but unseen), and once it plays and the tile has stopped moving (`settle`
  0.65 s), fades it in over 0.3 s (`crossfade`) with the current one whole underneath, then stops the current one:
  the picture never goes black. Each stream keeps its own view all along.
- **Made private**: the video fades out where it is (0.4 s), then the stream stops; made public: `waking` till it
  plays.
- **Clipped** to its corner (`cornerRadius`), continuous.
- **Overlays**, each always laid out and only faded (views added or removed while a tile moves animate from where
  they last were, not with the tile):
  - the bottom-left corner darkened (radial, 170 pt compact / 280 pt), always;
  - hovered: the top (44/72 pt) and bottom (52/84 pt) edges darkened, ease-out 0.15 s;
  - the status message, centred on the tile (not the snapshot), one layout at every size, scaled 0.8 and up 10 pt
    when compact; a new message fades in where it belongs (`.id(status)`, opacity);
  - bottom left: the name and badges (`badges(compact:)`), 7/10 pt in;
  - top right, hovered: controls (with others on the stage), watch alone, take off (glass circles, the name pill's
    height: 32 / 26 pt compact), ease-out 0.15 s;
  - top left: the health badge; the events chip, hovered, with its popover (which keeps the controls shown);
  - a picture taken: a white flash, 0.55, in 0.05 s, out 0.35 s;
  - something wrong or private: its edge in the health's colour (2 pt, 0.7);
  - the glow round one just added (`AddedGlow`), always there, switched on and off.
- **Clicks**: double-click watches it alone; its menu (`CameraMenu`); dragged, it reorders (`StageReorder`, applied
  before `.position` so its drop area is the tile); hover shows its controls.
- **Sound**: the one heard (`audibleCamera`) unmuted; waking retried soon.

- **Resized** (the rail or the dock coming or going, the window): the tiles follow the stage's edge at once; when
  its new size takes another number of columns, they reflow, each moving to its new place on the side panels'
  curve, those changing rows over the others (AppKit stage; SwiftUI's snapped).
- **Interrupted**: a change made while tiles are still moving (or arriving) moves them on from where they're drawn,
  as one piece, whatever they're in the middle of (each move is added on top of those still running).

## Around the stage

- **The rail** (cameras, left): shown and hidden from the toolbar (`showRail`), sliding off its leading side and
  fading, `dockAnimation` (spring 0.42, bounce 0.12); at once while the window's being resized (`railMovesAtOnce`).
  It steps aside for the adjustments' sidebar when there isn't room for both, and comes back when the stage has
  several cameras again (`alongStage`, `railMadeRoom`, with a note: "Cameras hidden to make room for the controls",
  2.5 s), in the same transaction as the stage's change, so it moves with the tiles.
- **The dock** (one camera alone, its controls, under the stage): opened and closed (`setControls`, the button, ⌥⌘L)
  with `dockAnimation`; held back until what it holds is loaded (or 0.8 s, `dockWait`), the button saying so; the
  stage over the dock while open (tiles growing back over its place pass over it), the button over the stage while
  hidden.
- **The adjustments' sidebar** (right): with the dock, sliding from the trailing edge and fading; floating over the
  stage instead when the window's too narrow.

## The new stage, checked against

The reference recording, side by side, change by change; the `live` timings, before and after; and each item above
ticked off as it's built.
