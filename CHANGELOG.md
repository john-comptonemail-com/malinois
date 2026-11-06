# Changelog

What each App Store release of Malinois changed, newest first. The current release is under What's new in the [README](README.md).

**Shipped in 1.10**

- Your iPhone now signs its event records, so someone you share an event with can check it has not changed since the phone signed it. The signing key stays in the iPhone's Secure Enclave, and Apple's App Attest service certifies it belongs to Malinois on a genuine iPhone; that needs a network connection once, and again after a restore. Events recorded before then are not signed. If a signed record ever leaves the log other than by its size limit, the log says so.
- Sharing a signed event adds a ZIP of its evidence, which anyone with a Mac can check with Malinois's verifier, built from the app's public source code.
- After you restore your iPhone from a backup, you can again download the full evidence of your restored events from iCloud.
- On Apple Watch, an iCloud check that takes longer than 20 seconds now ends and says so.
- Also: after an interruption or a camera error, the camera no longer restarts while a capture is still under way; changing the time on your iPhone no longer upsets the motion and Sound tripwires' trip checks; and the cleanup of old events in iCloud names each event only once.

**Shipped in 1.9**

- Malinois now requires iOS 18 or later. The Apple Watch app still runs on watchOS 10 or later.
- Fixes a crash at startup on iOS 18 when Malinois's saved data was damaged.
- A clip that iOS ends on its own, when storage runs out for example, now stops at once and is marked partial, and a clip still waiting to be saved is no longer removed at launch.
- Turning cross-device alerts off no longer reports success unless iCloud confirms that every alert subscription was removed.
- Also: a thumbnail that arrives late now shows on your other devices; a stalled iCloud request no longer holds up later upload retries; your other devices stop offering to download a capture whose iCloud copy is gone; recovery after an interrupted watch is more reliable; and leftover temporary upload images are cleaned up at launch.

**Shipped in 1.8.2**

- In Siren mode the siren now plays from the iPhone's own speaker even with headphones, AirPods or a Bluetooth speaker connected; iOS may show its orange microphone dot while it sounds, though nothing is recorded.
- Once three tamper alerts arrive within a minute, the rest of that burst arrive quietly, on Apple Watch too.
- The Event Log now records changes to more settings, how long monitoring was interrupted, and a skipped automatic re-arm; countdowns cancelled in a row count as one record, with one alert.
- A clip's thumbnail now shows a frame near the biggest change in its first 12 seconds, rather than always the frame 1 second in.
- Also: an earlier warning with Until clear, a warning when arming an iPhone without a passcode, the "Allow notifications" offer as soon as you verify iCloud access, reliability fixes for uploads, alarms and Apple Watch alerts, and clearer wording about Guided Access and iCloud backup.

**Shipped in 1.8.1**

- ARM asks for your PIN when it has not been entered for 14 days.
- The one-time screen before your first arm also asks you to turn Voice Control off, and the arm is cancelled after a minute without a touch.
- On a second device, Home offers "Allow notifications" right after you verify iCloud access.
- The log now records a stalled motion tripwire, a reinstall, a PIN change, and Guided Access ending during a watch.
- Face ID unlock for the Event Log is tied to the faces or fingers enrolled when you turn it on; if they change, it turns off until you turn it on again.
- If Malinois opens before your iPhone's first unlock after a restart, it waits for your settings instead of using defaults.
- A clip that keeps uploading is no longer cut off; only an upload that has stalled is.
- A momentary failure to look up your iCloud account no longer pauses uploads or clears your verification.
- In Siren mode the alarm sounds even if the camera is slow to give up the microphone, and Malinois does not re-arm itself while a PIN recovery is pending.
- Evidence pushes ask iOS for extra running time from their first step, so a lock right after a trip is less likely to cut them off.
- Two rare fixes: a damaged lockout value can no longer lock the PIN pad for good, and an interruption at the moment the app leaves the screen can no longer go unrecorded.

**Shipped in 1.8**

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

**Shipped in 1.7.1**

Fixes for two rare timing problems found in a review.

- If Malinois was interrupted while saving an event, for example by a forced restart, the next event it recorded could be lost if the phone was interrupted again a moment later. It is now kept.

- Entering your PIN to stop an automatic re-arm at the very moment calibration ended could leave the sensors, and with some settings the camera, running, and make Malinois re-arm itself the next time it opened. It now stops cleanly.

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

**Shipped in 1.5**

More reliable event history and iCloud syncing.

- Incident history now has its own space: up to 500 incidents and 100 recent status entries, so routine arming and settings changes no longer crowd incidents out of the Event Log.
- Fixed the new-event count sometimes needing a second Event Log visit to clear.
- Signal-loss alarms now leave their own entry in the Event Log.
- Improved reliability when saving captured evidence and managing older iCloud media.
- Improved syncing of capture-failure explanations between devices, and fixed downloads overwriting newer event information. (Pro)
- Heartbeat records now include the phone’s temperature status. (Pro)
- Automatic iCloud storage cleanup can trim eligible old heartbeat history while keeping the latest heartbeat from each watch. Manual and Keep forever settings are respected. (Pro)

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

**Shipped in 1.3.3** — a fix: after Malinois is ended while armed (a crash, the app being closed, a restart), opening it again records the interruption and re-arms, as it did before 1.3.2.

**Shipped in 1.3.2** — the rest of the September review fixes: the record comes first (a jamming blackout or a sustained flood is logged before the alarm), fewer stray records, and fixes for clips and the camera; and the Event Log's sync spinner now stays up until every record has reached iCloud.

**Shipped in 1.3.1** — the fixes from the September review pass: a cancelled countdown leaves a record and alerts your other devices, the Side Button coaching for Guided Access, and the app now says when its own log or journal is in trouble.

**Shipped in 1.3** — honest capture-interruption records: a capture that produced nothing now says why, on the event itself.
