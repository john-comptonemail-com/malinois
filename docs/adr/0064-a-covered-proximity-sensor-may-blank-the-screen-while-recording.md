# ADR 0064: A covered proximity sensor may blank the screen while recording: kept, and said

- **Status:** accepted
- **Date:** 2026-10-30

## Context

The Proximity tripwire (on by default) turns on iOS's proximity monitoring for the whole watch
(`ProximityMonitor.swift`), pausing it only for the disarm pad. With proximity monitoring on, iOS turns the whole
display off while something covers the sensor at the top of the screen, as it does in a call. A capture keeps running
then, but its REC badge, the warning and iOS's camera dot cannot be seen until the sensor is uncovered. The documents
said the screen is never blank while the camera is active and that recording is always indicated (BACKLOG 180's A4,
DeepSeek-2 on `296bab0`; D3 and F5).

The owner checked it on an iPhone 17 Pro with the App Store's 1.8.2 (2026-10-30): armed on a charger with the default
tripwires, a tap to record, then the top edge covered: "whole screen went off, event log has the recording".

## Decision

The Proximity tripwire keeps running during a capture, and the documents say what iOS does meanwhile: the README,
SECURITY.md, the privacy policy and both copies of the review notes (the owner: "Say in the docs"). The app still
never blanks the screen itself while a camera runs, and no setting hides the indicators.

## Consequences

- Someone who covers the top of the phone while it records does not see the badge or the warning until they let go;
  the recording goes on and is kept.
- Not taken: pausing the Proximity tripwire while a capture records. It would keep the indicators in view, at the cost
  of the tripwire's detection for the capture's length (up to two minutes in Until clear mode).
- The App Store listing's "the recording indicator shows throughout" (its Vision example) is for the submission's
  review of the store texts.
