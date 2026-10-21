# ADR 0012: The camera captures from the front unless the Vision tripwire is on

- **Status:** accepted
- **Date:** 2026-09-05

## Context

From 1.2 to 1.3 (40) the default camera was Auto: rear while the phone lay face down, front
otherwise, re-resolved at each capture. It was chosen so a face-down phone did not photograph
the desk and so the Vision tripwire had a lens that saw the room. 1.3 (40) added a cue for
Rear — a screen touch among the triggering sensors switches to the front lens — and the
owner's device leg showed it to be a toss-up: a tap that jostles the phone trips motion first,
the trigger fires on that instant's sensors, and the touch folds into the running capture with
no lens change.

The owner's ruling (2026-09-05): "In most use cases, the front camera is going to have the
most utility. Anyone proactively enabling Vision will also encounter the capture modes. Rear
capture is really only ever useful with vision on, used as a Haven-type security cam setup.
Overall, I want the defaults to cover the majority of use cases."

## Decision

1. **Front is the default camera** for new installs.
2. **Rear and Auto are offered only while the Vision tripwire is on.** The Camera picker hides
   them otherwise, with a caption saying why; the Vision row says to pick Auto or Rear for a
   face-down phone. Both stays available regardless: it includes the front lens.
3. **The invariant is enforced in three places** through one pure function,
   `AppSettings.cameraChoice(_:visionOn:)`: when settings load (a stored Rear/Auto from before
   the gate is kept only while Vision is on), when Vision is switched off (the camera returns to
   Front), and defensively at arm (`effectiveCamera` clamps, using the Pro-effective Vision
   state, so a free tier with an inert Vision toggle also captures from the front).
4. The touch cue from 1.3 (40) stays: with Rear and a touch-first trip, the front lens is right.

## Consequences

- A new install captures whoever handles the phone. With the default 3-second clip, a
  face-down phone still gets the face: the front lens sweeps up as the phone is flipped. In
  photo mode a face-down lift is a black frame where Auto's rear shot might have shown a torso;
  photo is the low-data option and the owner accepted that.
- A Vision-less owner who props the phone screen-to-wall loses Rear; the README says so.
- Existing installs on Auto without Vision migrate to Front at the first launch of 41.
- Not done: the "second look" (a front photo after a rear capture that a touch folded into)
  stays a 1.4 candidate; it now matters only to Vision users. **Ruled 2026-09-29 (item 74 line
  2): not built.** Every Vision user can pick Both, so Rear's and Auto's captions and the Vision
  tripwire's hint point at it instead.
