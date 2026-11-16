# ADR 0081: A slow Vision trip saves the view it compared against, on the phone and in the evidence ZIP only

- **Status:** accepted. The design `docs/design/vision-reference-still.md`, APPROVED 2026-11-12 (the owner: "D1-D3 and
  V1-V3 (a), wording approved"; BACKLOG items 239 and 240, ruled that day: slow-check trips only, the still on the
  phone and in the ZIP only, in 1.13). Written before the build, with its path inventory (docs/self-review-checklist.md).
  Amended 2026-11-14 (BACKLOG item 242's round q; below): in clip mode the still is turned as the clip is.
- **Date:** 2026-11-12

## Context

Vision has two checks (`VisionDetector.evaluate`). The quick one trips when more of the view than the sensitivity
allows differs from a rolling baseline of recent frames; the slow one trips when over 35% of the view differs from the
reference set at the start of the armed session or since (`sessionBaseline`, `sessionLimitFraction`), so that a change
made slowly enough to slip under the quick check is still caught. A slow trip shows nothing moving in its photo or
clip, and its trace is flat (item 238): the owner cannot tell a lamp from an intruder. The detector sees only a 32 by 24
grid of each frame's brightness, and nothing was ever saved while armed.

## Decision

1. **The still.** Each time the detector sets its reference (the end of calibration, the re-anchoring after a capture,
   after a gap in the frames, through the settle frames, after a trip, or seeded from the first frame), the camera's
   next frame, within half a second at two frames a second, becomes a colour JPEG at most 640 pixels on its long side,
   in memory only, replacing the one before (V3 (a)). A new reference makes the one before stale at once, so an
   event never gets a still of an earlier reference. The camera tap encodes a frame only when one is asked for, and
   hands it to the main actor in the same step as that frame's grid. The still is dropped at the disarm and at the
   start of a calibration, and a still the camera delivers after either is not kept. It stays while the camera stands
   down (built so, 2026-11-12; this paragraph had it dropped then too): a camera back within the five seconds that
   re-anchor Vision keeps the same reference, which would otherwise have no still. Nothing is written while armed,
   and nothing is shown. The still is turned as the camera's photos are (their connection's turn and mirroring, less
   the tap's own), so that it shows the view as the event's photo does.
2. **Which trips.** A slow trip: the slow check over its limit while the quick check is not. A trip where both are over
   is a quick trip: its photo or clip shows the sudden change, and it gets no still, as now. (Claude's reading of
   "slow-check trips only", for the owner's note; the screen's words, "Vision tripped on a slow change", say this.)
3. **How it is saved (V1 (a)).** At a slow trip, before the event is added to the log, the engine names the still's
   file with a name of the store's form (a UUID and ".jpg", `EventStore.isStoredMediaName`), puts the name and the time
   the still was taken into the event (`visionReferenceFilename`, `visionReferenceTakenAt`), and the store writes the
   JPEG under that name into the media folder (only for a record the log has under that name, only under a name of
   the store's form, never over a file already there). Every copy of the event carries the two fields from its birth,
   so no later write of an older copy can drop them. The other way round needs one rule (found in the build): the
   trip response's own copy, written back when its capture ends, must not name again a still the storage limit took
   meanwhile, so `preservingMonotonicFields` keeps the name gone once the stored copy has none. A crash between the
   event's write and the file's leaves a record naming a file not on the phone, which the signer leaves out and the
   screen shows no still for, as for a photo.
4. **Its place in the evidence (V2 (a)).** A signed attachment named `visionReference`, after `secondary` in the
   record's attachment order, and the time as the fact `visionReferenceTakenAt`. That fact is present only in a record
   with a still: the facts are otherwise every one always present, but a new fact present in every record would change
   every signed record, so the signer would sign the whole log again and the export would refuse each record until it
   had (its check that the facts are the latest revision's, ADR 0080). The evidence ZIP carries the file. The Mac
   verifier reads a record's facts as an open list and checks attachments by name (`EvidenceBundle.isPlainFileName`),
   so the verifiers of 1.10 to 1.12 check the still as they check a photo: no new format, and a test in the macOS lane
   proves it with 1.10's verifier.
5. **Never uploaded.** iCloud's record of an event carries an allow-list of fields (`Event.metadataJSON`) and its
   full-resolution files go up by slot, primary and secondary (`MonitoringCloudCoordinator+Transfers`); the still is in
   neither. The other devices never see it; the paired watch's alert carries no media.
6. **Removed as a photo is.** An event's stored media names (`Event.storedMediaNames`: the photo or clip, the second
   camera's, and the still) are what the store reads wherever it gathers an event's files: the byte limit
   (`pruneMediaBytes`), the count limit's removals (`deleteMedia(for:)`), the sweeps of orphaned media and of media owed
   deletion, and the names a log on disk has. The still goes with its event's photo or clip, and the record's next
   signed revision leaves the attachment out, as it does a photo's; its time stays a fact of the record, as a photo's
   camera does. A set-aside log finds a file by searching its bytes for the file's name (`SetAsideLog.names`), so its
   Share and Delete take the still with its photos, and its record's screen shows it, as the event's screen does; its
   Delete keeps a still the event log names, as it keeps a photo.
7. **On screen.** The event's screen (behind the Event Log's gate) shows the still beside the photo or clip, with the
   approved words: "The view at 11:21, which Vision compared against" and "Vision tripped on a slow change: over a
   third of the view had changed since then." The time is the phone's way of writing it, with the day before it when
   the still is from an earlier day than the event, which the time alone would hide. Share sends it in the evidence
   ZIP only, as the review notes say.

## The path inventory

- **Every path that writes to iCloud or another device:** the meta record (`CloudExfiltrator.makeMetaRecord`: the
  allow-list and the thumbnail), the full-resolution records (`makePhotoRecord`, by slot), the state and beat records,
  the disarm signal, the watch's relay (`WatchAlertMessage`). None carries the still or its time; a test checks the
  payload and the manifest (`mediaManifest`) for it.
- **Every place an event is copied, merged, written back, journaled, persisted and decoded:** the log's persistence
  and the journal write the whole record (Codable), the two fields with it; `EventStore.merged` never lets an incoming
  copy replace this phone's own record, and a mirror never carries a still (`inheritingLocalEnrichment` and
  `carryingFiles` move the slots' files only); the capture pipeline's and the trip response's write-backs carry the
  fields from birth. Older versions (a tester going back to 1.12): their synthesized decoder ignores the two keys, their
  next write drops them, their launch sweep then removes the unnamed file, and their signer signs a revision without
  the attachment; the record's history shows it.
- **Every point where the decision is checked again:** none waits. The trip's verdict and the still are on the main
  actor in the same step (the frame's task), and the engine reads the still where it makes the event.
- **Every fact the decision reads:** the trip's two comparisons (`Verdict.trip(changed:sessionChanged:)`) against the
  sensitivity's fraction and `sessionLimitFraction`, and the reference's generation.
- **Every way to the screen:** the event's screen, from the Event Log (the PIN, or a face or finger where the owner
  turned that on): a read surface, which shows and shares; nothing there deletes.
- **What it leaves behind, and what is published about it:** the file, with its record, removed with the record's
  media. Sentences made untrue, each with words for the owner: the privacy policy's "Those frames are never written to
  storage" (both copies), SECURITY.md's "nothing is stored while watching", the README's Vision row ("Nothing is stored
  while watching"), the comments of `VisionMonitor` and of the camera's tap; a line in the App Review notes; What's
  New. Still true as written: the description's "nothing is stored while it's just watching", the review notes' field
  "nothing is stored unless it trips" and their "Nothing is written to storage until a tripwire actually fires".
- **Every input someone controls:** the scene (the still shows whatever was in view when the reference was set,
  minutes or hours before the trip, a person included: the privacy policy says so); the phone's clock (the still's
  time is the phone's clock, as every record's time is).

## Consequences

- A slow trip can be judged from the event alone: light that changed shows as light, and someone who has since moved
  shows where they stood.
- The still can show a person who was in view at the reference time, earlier than the trip. It stays on the phone,
  goes in the evidence ZIP only when the owner shares it, and goes with the event's photos.
- The camera encodes a frame each time the reference is set, which is rare (calibration, captures, gaps, trips), and
  only the newest still is in memory.
- Not taken: every Vision trip (a quick trip's photo or clip already shows the change); uploading the still (it would
  change iCloud's schema and every other device); a grey still (harder to read); the still inside the record, as the
  thumbnail is (the log would grow, and iCloud's copy would need code to leave it out).

## Amendment (2026-11-14, BACKLOG item 242's round q): the still in clip mode

Decision 1 turns the still as the camera's photos are. A clip session, a new install's default, has the movie output
and no photo output, so the photo connection the turn came from was nil, and the still took no turn or mirroring at
all (item 241's A5, seen by reading; TestFlight 88 could not test it on a phone). The still now takes the turn and
mirroring of the event's capture output (`CameraController.stillTurnSource`): the movie output's in a clip session,
the photo output's in a photo session, in both the one-camera and the two-camera sessions, so it shows the view as the
event's clip or photo does. The decision stands; its words now say "as the event's capture is" where they said
"as the camera's photos are". A phone check in TestFlight 89 confirms it, front and rear.
