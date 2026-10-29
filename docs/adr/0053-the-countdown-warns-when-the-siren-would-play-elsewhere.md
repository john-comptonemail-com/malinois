# ADR 0053: The countdown warns when the siren would play away from the iPhone

- **Status:** superseded by ADR 0062 (2026-10-28, 1.8.2: in Siren mode the siren plays from the iPhone's speaker, and
  the countdown's warning is removed). Accepted before (BACKLOG 141, the owner's ruling "Approved on your 1-4 plan":
  fable-2's fix "as the test shows"; the test, 2026-10-20); for 1.8 (76).
- **Date:** 2026-10-20
- **Amended 2026-10-23** (1.8.2, BACKLOG 155's A13, the owner's ruling (a)): "before the tripwires start" is held by a
  guard in the engine (`MonitoringEngine.sirenRouteCheckAllowed`), since the check sets the audio setting and the Sound
  tripwire records from calibration on; the check's function is named for what it does,
  `SirenPlayer.setSirenCategoryAndReadOutputs()`.

## Context

Fable's fresh review of 1.8 (75), fable-2 (Medium, suspected): the siren plays with the `.playback` audio category and
no route override, so it goes wherever the iPhone's sound goes. With headphones, AirPods, a Bluetooth speaker, AirPlay
or a car connected, it would not be heard in the room. The siren code has not changed since 1.7.1.

The owner's test on the iPhone (TestFlight 75's step 14): "the siren plays only through airpods when connected, and
moves to phone immediately when airpods are placed in the case". So the suspicion holds, and a disconnect needs no
handling: the siren carries on from the iPhone by itself.

Two ways to deal with it:

1. **Pin the siren to the iPhone's speaker.** iOS offers a speaker override only under the `.playAndRecord` category.
   The siren would then take the recording category, which the camera's clip audio and the Sound tripwire also use,
   and switching it mid-alarm is where the app has lost the siren before (ADR 0025's audio handoff; on 2026-08-26 a
   capture rebuilding its session interrupted the siren every five seconds). It would also hold the siren back from the
   owner's own headphones when they are nearby.
2. **Warn while it is so.** The countdown already warns when the media volume is low (F-13), the other way the siren
   can be lost before the owner leaves.

## Decision

In Siren mode, the countdown shows "Audio is going to <the device's name, as iOS gives it> - disconnect it now so the
siren plays out loud from this iPhone." while the sound would play anywhere but the iPhone's own speaker or earpiece.
It is sampled with the volume warning (at arm and when the countdown starts) and at each tick of the countdown, so it
comes up when headphones connect and goes as soon as they are put away. Nothing is pinned.

The check reads the route iOS gives the siren's own setting: it sets the `.playback` category first, without activating
the session, so nothing plays and no other app's sound is touched. The app's session keeps the category its last user
set, and the Sound tripwire's (`.playAndRecord` without Bluetooth options) leaves Bluetooth headphones out of the route.
The check runs only in Siren mode, before the tripwires start; a Siren-mode camera holds no microphone.

Code: `SirenPlayer.awayWarning(outputs:)` (pure) and `SirenPlayer.setSirenCategoryAndReadOutputs()`;
`MonitoringEngine+SirenRoute.swift`;
the arming screen's countdown.

## Consequences

- The owner learns at the countdown what step 14 showed, while there is time to put the headphones away or cancel.
- Headphones connected after the countdown (the owner coming back within Bluetooth range, for example) still take the
  siren; the armed screen is dark and shows nothing. Out of range, the iPhone plays it.
- Alert and Stealth mode show no warning. Their only siren is the one a suspected jamming attack sounds, with "Alarm on
  suspected attack" on; it follows the sound's route too, and the countdown does not warn of it, as it does not warn
  of a low volume then.
- Not taken: pinning the siren to the speaker (option 1), for the risk above; it can be revisited in a later release
  with its own device testing.
- Tests: `Item141SirenRouteTests` (the rule, the siren's own route, the countdown with and without the siren).
