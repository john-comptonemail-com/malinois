# ADR 0011: Permissions are asked on first use, and clip audio is off by default

- **Status:** accepted
- **Date:** 2026-09-05

## Context

Through 1.3 (39) the app asked for the camera, the microphone and notifications at first
launch, from the root view's task, before the user had even set a PIN: three system prompts on
top of the PIN screen. The owner's 1.3 goal is reach (ADR 0009, ADR 0010), and those prompts
were the biggest remaining friction on a fresh install. Two facts bounded the change:

- The Sound tripwire is off by default, but the default capture mode is a 3-second clip and
  clips recorded audio, so "the microphone is only needed for the Sound tripwire" was not true.
  Worse, the clip session attached the microphone and the sound monitor started recording with
  no permission check, so a merely deferred prompt would have been raised by iOS itself in the
  middle of arming or a capture.
- Only the device that RECEIVES a cross-device alert needs the notifications permission
  (SECURITY.md, 34.H7); the arming device never does, and registration for remote
  notifications needs no permission at all.

## Decision

1. **Nothing is asked at launch.** The root view's task only registers for remote
   notifications, which feeds the silent CloudKit pushes and needs no permission.
2. **The camera is asked on the first ARM tap**, before the arming screen and so before Guided
   Access could be on, and only when capture or the Vision tripwire needs it and iOS has never
   been asked (`CameraController.cameraPromptIsDue`, pure). A denial still arms; the arm-time
   "Camera access is denied" notice already covers it.
3. **The microphone is asked when a consumer is switched on**: the Sound tripwire's toggle, or
   the new *Record audio in clips* toggle (Settings → Capture). **Clip audio is a setting,
   default off** (`AppSettings.clipAudio`): a new install's clips are video only until the owner
   adds sound. Installs from before the setting keep what they had — the migration
   `migratedClipAudio(stored:micGranted:)` starts it on wherever the microphone was already
   allowed, so no upgrade silently drops audio from evidence.
4. **The microphone is never attached or opened without the grant.** The camera controller
   attaches the mic only when the engine's arm-time decision (`clipAudioAllowed(setting:
   micGranted:)`, pure) says so, and tracks the mic as its own reconfiguration dimension; the
   sound monitor refuses to start recording while the permission is not granted and reports
   itself unhealthy instead. iOS therefore never raises the prompt on its own.
5. **Notifications are asked in context on the receiving side**: Home shows "Cross-device
   alerts need notifications on this device" with Allow and Hide buttons while Pro is active,
   iCloud is ready, Cross-device alerts is on, iOS has never been asked, evidence from another
   device on the account has arrived in this log (a mirrored record — since 1.3 (43), owner's
   ask: most installs are single-device), and Hide has not been tapped (`notificationAskIsDue`,
   pure); Settings → iCloud shows the state with the same Allow; the Cross-device alerts switch
   asks when turned on.

## Consequences

- A fresh install reaches its first armed session with exactly one system prompt, the camera,
  at the moment the user has context for it. Most users never see the microphone prompt.
- Video-only clips by default are also the more defensible default: recording bystanders'
  voices is regulated in more places than video is. The arming screen says clips are video
  only until audio is on, next to the existing Both-camera caveat; the privacy policy says
  when the microphone is asked for (effective date bumped).
- The Siren-mode rule that every trigger is photographed rather than filmed (F4) is unchanged
  even with clip audio off; relaxing it is a separate decision.
- A device that only ever arms is never asked for notifications, which is correct: it has
  nothing to show. A second device on the same iCloud account is asked from its own Home.
- Paths not taken: asking for the microphone at the first arm whenever the mode is a clip (two
  prompts in a row at the first arm, no change in what is recorded); keeping the launch prompts
  (the friction the owner named); a private URL scheme to deep-link permission or
  accessibility settings (App Review risk, and it breaks between iOS versions).

## Amendment (2026-09-05, 1.3 (41))

iOS shows no permission alert while Guided Access is on, so an ARM tap under Guided Access
cannot ask for the camera (found on 1.3 (40), item 69 leg 11). The arming screen now says so
("Allow the camera first", with the way out: cancel, end Guided Access, ARM again, allow, restart
Guided Access); the engine attempts no warm-up while the permission is undetermined, so no
"camera unavailable" notice appears; and the README and the onboarding nudge put ARM before
Guided Access. The countdown stays available in that state: the other tripwires work without
the camera. Also: the clip-audio decision is pushed at every arm, not only when the readiness
policy pre-warms the camera — on battery with Auto readiness 1.3 (40) never handed it over.

1.3 (43): the request itself is **skipped under Guided Access**. 1.3 (42) still made it, and iOS
26 records a request it cannot show as a refusal — Home then read "Camera access is denied" and
the arming-screen notice never had its condition. With the request skipped, the permission stays
unasked, the arming screen shows "Allow the camera first", and the prompt is available once
Guided Access ends. A device where a blocked request already registered as a refusal shows the
existing denied notice (iOS Settings, or a delete-and-reinstall, resets it).
