# ADR 0025: Preserve the shared audio session when Sound pauses for a clip

- **Status:** accepted; physical-device retest pending
- **Date:** 2026-10-07

## Context

On build51 the owner recorded a Front-camera, three-second clip with clip audio enabled,
microphone permission granted, and both Sound and Vision tripwires enabled. The original
2.8-second MOV contained a mono 48 kHz AAC track whose 134,400 decoded samples were all zero.
With only Sound disabled, the owner reported audible playback inside Malinois.

The capture pipeline warms the camera before pausing Sound. That pause called the monitor's
full stop, which explicitly deactivated the shared AVAudioSession immediately before recording.
Apple documents that deactivating a session with running audio objects stops those objects,
even if the call returns an isBusy error. This is consistent with the observed silent track.

## Decision

Distinguish a temporary capture pause from a full monitoring stop. SensorMonitor exposes
pauseForCapture with a default stop implementation. AudioMonitor overrides it to stop metering
and release its recorder, with the same local cleanup, while leaving the shared session active
for the already-warm camera. MonitoringEngine uses this pause only on its existing audio-enabled
capture path. The existing capture completion path resumes Sound.

Queued monitoring and calibration callbacks check that their metering timer is still valid
before reading a level. Invalidating a timer cannot cancel a task it already queued; without
this guard, the recorder self-heal could reopen the microphone during the capture pause.

Ordinary stop still deactivates the session. Disarm and siren ownership transitions keep that
behavior. The camera remains responsible for capture-session configuration; there is no global
audio-session coordinator or change to permission, retention or evidence-upload policy.

## Consequences and verification limits

The regression tests exercise the real monitor's deactivation boundary and the engine's
pause/resume/disarm behavior, but the simulator cannot prove physical microphone recording.
Build53 must be retested with Sound and Vision both enabled on the Air before this release hold
can close. Passing simulator tests alone does not establish an audible recording.

This clarifies the handoff used by ADR 0011 without changing its permission or audio-default policy.

Reference: [Apple AVAudioSession.setActive documentation](https://developer.apple.com/documentation/avfaudio/avaudiosession/setactive(_:options:)).

## Build53 refinement after the build52 phone test

Build52 passed on battery but remained silent while charging in Auto. The owner then kept the
phone charging and selected Battery saver: recording was audible. This isolates the persistent
warm-camera path rather than charging itself. The first correction was insufficient on hardware.

Pause Sound before single-camera clip warm-up. When that pause actually yields a Sound recorder,
restart the camera so it acquires audio after Sound is stopped. Stop/configure/start runs as one
serialized camera-queue operation, not separate awaited stop and warm calls: disarm cleanup must
not run between them and then be undone by a late restart. Check the shared warm-up deadline
inside the queue before work and after blocking stop/configuration work, before startRunning.

This original decision resumed Sound on every single-clip exit, including timeout.
ADR0038 supersedes timeout cleanup: Sound stays paused until actual camera shutdown
confirms, and an invalidated watch cannot resume a replacement watch's recorder.
Ordinary completed captures retain the existing engine resume guards. Video-only clips, stills and
native Both-camera recording do not receive this single-camera audio restart. Front-only fallback
does. Clips borrowing Sound's microphone now pay the cold-start/exposure-settle delay even in
Instant or Auto while charging; Vision is suppressed during the transition as during other
camera changes. Evidence metadata still precedes capture. Other readiness choices are unchanged.

The operating system's blocking startRunning itself remains uncancellable, as in existing warm-up;
the caller has a bounded deadline and disarm shutdown is serialized behind that operation.
Simulator coverage establishes ordering/cleanup, not audible hardware recording. Build53 phone
verification remains mandatory; the earlier 559-test pass did not establish the build52 fix worked.
