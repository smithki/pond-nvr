# Motion

How things move in Pond: the rules every change is held to, whoever makes it. Each with what it means here, from
cases that taught it. How smoothly each view moves now, measured, is in [smoothness.md](smoothness.md).

## The rules

1. **A thing is one thing that moves.** A tile, a row, a panel goes to its new place itself: never faded out where it
   was and in where it's going, two of it on screen at once. Live's tiles that change rows travel across the others
   ([live-stage.md](live-stage.md)); a card in Events slides to its new place as the panel opens.

2. **Alive, never distorted.** Moves spring, with a little bounce (SwiftUI's `.snappy`, `.spring(duration:bounce:)`),
   not a flat ease. And nothing is squashed or stretched to make a move: the Timeline's zoom springs the time range in
   view, so every frame is the drawing at that moment's length, not a picture scaled (a picture's scale sprung from 15
   minutes to a day squeezed the lanes far past where they end up).

3. **What belongs together moves together.** One curve, one clock: Live's stage, rail, dock and sidebar are one view
   moved by Core Animation (`LiveShell`); the Timeline's ruler and lanes are moved by the same code from the same
   changes, so the playhead's knob and its line over the lanes never part; a row's label moves with its row.

4. **Taken over, it carries on.** A move begun while another is under way starts from where things are drawn now, not
   from where the last one was going (playing, the Timeline follows the playhead with a move five times a second).

5. **Only what's asked for moves.** Opening a view, or things arriving by themselves (cameras, the lineup, events), are
   drawn in place at once; what someone does is what animates. Live opens still, and its first change asked for
   animates as ever.

6. **Never a frame dropped.** 60 frames a second at least, no frame over 16 ms, on the Mac it's measured on. Nothing is
   built, loaded or drawn whole at the moment it has to move: built ahead (a panel for the card the pointer rests on),
   or a piece a frame.

7. **Edges meet.** No seams, slivers, half-pixel lines or gaps where shapes should join: edges on whole pixels, a
   private stretch square where it meets the line that begins a camera's recording, stretches too close to tell apart at
   the zoom shown drawn as one.

8. **Quiet unless it matters.** Each state is said once, as quietly as it deserves: what's chosen or on its way (a camera
   made private, connecting) is a word or two; a problem is what's wrong and what to do; the colour of an edge means a
   problem.

9. **Faster is the same.** Making something faster never changes how it looks or moves: the new way is checked against
   the old, case by case, frame by frame, before it takes over.

## Checking a change

- **Look at it moving**, not at stills of its ends: the demo's snapshot steps drive each view (`live`, `transitions`,
  `panels`, `timeline`, and steps for single cases), and a burst of the window's pictures, ten a second, shows each frame
  of a move (development.md).
- **Against the way before**, side by side, when it replaces something (the setting it's behind, flipped).
- **Timed**: the steps' reports say how many frames were over 16 ms while each kind of change moved; none is the goal.
