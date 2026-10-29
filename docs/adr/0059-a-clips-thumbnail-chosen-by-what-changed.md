# ADR 0059: A clip's thumbnail chosen by what changed

- **Status:** accepted
- **Date:** 2026-10-24

## Context

A clip's thumbnail was its frame about 1 s in (0.3 s or 0 s for a shorter clip), 200 pixels on the long side, made
once when the finished clip is stored. The log shows it, and it rides in the record that goes up to iCloud before the
clip itself, so on the owner's other devices it is often the only picture of an event until the clip downloads. The
first second is a poor guess: a Vision trip fires at the first change in the frame, often the edge of a person; in low
light the first frames are the darkest; and the tripwire is held during a capture, so nothing scores the clip's own
frames. The owner proposed choosing the frame by content and refined how (BACKLOG 154, ruled 2026-10-22).

## Decision

1. **Sample the finished clip two frames a second from its start, 24 at most** (`thumbnailSampleInterval`,
   `maxThumbnailSamples`): a longer clip (Until clear runs to two minutes) is sampled over its first 12 s, where the trip
   that started it is. Each sample is the frame at its exact time, at most 200 pixels.
2. **Score each sample with the Vision tripwire's own measure** (`changeScores`): its 32 by 24 cells, made by the
   tripwire's downsampling, mean-normalized, against the clip's own first frame at the tripwire's least threshold
   (`changedFraction`). The clip's first frame, not the session's baseline: a torch-lit clip would read as wholly
   changed, and the Both option's second camera has no baseline. A change of light over the whole frame scores nothing.
3. **Show the first sample whose score reaches 80% of the clip's greatest** (`thumbnailSampleIndex`): the greatest is
   often a hand over the lens or a blur, and the first frame near it is where the subject has arrived.
4. **Keep the frame about 1 s in** when the clip cannot be read, is too short to sample twice, or nothing in it reaches
   the most sensitive trip's 2%: the sample at 1 s when there is one, else the old 1 s, 0.3 s or 0 s request.
6. **Every wait on AVFoundation has a limit** (Codex's codex-14): the clip's length 1 s, read only when the caller does
   not hand it over (a capture does, measured; a download does not); all the samples 1.5 s together, through the
   asynchronous generator, scoring those back by then and cancelling the rest; the old fallback 1 s. When time runs out
   with too little back, the clip is saved without a thumbnail: the store's queue is never held for good.
5. The size, the format (JPEG at quality 0.5), the upload path and the other devices' handling are unchanged: one
   function (`CameraController.videoThumbnail`) and its new helper (`contentFrame`), with its two callers in the store
   unchanged.

## Consequences

- The thumbnail agrees with what trips: the frames it prefers are the ones the tripwire would call changed.
- A cost on the store's queue, which a response waits for before its alert: a clip is stored before the alert shows;
  bounded by decision 6, at most about 2.5 s for a clip whose length the capture measured.
  Measured on the Simulator for a 5 s full-HD clip at 30 frames a second (ten samples): 0.067 s on 2026-10-24
  (`Item154ClipThumbnailTests` prints it as its "step 35:" line). The test's frames are flat greys, which decode
  faster than a camera's; a phone's own clips are not measured. The clip's length is read with AVFoundation's
  asynchronous call (the synchronous one is deprecated since iOS 16), which the queue waits for.
- Not taken: the middle frame (a blind guess, and on a two-minute clip often after the person left); a strip of three
  frames (a wider log cell, and the detail view already plays the clip); the tripwire's own trace (it ends at the trip).
- Tests: `Item154ClipThumbnailTests` (the rule, the score, synthetic clips with a subject arriving mid-clip, a late
  change and a larger change after the subject, the controls, and the cost). Not checked here: real clips from a
  phone's camera, whose noise and exposure differ from the synthetic clips' flat greys.
