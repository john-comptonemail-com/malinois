# ADR 0062: In Siren mode the siren plays from this iPhone's speaker

- **Status:** accepted (BACKLOG 163's step 26, item 155's A12; the owner's rulings: "26 - 1" and "I thought we were
  always going to play siren through the speaker?" on 2026-10-27, "2 - always" and the log line approved on
  2026-10-28, then "remove the countdown audio warning"); for 1.8.2 (79). Supersedes ADR 0053.
- **Amended 2026-10-28** (BACKLOG 170's codex-7 and codex-8, the owner: "rest yes"): a speaker request iOS refuses is
  checked like the fallback, and where the siren plays logged (decision 4); AirPlay screen mirroring is an output of the
  recording setting, which the first version said no AirPlay device was (Context, path 2).
- **Date:** 2026-10-28

## Context

ADR 0053 (1.8 (76)) left the siren on the playback audio setting, which plays wherever the iPhone's sound goes, and
warned at the countdown while headphones or a Bluetooth device would take it. The owner's check A on 1.8.1 (2026-10-27)
confirmed what the warning cannot cover: AirPods that connect during a watch, after the countdown, take the siren. So a
thief's headphones, or the owner's own coming back within range, keep it from being heard in the room.

iOS pins an app's sound to the iPhone's speaker only under its recording audio setting (`.playAndRecord`). With
`defaultToSpeaker` and without the options that admit Bluetooth (HFP or A2DP) or AirPlay outputs, Bluetooth headphones
are not eligible outputs at all, nor AirPlay devices but for screen mirroring, which Apple documents the setting as
supporting; `overrideOutputAudioPort(.speaker)` also takes the sound off wired headphones, until the next change of
route. ADR 0053 did not take this for two reasons:

1. The recording setting is the one the camera's clip sound and the Sound tripwire use, and switching it under a
   running siren is how a siren was lost before (ADR 0025). In Siren mode this does not arise: captures are stills,
   the Sound tripwire stops while the siren sounds, and the camera's microphone is released before the siren starts,
   as before.
2. With Malinois's microphone permission never answered, iOS might ask for it when the siren starts, mid-alarm. The
   Simulator does not (`round25-micprobe`, 2026-10-27: with the permission reset, the recording setting with the
   speaker asked for activated at once, and no question came); a real iPhone may differ.

## Decision

1. **In Siren mode the siren plays from this iPhone's speaker**, whatever the microphone permission: the recording
   setting in the default mode, with `defaultToSpeaker` and `duckOthers` and none of the Bluetooth or AirPlay options,
   and the speaker asked for at each start. A change of route while it plays (wired headphones, a USB device or a car
   connecting) asks for the speaker again. Nothing is recorded with the setting. A request iOS refuses is checked like
   the fallback (decision 4).
2. **If that setting will not start, the playback one is used for that start**, so the alarm still sounds; the next
   start tries the speaker again.
3. **The suspected-attack alarm in Alert and Stealth is as it was**: the playback setting, wherever the sound goes.
4. **An alarm that plays anywhere but the speaker without the speaker setting, or with its request refused, is
   logged**, once from its start to its
   stop: a status entry, silent on the other devices as every status entry is, "The siren played through <the output,
   as iOS names it>, not this iPhone's speaker" ("headphones or another device" when iOS names none). The name rides
   in the entry's kind, encrypted in iCloud as every kind is, and is kept as a device label is: no control or
   direction characters, at most 40 characters and 160 bytes. A kind not as this build writes it is dropped.
5. **The countdown's warning is removed** (ADR 0053's decision): in Siren mode the siren no longer goes to headphones,
   and nothing before the siren's own start sets an audio setting.
6. **Both settings name the default mode**, so the siren never plays in the Sound tripwire's measurement mode, which
   Apple documents as lowering the playback level. Before 1.8.2 the playback setting was set without a mode and kept
   the session's, so with the Sound tripwire on the siren took its measurement mode (on the Simulator the undo check
   `round26-undo26-modeplayback` shows the mode kept; how much quieter that made the siren on an iPhone is not
   known).

Code: `SirenPlayer.audioSetting(onSpeaker:)` and the player's `activate`, route-change handler and
`onPlayingElsewhere`; `MonitoringEngine+SirenRoute.swift`; `Event.sirenElsewhereKind(device:)` and its entry in the
iCloud decoder's list.

## Path inventory: every way the siren's sound can leave the speaker in Siren mode

1. Bluetooth headphones, AirPods or a Bluetooth speaker, connected before or during the alarm: not eligible outputs of
   the setting (decision 1).
2. AirPlay: not eligible but for screen mirroring, which the setting supports; the speaker request is to take the sound
   off it too, untested (decision 1; TestFlight 79 where a receiver is at hand).
3. Wired or USB headphones, or a car, connected before the alarm: the speaker asked for at the start (decision 1).
4. The same connected while it plays: asked for again at the change of route (decision 1).
5. A restart (a call's end, an activation retry, a late microphone release): the same setting, asked again.
6. An escalation in Siren mode (a sensor flood, suspected jamming): the same setting.
7. The setting refused: the playback setting, logged when it plays elsewhere (decisions 2 and 4). The speaker request
   refused, at the start or at a change of route: logged when the siren plays elsewhere (decision 4).
8. Another part of the app changing the setting while it plays: the Sound tripwire is stopped for the siren and the
   camera's microphone released first, as before, and captures are stills in Siren mode.

## Consequences

- With headphones or AirPods connected, before or during a watch, Siren mode's siren is heard in the room.
- The owner's own headphones nearby no longer get it either; the ramp's quiet start plays from the speaker.
- iOS may show its orange microphone indicator while the siren plays, the setting being a recording one.
- If a real iPhone asks for the microphone when the siren first starts with the permission never answered, the
  question comes up mid-alarm. TestFlight 79 checks it on a device that has never asked (Malinois absent from Settings
  → Privacy & Security → Microphone); if it does, the fallback is asking when Siren mode is chosen. **Checked
  (TestFlight 79, 2026-10-29):** on the owner's iPad mini, where Malinois had never asked (reinstalled), no question
  came at the arm, the trip or the siren, and Malinois stayed off the Microphone list; the owner's iPhone had answered
  the permission, so an iPhone in that state was not tried. The fallback is not needed.
- The countdown's low-volume warning reads the volume iOS reports for its current output; with headphones connected
  that may be theirs, not the speaker's the siren now plays at.
- Alert and Stealth's suspected-attack alarm still follows the sound's route; it is now logged when it plays elsewhere.
  An output that connects after such an alarm started is not logged.
- A device on 1.8.1 or earlier does not recognise the new entry and leaves it out of its log; on this phone, an
  earlier version installed over 1.8.2 shows it as an entry it does not recognise.
- Tests: `Item141SirenRouteTests` (step 26's part), `Item148DecoderFuzzTests` (the kind admitted, damaged ones
  dropped) and `Item170ReviewTests` (a refused speaker request). Device checks on TestFlight 79: check A again
  (AirPods connected during a watch, then a trip in Siren mode), the question on a device that never asked, what iOS
  shows while the siren plays, and screen mirroring to an AirPlay receiver where one is at hand.
