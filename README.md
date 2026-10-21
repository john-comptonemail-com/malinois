# Malinois

A covert unattended-device tamper detector for iPhone.

**[Download on the App Store](https://apps.apple.com/us/app/malinois-device-anti-tampering/id6797636246)**

Malinois' singular objective is that you either:

- **A.** Return to an unattended device in the same state you left it, or
- **B.** Know that unauthorized access was attempted (or succeeded)

It is designed for that to hold even when the person who handles your phone knows your iPhone passcode. Malinois is a detector, not a lock: knowing is the goal, and the photo or clip it takes is best-effort evidence on top. It watches only while it's open on the screen.

Once armed, if the phone is moved, tilted, unplugged, handled, touched, or approached, Malinois logs a tripwire event, tries to capture a photo or clip, and writes it to a PIN-gated Event Log. Arms, disarms and tripwire events are logged with no way to delete a single entry, not even with your PIN.

**Before you rely on it:** turn on Guided Access with its Side Button option off, give Guided Access and Malinois codes of their own rather than your iPhone passcode, turn Voice Control off if you use it, and set iOS to ask before new wired accessories connect. Malinois can check that Guided Access is on, but iOS doesn't let it see the other settings: those are up to you.

**What you'll find afterwards**

| If someone… | You'll find |
|---|---|
| picks up, moves, touches, unplugs or covers the phone | An event in the Event Log: the time, the sensors that fired, and a photo or clip when the camera could take one. With Pro, verified iCloud access and a connection, the event's record reaches your iCloud within moments, before the photo, and your other devices get an alert. |
| keeps jostling or tapping it to bury the real event | One "sustained activity" record instead of a flooded log, with photos still taken on a timer. |
| tries wrong PINs | Wrong disarm PINs leave their own event, with a front-camera photo when available. |
| disarms it with your PIN | A disarm record. With Pro, your other devices get a disarm alert. |
| knows your iPhone passcode and forces a restart to get in | The phone is normally at its lock screen when you return, not Malinois's dark screen. The handling before the restart is normally recorded, and the next time Malinois runs it records "Monitoring interrupted" and that the phone restarted. |
| knows your Guided Access passcode and closes Malinois | The next time Malinois runs, it records "Monitoring interrupted". |
| deletes Malinois | The app and its log are gone, which is itself the sign. With Guided Access on, getting to the Home Screen to delete it takes one of your passcodes. With Pro, events already uploaded can survive in your iCloud; SECURITY.md says when they can't. |
| switches the phone off or destroys it straight away | With Pro and a connection, the event's record goes up before the photo, so it can reach your iCloud first. Without a connection, nothing leaves the phone. |
| blocks its signal | If the phone had a connection when you armed it and hasn't moved, losing every connection for about 30 seconds sounds the siren and leaves a signal-loss entry. |

**When you come back:** before typing your PIN, look at "Armed for" above the pad: it should match how long ago you armed. After disarming, Home's "Last armed" line should start at the time you armed; if it starts later, your session ended and another began. Then open the Event Log and read every entry since you armed, not just the newest: a disarm you didn't make, "Monitoring interrupted" or a wrong PIN means someone tried, even if the phone looks untouched.

Without Pro (free for every install during Early-Access), Malinois sends nothing off the phone, so a wiped or destroyed phone takes its record with it; only an earlier iOS backup might hold a copy. Sensors have thresholds and iOS can stop any app: [SECURITY.md](SECURITY.md) lists the known gaps. You can check all of this against the code: this repository holds the source of every shipped release, with no third-party code ([what this repository is](#what-this-repository-is), and what it can't prove).

## Try it out

1. **First run** — set a 4-digit PIN (or 6).
2. Tap **ARM**. The camera prompt appears the first time; allow it.
3. On the arming screen, **triple-click the side button** to start **Guided Access** (one-time iOS setup: Settings → Accessibility → Guided Access).
4. Tap **Start countdown**, set the device down, screen up, and go about your business. The countdown ends, sensors calibrate, and the screen goes dark.
5. **To disarm:** press and hold the screen for 5 seconds, enter your PIN, then triple-click again to end Guided Access. Evidence is in the **Event Log**.

**Enable Guided Access before you trust an armed phone unattended.** You can skip it while getting a feel for the app, but it's what stops someone from simply closing Malinois. One-time setup: Settings → Accessibility → Guided Access. Triple-click the side button before arming to enable GA, and triple-click again after disarming to end it. Using a PIN instead of Face ID for Guided Access is recommended due to the open "Guided Access is not available" iOS bug. In Guided Access's **Options**, turn **Side Button** off (Sleep/Wake Button on older phones), so one press can't lock the screen and pause monitoring; a press then only shows the iOS reminder, and ending Guided Access still needs its passcode. Voice Control is off unless you've turned it on; if you use it, turn it off before arming, because its "Close application" command can close Malinois even under Guided Access. Optional hardening: Screen Time → Content & Privacy Restrictions → Deleting Apps → Don't Allow, behind a Screen Time passcode, since deleting the app is the one thing that destroys the on-device log.

## AI Disclosure

**I am a data engineer who wanted an app that didn't exist, but I am in no way an iOS developer.** Malinois was developed in its entirety using AI tools; primarily Fable 5. Rounds of adversarial reviews are performed with multiple passes from different models (5.6 Sol, Kimi K3, GLM 5.2, Deepseek V4 Pro/Flash, etc.) until a release-ready consensus is reached, and I test on 3 modern iOS devices. The majority of the documentation is also AI-generated. As with most docs these days, I find it frustrating to read at times, but I also feel it would be deceptive on my part to try and conceal it by rewriting, so I've reviewed it for obvious errors and largely left it as-is.

This is ultimately a personal project, but it's a project I think others might find a use for, and it would not have happened without AI. As such, please poke holes in the code, the assumptions and decisions I made, threat model thinking, anything and everything: I'm relying on it too.

**What you can check rather than take on trust.** The rules in SECURITY.md are each pinned by a unit test. Every release goes through adversarial reviews by other models and, lately, by outside readers of this repository; each finding and what was done about it is tracked in a numbered ledger before the fix ships. Builds are tested on two iPhones and an Apple Watch. The full test run for each release is in its GitHub Release notes.

## How this is engineered

- About 24,000 lines of Swift across the app, its watch app and two extensions, and no third-party code: what you see is everything that runs.
- 1,079 unit tests in 73 files, about as many lines of tests as of app. Most rules in SECURITY.md are pinned by one.
- The decisions that matter are pure functions, 196 of them, each tested on its own.
- 44 design decisions are written up as records in `docs/adr`, which the code cites ("ADR 0039").
- Fixes cite a numbered findings ledger by item number, which stays private.

## Pro

**Early-Access:** while the program is open, Pro is free for every install, permanently — no card, nothing to cancel, nothing to do. If Pro ever becomes a paid unlock, that will apply to new installs only; Early-Access installs keep everything.

A Pro in-app purchase is available, but **Pro is not required to meet Malinois' objective**: Detection, on-device capture, the local log, everything needed to fulfill that promise, is and will always be free. Pro features are "nice-to-haves" or extend the app functionality beyond the primary objective, and I believe the defaults are sufficient for the vast majority of use cases. Pro features include cloud backup/restore (each event's record reaches iCloud within moments, then its photo or clip, so a phone destroyed seconds later can still leave its record behind), cross-device alerts, Vision/Audio tripwires, more capture options, and helping me further enrich Anthropic investors.

> ⚠️ Use this only on **your own device**. It is a personal anti-tampering / anti-snoop tool, not a surveillance tool for other people.

## What's new in 1.8

- A one-time screen before your first arm shows how to disarm, and how to end Guided Access.
- In Siren mode, the countdown now warns when the siren would play in connected headphones or a Bluetooth device instead of out loud.
- If Malinois is closed again within 90 seconds of re-arming itself, Home now says it did not re-arm.
- Home, the PIN screens and the calibration card now fit the largest text sizes.
- A tap on the REC badge's corner, or on the screen during the "Calibrated" card, now counts as a touch.
- On Apple Watch, alerts from your iPhone now show when they happened, and alerts that waited more than an hour arrive as one summary.
- On Apple Watch, alerts from your iPhone that also arrive through iCloud are now paired, to cut down on duplicates.
- A cancelled countdown now reaches your Apple Watch too.
- Verify iCloud access now says why it is unavailable while Guided Access is on.
- "Download full evidence" is offered only where a copy can be in iCloud, and sharing a status entry no longer calls it tampering.
- If Malinois's settings can't be read, your iCloud backup choice is kept, or backup is turned off.
- A photo or clip that arrives during a storage clean-up is now checked again before it can be removed.
- Clearer words in the app about what iCloud backup, alerts and the Vision tripwire do.
- Fixes from independent reviews, including which event a sensor trip is recorded on and how storage limits apply to downloads.

Earlier releases are listed under [Roadmap](#roadmap), at the end of this file.

---

## What this repository is

This is the **source of each shipped release**, published so the app's privacy
and security claims can be checked against the code rather than taken on
trust. Each commit here corresponds to one App Store release. The app source
is byte-identical to what was submitted, with exactly one change: the developer
team ID is removed from the project file. (This README and the licence files
exist only in this mirror. SECURITY.md is published as written from 1.6 on;
earlier releases carried light adaptations to it.)

It is a **mirror, not a project**: development happens elsewhere, issues and
pull requests are not monitored, and the two histories never merge. New code
appears here when — and only when — a release ships.

One honest limitation: iOS offers no reproducible builds, so this repository
cannot *prove* that the binary on the App Store was compiled from exactly this
tree. What it can do is let you read what the app is designed to do — every
claim in the privacy policy and in [SECURITY.md](SECURITY.md) is checkable
against this source.

## Where to look

- **[SECURITY.md](SECURITY.md)** — a full threat model and technical reference, about 1,700
  lines: every defense mechanism, the attacks the app explicitly does *not* defend against, and how to
  report a vulnerability. If you read one file, read this one.
- **`Malinois/`** — the app. No third-party dependencies, by design: what you
  see is everything that runs.
- **`MalinoisTests/`** — the unit tests. Most security rules in SECURITY.md
  are pinned by a test here.
- **`docs/adr/`** — the design decisions, one record each, as written when they were made; the code
  cites them by number, and [the index](docs/adr/README.md) lists them.

**A reviewer's map**, one line each:

- The PIN's storage and lockout: `Malinois/Services/KeychainService.swift`.
- The crash-durable log, its write-ahead journal and quarantine: `Malinois/Services/EventStore.swift`.
- What happens at a trip, the record before the response: `Malinois/Services/MonitoringEngine.swift` (`respond`).
- Which account may receive evidence, and the upload chain: `Malinois/Services/CloudEnrollment.swift` and `Malinois/Services/CloudExfiltrator.swift`.
- The disarm hold and the attribution window: `Malinois/Services/DisarmEntryCoordinator.swift`.

**Invariants**, each checkable against the code and its tests:

- The record is written and synced to disk before anything responds: before the alarm, before the camera.
- There is no delete control for records; only the log's size limits remove them, and SECURITY.md says which removals the log reports.
- A Keychain that cannot be read is never taken for "no PIN": setup is never offered over a sealed one.
- Monitoring continues during PIN entry; only the proximity sensor pauses, and PIN keys are not touch trips.
- Detection, capture and the local log are free, and stay free.
- Without Pro nothing leaves the phone; with it, copies and alerts go only to your own iCloud account and your own devices.

Building requires Xcode and your own signing settings; the project file ships
with no development team set.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE), with an App Store additional
permission and a name/artwork reservation in
[LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md).

## Roadmap

Solo project, no dates, and everything here is subject to change — or to being talked out of. If one of these matters to you (or something missing does), support@comptonemail.com reaches me.

**Shipped in 1.3** — honest capture-interruption records: a capture that produced nothing now says why, on the event itself.

**Shipped in 1.3.1** — the fixes from the September review pass: a cancelled countdown leaves a record and alerts your other devices, the Side Button coaching for Guided Access, and the app now says when its own log or journal is in trouble.

**Shipped in 1.3.2** — the rest of the September review fixes: the record comes first (a jamming blackout or a sustained flood is logged before the alarm), fewer stray records, and fixes for clips and the camera; and the Event Log's sync spinner now stays up until every record has reached iCloud.

**Shipped in 1.3.3** — a fix: after Malinois is ended while armed (a crash, the app being closed, a restart), opening it again records the interruption and re-arms, as it did before 1.3.2.

**Shipped in 1.4**

A clearer record of what happened, and more useful alerts on your other devices.

- Wrong disarm PINs leave their own event, with a front-camera photo when available.
- Home shows how many events are new since you last opened the log.
- Alerts name the device and the tripwire. Vision-only alerts arrive quietly; tamper alerts are Time Sensitive and can get through a Focus when allowed.
- With Pro, “Last heard from” shows the latest heartbeat from another armed iPhone. Heartbeats are sent every five minutes while the app can run and reach iCloud.
- Changes to protection settings and serious or critical heat while armed leave records in the log.
- When Malinois detects that iCloud copies were deleted in Settings, it can restore locally retained records after confirming the same account. (Pro)
- With Guided Access enabled, the screen stays awake for ten minutes while disarmed to give you time to get ready.

This update also improves clip audio when Sound detection is enabled, explains partial camera captures while preserving successful evidence, clarifies iCloud Photo & Video Storage, and fixes several event-log and recovery issues. Touch detection is always enabled while armed.

**Shipped in 1.5**

More reliable event history and iCloud syncing.

- Incident history now has its own space: up to 500 incidents and 100 recent status entries, so routine arming and settings changes no longer crowd incidents out of the Event Log.
- Fixed the new-event count sometimes needing a second Event Log visit to clear.
- Signal-loss alarms now leave their own entry in the Event Log.
- Improved reliability when saving captured evidence and managing older iCloud media.
- Improved syncing of capture-failure explanations between devices, and fixed downloads overwriting newer event information. (Pro)
- Heartbeat records now include the phone’s temperature status. (Pro)
- Automatic iCloud storage cleanup can trim eligible old heartbeat history while keeping the latest heartbeat from each watch. Manual and Keep forever settings are respected. (Pro)

**Shipped in 1.5.1**

Stronger protection for your PIN and iCloud evidence, and more accurate camera captures.

- After updating, verify iCloud access once in Settings → iCloud with Face ID, Touch ID or your passcode. Until then, monitoring and on-device evidence keep working, but iCloud sync is paused.
- Your Malinois PIN is kept if you delete and reinstall the app. Replacing a forgotten PIN requires Face ID, Touch ID or your device passcode.
- The Event Log separates events held on this device from uploads that can be retried, explains why an event is held, and lets you hide the held-events banner until something changes.
- Camera captures have their own time limit, clips show their real length, and partial recordings say so.
- Alerts on your other devices are now generic: they no longer read event details from iCloud, so they don't name the device or sensor, and Vision-only alerts use the normal alert sound. (Pro)
- Turning off cross-device alerts requires Face ID, Touch ID or your passcode. (Pro)
- Home shows the Pro badge for both purchased and Early Access Pro.
- During routine iCloud checks, Home now says “Checking iCloud for new events” instead of “Restoring your event log”.

**Shipped in 1.6**

Glotfelty Edition\
Apple Watch alerts, a PIN pad that submits itself, and clearer records.

- New Apple Watch app: tamper and disarm alerts arrive on your wrist, even when the armed iPhone is the one your watch is paired with. Open Malinois on the watch once to turn it on. (Pro)
- Tamper alerts break through Focus and Sleep again, on iPhone and Apple Watch.
- The PIN pad submits as soon as you've typed your PIN, with no check mark to press. Your first entry after updating, and any retry after a wrong PIN, still use check mark.
- New PINs are 4 digits by default, with 6 available. A PIN that is easy to guess, like 1234, shows a warning, and setup suggests a code different from your iPhone and Guided Access passcodes.
- The arming screen and countdown show more clearly how to disarm, and on a new install the warning screen shows it too, until your first disarm.
- Arming without Guided Access now warns that anyone who picks up your iPhone can leave Malinois and use it, so stay nearby.
- If the Sound tripwire's microphone stops working while armed, the Event Log now says so, and again when it works.
- Fixes: Sound no longer gives a false alarm when the microphone comes back after an outage; a photo or clip that finishes late uploads right away; with both cameras, your other devices now show the second camera's evidence when it arrives after the first; prices show in your own currency.
- Images are checked before they're opened, so a damaged or oversized file can't overload the app.
- The Face ID permission text now lists every use of Face ID in Malinois.

**Shipped in 1.7**

A switch for iCloud backup, a record of clock changes, and screens that fit small displays and large text.

- New iCloud backup switch in Settings → iCloud, for when you want evidence kept only on this iPhone. Turning it off needs Face ID, Touch ID or your passcode and leaves an entry in your log. Events recorded while it is off stay on this iPhone, even after you turn it back on. Your paired Apple Watch still gets this iPhone's alerts directly; your other devices don't while it is off. (Pro)
- When the clip storage is full, a clip now fails at once with its own reason and a notice on Home, instead of starting the camera and recording nothing.
- A change of the device clock by a minute or more while armed is now recorded in the Event Log.
- The Event Log's size limit never removes an event while it is uploading, and the log says so if events not fully backed up to iCloud had to be removed to make room. (Pro)
- Home and PIN setup now scroll on small screens, such as the outer display of iPhone Duo, and with large text, instead of cutting text off.
- The newest iPhones, including iPhone Duo and iPhone 18 Pro, show their names as the default device label.
- The Face ID permission text now mentions turning off iCloud backup.
- With iCloud backup off, Home and the arming screens now say so. (Pro)
- Warnings found when you tap ARM, such as a camera that could not start or clips that will have no sound, now show on the arming screens before you walk away, not only on Home afterwards.
- On a charger or in Instant mode, where the camera starts when you tap ARM, the REC badge now shows on the arming screens too.
- Taps on the armed screen are recorded even after iOS interrupts a touch, for example during the Guided Access triple-click.
- Saving a photo or clip from Share now asks once for permission to add it to your photo library.
- If the event log can't be read, the copy set aside is now kept with its photos and clips, instead of being deleted after 30 days.

**Shipped in 1.7.1**

Fixes for two rare timing problems found in a review.

- If Malinois was interrupted while saving an event, for example by a forced restart, the next event it recorded could be lost if the phone was interrupted again a moment later. It is now kept.

- Entering your PIN to stop an automatic re-arm at the very moment calibration ended could leave the sensors, and with some settings the camera, running, and make Malinois re-arm itself the next time it opened. It now stops cleanly.

**Exploring**

- **Hardware-key disarm** — disarm with a YubiKey-class security key over NFC or USB-C. Proven on our test devices; whether it ships depends on whether people ask for it — support@ is how you ask.
