# Security and privacy — Malinois

<a id="security-model--malinois"></a>

This document describes **Malinois 1.7.1 (71)**. Start with the practical guide below.
The [technical reference](#technical-reference) contains the implementation details
and design rationale for security reviewers and maintainers.

Use Malinois only on your own device. It is intended to help you notice and record
someone handling your unattended phone, not to monitor other people without their
knowledge.

<a id="contents"></a>

## Start here

- [What Malinois is designed to protect](#what-malinois-is-designed-to-protect)
- [What to enable before leaving your phone](#what-to-enable-before-leaving-your-phone)
- [What happens when a sensor triggers](#what-happens-when-a-sensor-triggers)
- [Your PIN, Guided Access and device authentication](#your-pin-guided-access-and-device-authentication)
- [Where events and recordings are stored](#where-events-and-recordings-are-stored)
- [iCloud verification and recovery](#icloud-verification-and-recovery)
- [Limits to understand](#limits-to-understand)
- [Report a security issue](#report-a-security-issue)
- [Technical reference](#technical-reference)

## What Malinois is designed to protect

Malinois is designed for an unattended, unlocked iPhone that someone might pick up,
unplug, move or otherwise disturb. Enabled sensors can trigger an event, a camera
capture attempt and the response you selected.

The event log helps you review what the phone detected. Depending on your settings,
an event can include the time, triggering sensors, sensor measurements, and a photo
or video. An event and its recording are separate: a sensor can detect activity even
when the camera cannot produce usable footage.

Core motion, power, proximity and touch detection, local capture, the PIN-protected
log, and the siren are available without Pro. Pro adds iCloud evidence storage, cross-device
alerts, the Sound and Vision tripwires, and additional camera options. An expired
trial does not delete your saved settings or turn off the core free protections.
See [Free and Pro](#protection-tiering-free-vs-pro) for the full entitlement rules,
including Early-Access Pro.

The app's intended use is distinct from protection against a compromised operating
system. The [threat model](#threat-model) describes the assumed attacker capabilities
and the boundaries attached to each credential.

## What to enable before leaving your phone

**Use Guided Access.** This is Apple's feature for keeping the phone in one app.
Malinois normally requires it before arming. The first arm on a fresh installation
has an automatic one-session exception; you can also choose a one-session exception
from the arming screen. That exception does not switch off the saved requirement.
While an arm goes ahead under it, the arming screen and countdown warn that anyone who
picks up the phone can leave Malinois and use it unlocked.

In Guided Access options, disable the Side Button (called Sleep/Wake on some devices)
so a normal button press does not lock the screen and suspend the watch. In Siren
mode, disable Volume Buttons too. Turn off Voice Control before arming: its command
to close an application has been observed to close Malinois even under Guided Access.

**Choose the sensors, camera and response you need.** Wait for the countdown and
calibration to finish. Monitoring begins when calibration finishes, including while
the brief calibration-complete screen is still visible. The earlier countdown and
calibration are not a live watch.

**Check cloud and notification status separately.** For Pro cloud features, complete
iCloud verification on the installation. A device receiving alerts needs notification
permission. A working cloud connection does not by itself mean that another device
can display an alert.

**Understand the camera's power setting.** In Auto mode, charging keeps the camera
ready. On battery, Auto uses a cold camera, which adds startup delay and does not
supply continuous frames to Vision. A live camera displays the REC badge and iOS's
camera indicator. Sound monitoring uses the microphone; iOS shows its microphone indicator, with the
green camera indicator taking precedence while the camera is live. Metering alone
does not save an audio recording.

## What happens when a sensor triggers

The app first attempts to save an event record. For eligible Pro events, it begins
uploading the small event-details record before camera capture. Photos, videos and
thumbnails follow separately. This gives the event details a head start; the
[upload reference](#evidence-integrity) explains the delivery limits and retry rules.

If another sensor triggers during a capture, its activity can join the same event.
Rapid repeated triggers can be combined into a sustained-activity record, with
further capture attempts at a limited rate. Several triggers therefore do not
necessarily produce several separate rows or videos.

Your response setting controls the normal on-device reaction. Alert, the default,
shows a silent warning. On a new install the warning also shows how to disarm until
your first disarm; after that it never does, so a later intruder is not told. Siren mode uses photos instead of clips so capture does not
take over the audio needed for the alarm. Its optional volume ramp gives you time
to disarm before the alarm reaches full volume.

When a capture fails, look in the event details for a recorded reason. The
[detection and camera reference](#detection-reliability) explains interruptions and
partial recordings; the [recovery reference](#resilience-notes-added-after-red-team-review)
explains when a failed capture gets another attempt. A clip's displayed length is based on the
returned movie rather than just the requested duration.

## Your PIN, Guided Access and device authentication

These are separate controls. Knowing one does not make it interchangeable with the
others.

| Control | What it is used for |
|---|---|
| **Malinois PIN** | Disarming, opening Settings and protected app screens, and ordinary PIN changes. |
| **Guided Access passcode** | Ending Apple's restriction that keeps the phone inside Malinois. |
| **Face ID or Touch ID for viewing** | Optional access to the Event Log and Test Sensors. Settings and ordinary disarm remain PIN-only. |
| **iOS device-owner authentication** | Explicit PIN recovery, iCloud verification, turning off account-wide cross-device alerts, and turning off iCloud backup. This may use Face ID, Touch ID or the device passcode. |
| **Apple Account / iCloud access** | The account in which CloudKit stores the cloud copies. Malinois also requires its own installation verification. |

Repeated incorrect Malinois PIN entries cause increasing delays. The failure count
survives closing the app. This can also delay the owner's access after someone else
has guessed incorrectly. The [PIN reference](#pin-disarm--evidence-access) explains
storage, recovery and the exact lockout rules.

From 1.6 the PIN pad submits once your PIN's last digit is typed, as the iPhone's passcode
does; each such entry counts as an attempt, exactly like the ✓ it replaces, so the PIN's
length is not secret. After a wrong entry, ✓ returns for the rest of that entry, so a
stored length that is ever wrong cannot keep the real PIN from being entered. New PINs are
4 digits by default, with 6 available; a PIN that is easy to guess draws a warning, and the
setup screen advises a code different from the iPhone passcode and the Guided Access
passcode, so one code learned over a shoulder does not open all three.

Reinstalling does not authorize clearing a surviving Malinois PIN. You can use that
PIN to restore local access, or choose **Forgot PIN?** and complete device
authentication before selecting a replacement. Cancellation, backgrounding during
recovery, or a failed save does not complete the reset. Restoring local access does
not separately verify iCloud.

The [detailed threat model](#threat-model) explains how credential and client access
affect local and cloud evidence.

## Where events and recordings are stored

**On this device:** the log and saved media use iOS file protection. The local log
has separate limits of **500 incidents** and **100 recent status entries**, such as
arming, disarming and settings changes. Saved media also has a shared limit of
approximately **2 GB**. Retention can remove records or recordings as these limits
are reached. The [storage reference](#evidence-at-rest) explains removal order and
which losses are reported.

There is no individual-event Delete button in Malinois. That UI rule is different
from automatic retention. It also does not prevent deleting the app through iOS;
app deletion removes its local container.

**In iCloud, with Pro:** event details and thumbnails can be restored, and full
photos or videos can be downloaded from an event's detail screen, subject to account
verification and availability. Cloud copies have a separate retention policy from
the local log.

**Stopping uploads (1.7):** Settings → iCloud → **iCloud backup**, on by default, changeable
only while disarmed. Turning it off needs iOS device-owner authentication. A "backup turned
off" status entry is recorded first and queued for upload: it is the one record that still
uploads while backup is off, retried like any other, so the cloud log shows when once it
reaches iCloud (a phone offline at the time sends it later, and devices running a version
before 1.7 do not show it). While off, this phone starts no other upload: events, media,
status entries and heartbeats stay on it. The switch is checked before every step of an
upload and every retry, so an upload under way when it is turned off stops at its next step;
a file CloudKit has already accepted stays there. While off, this phone's events raise no
iCloud alerts on other devices, while theirs still arrive; a paired Apple Watch still gets
this phone's alerts directly from it, without iCloud. An event recorded while backup was off
stays on this phone for good, even after backup is turned back on: it is marked, and also
registered to no iCloud account, which keeps it on the phone even if an older version of
Malinois is installed over this one. Events recorded before it was turned off upload when it
is back on. Existing iCloud copies are not deleted. Turning Malinois off for iCloud in iOS
Settings also stops uploads, but what was recorded meanwhile uploads when it is back on.
While backup is off, Home shows it in orange in place of its iCloud row, and the Guided Access
step and the countdown say it before each arm (1.7 (70)). ADR 0047.

The cloud storage setting can keep full media indefinitely, clean it up manually,
or remove it automatically after the selected age. App cleanup preserves event
details, thumbnails and audit records. Automatic cleanup also trims eligible old
heartbeat trails while keeping each watch's latest heartbeat. The policy has a
30-day minimum age, with conservative server-time checks; see
[Cloud storage and retention](#cloud-cloudkit) for the exact rules and exceptions.

**Cloud privacy and alteration:** Malinois uses encrypted CloudKit fields and media.
Apple's Advanced Data Protection setting determines whether those fields and media
receive end-to-end protection. Record identifiers, types and server timestamps still
reveal activity and timing. See [Encryption and backups](#encryption-and-backups).

The absence of an individual-event Delete button does not make cloud records
immutable. A developer with appropriate container access can inspect and alter their
own private records through Apple's tools; an unrelated developer account does not
by itself grant access to Malinois's container or another person's private data.
See [Cloud access and integrity](#cloud-cloudkit).

On the free tier, Malinois does not upload evidence to its CloudKit storage.
**Local-only** describes that upload behavior; device backup settings may create
additional copies of local app data.

## iCloud verification and recovery

Each installation must verify access to its iCloud account using iOS device-owner
authentication. Pro access, choosing a new Malinois PIN, or finding an old PIN in
the Keychain does not grant this cloud permission. Until verification succeeds,
local monitoring remains available and cloud operations stay paused.

Events have different upload states:

| Event state | What it means |
|---|---|
| **Eligible but waiting to upload** | An event associated with the verified account could not upload yet, for example because the phone was offline. It can be retried. |
| **Kept on this device** | The Event Log explains why this event is held separately from ordinary upload retries. Unknown or different account bindings are examples. |
| **Synced** | The upload completed. A previous successful upload is not proof that the remote copy still exists today. |

Verification does not silently adopt records whose original account is unknown.
For example, an event with an unknown original account stays local after verification;
a new event bound to the verified account can be submitted for upload. This does not
make every hold permanent: a temporary verification pause is a different condition.

Account changes invalidate pending cloud work, and stale results must not be
attached to the local log. Work already accepted by the server cannot be recalled.
The [cloud reference](#cloud-cloudkit) describes these checks and the existing
cloud-deletion detection and recovery conditions.

Cross-device notifications use generic tamper and disarm text. The notification
extension does not fetch private event details. From 1.6 an Apple Watch on which Malinois
has been opened once shows the same alerts: from your other devices through iCloud, and from
its own iPhone straight over Bluetooth or shared Wi-Fi, and in testing also with the watch on a
different network from the phone. It reads no event records. On Pro, a watch with verified cloud
access and a matching account binding attempts a heartbeat every five minutes.
Another device can show when that watch was last heard from. Failed heartbeats are not uploaded later; a gap can reflect a connection
problem and is not proof of tampering.

## Limits to understand

- **The app needs to keep running in the foreground.** A locked, suspended or stopped
  app is not continuously monitoring. Guided Access helps keep it on screen.
- **Sensors have thresholds and pauses.** Small or slow changes can be missed. Sound
  pauses for clips that record audio and while the siren uses audio. Vision needs a
  live camera and pauses comparison around capture and recovery. Proximity pauses
  during PIN entry; PIN keypresses do not count as touch trips.
- **Recording quality depends on the scene and camera.** Darkness, camera coverage,
  startup delay and interruptions can limit the usefulness of a capture.
- **Network loss can delay or prevent off-device preservation.** A connectivity
  warning identifies observed signal loss or failed delivery, not proof of a jammer.
  An ordinary outage can resemble interference.
- **Restart, power loss and iOS failures can end a watch.** Later interruption records
  depend on the app running again. Automatic re-arming has its own countdown and guards.
- **Some failures have no owner notice.** A Sound microphone that stays down for 30
  seconds of a watch leaves a status entry (1.6), but the source describes other sensor
  failures that produce neither an event nor a warning. Storage failure can also prevent saving an
  event, and a notification attempt does not guarantee delivery.
- **Retention and deletion can remove evidence.** The local and cloud copies have
  different limits and controls; neither should be treated as an indefinite archive.

For the detailed boundaries, including a compromised device, siren volume, wired
accessories and Guided Access exceptions, see [Known limitations](#non-goals--known-limitations).

<a id="reporting"></a>
<a id="reporting-a-vulnerability"></a>

## Report a security issue

Email **support@comptonemail.com**. Do not open a public issue containing sensitive
security details. Include the app and iOS versions, the steps that reproduce the
problem, what you expected, and what happened instead. Name relevant source files
if you know them; you do not need to read code to report a problem.

Reports receive an acknowledgement. Fixes ship through the App Store, and this
repository mirrors the source for each shipped release.

<a id="defenses"></a>

## Technical reference

The sections below give the detailed design explanations, operating limits and
review history. Expand the topic you need.

**Terms used in the reference:** *first-hand* means recorded on this device;
*mirror* means a copy downloaded from iCloud; *metadata* means event details rather
than the full photo or video; *exfiltration* means uploading evidence off the phone;
*coalescing* means combining repeated triggers; *fail closed* means refusing the
operation when its required authorization or safe state cannot be established.

<a id="the-model-on-one-page"></a>
<details>
<summary>Detailed overview and protection boundaries</summary>

**Threat:** someone with brief physical access to your unattended, unlocked iPhone —
picking it up, unplugging it, plugging it into a computer, searching around it, or
trying to power it off before the evidence escapes.

**Adversary tiers:**
- **Tier 1 — opportunistic snoop or thief, no credentials.** The design target,
  subject to sensor coverage, foreground execution, storage and delivery limits below.
- **Tier 2 — someone holding one of the owner's credentials.** Bounded outcomes: a PIN
  holder can stop *future* monitoring. The app has no individual-event delete control;
  storage limits and cloud cleanup can still remove eligible records or media. Handling
  normally triggers a capture attempt, subject to camera settings and availability;
  a Guided Access passcode holder can close the app; on a later launch Malinois attempts
  an interruption record and, when authorized, a cross-device notification. With the
  device in hand and unlocked, that passcode holder can wholesale-delete the cloud copy
  from iOS Settings. An iPhone passcode holder can force-restart the armed phone, which
  ends Guided Access and the watch, unlock it, and after reinstalling Malinois set a new
  Malinois PIN and verify iCloud with that passcode alone; the handling before the
  restart is normally recorded and, online with iCloud backup on, sent, but the reset
  raises no alert on the owner's other devices. Access to the iCloud account can also enable wholesale deletion.
  The local log is not removed by that cloud deletion. This ordinary storage control
  is not an individual-record editor; it does not make the cloud records immutable.
  There is no immediate deletion alert. On a later launch, missing-record checks can
  report the loss and requeue eligible records still held locally, subject to account
  verification. An encrypted-data reset can also start recovery after an authorized
  write reports the relevant error. Recovery cannot recreate records no device retains.
  What the local log does **not** survive is the app being deleted from the unlocked home
  screen — no credential beyond reaching that screen, no record left behind; Guided Access
  is what keeps a snoop from the home screen, and iOS's Screen Time restriction on deleting
  apps can deny it outright (README, *Enable it*). A Pro cloud copy that still exists can
  be restored after reinstall and cloud verification.
- **Tier 3 — compromised devices and advanced tooling.** Outside the guarantees.
  A professional handling an otherwise intact phone may trigger it, but there is no
  assured ordering between detection, upload and compromise.

**Implemented protections and their limits:**
1. **Monitoring is maintained with sensor-specific pauses.** Proximity pauses during
   PIN entry, and PIN keys are not touch trips. Sound pauses for clips recording audio
   and while the siren owns audio. Vision requires a live camera and temporarily suppresses comparison around
   capture startup, interruption and resettling. The countdown and calibration are not a live
   watch. A rearm or watchdog is not proof of continuous sensor health.
2. **The event precedes the response.** The app attempts to journal the event before
   alerting and attempts metadata upload before camera capture for eligible Pro events
   with verified cloud access and matching account bindings. Write failures,
   shutdown and network conditions can still prevent preservation or delivery.
3. **No individual-event delete action in the UI.** Retained records gain annotations,
   but retention can remove records and media, including pending evidence under pressure.
4. **Recording is always indicated** (the REC badge and iOS's camera dot; with the Sound
   tripwire on, iOS's microphone dot for the whole watch) — covertness has a deliberate,
   non-negotiable bound.
5. **Failure reporting.** Interrupted sessions, refused uploads, degraded persistence
   (a full disk, a quarantined log, a journal that cannot be written), and silent-clip
   conditions (a denied microphone, one that could not be attached) all surface to the
   owner when the relevant detection, storage and presentation paths succeed. A Sound
   tripwire whose microphone worked and then stays down for 30 seconds of a watch leaves a
   quiet status entry, and another when it works again (1.6; at most three outages a
   watch). A device clock moved by a minute or more during a watch leaves a quiet status
   entry naming the jump (1.7): event times and the log's order come from the device clock,
   and the entry explains a change without correcting them. The clock is compared while the
   app runs, so a change made while iOS had ended the app is not recorded. This does not cover every failure: other sensor restarts and persistent
   sensor-health failures have no event record or owner notice. Recording attempts,
   durable storage and delivered notifications are separate outcomes.

**Honest limits:** a hardware force-restart can be raced but not blocked; no network at
trigger time can prevent upload; a compromised OS is out of scope. Free-tier evidence
is not uploaded by Malinois, but device backups may contain local app data.

Passages marked **Design note** record *why* something is built (or deliberately not
built) the way it is — skip them on a first read; return to them before proposing changes.

</details>

<a id="threat-model"></a>
<details>
<summary>Threat model and credentials</summary>

**Who:** an opportunistic snoop or thief with brief **physical access** to your
unattended, unlocked iPhone while you're away from it. They can pick it up,
tilt/move it, unplug it (or **plug it into a computer** to pull data off it), make
noise near it, tap the screen, or try to power it off.

**What they want:** to handle or take the device without leaving a trace, and — if
they realize it's monitored — to destroy the evidence before it escapes the device.

**What we protect:** the *fact and evidence* of tampering — a timestamp, which
sensors tripped, sensor traces, and any successful photo/clip. The app attempts local
preservation and eligible Pro uploads before a later shutdown; neither capture nor
delivery before shutdown is guaranteed.

**Adversary tiers.** Three, each analyzed and *bounded* below:

**Tier 1 — the design target.** The opportunistic snoop or thief above, with
no credentials. The documented operating conditions and limits still apply.

**Tier 2 — credentialed insiders (in scope, with bounded outcomes).** A partner, colleague,
or repeat visitor who has obtained one of the owner's credentials. Each credential buys
something specific and leaves something behind (details in
[Non-goals](#non-goals--known-limitations)):
- **Malinois PIN:** can disarm, stopping *future* monitoring. There is no individual-event
  delete control. The PIN also opens cloud cleanup settings for eligible old media and
  heartbeat trails; automatic local retention is a separate source of removal. The app
  attempts a timestamped disarm record.
  Retention, app deletion before upload, or storage failure can remove that evidence. Detection continues
  during PIN entry, and the Touch tripwire has no switch (ADR 0015), so the hold that reveals
  the pad normally creates a Touch record and attempts capture unless the camera was switched off in Settings
  (which needs the PIN, and since 1.4 attempts a record of its own). On Pro with verified
  cloud access, an eligible account binding and cross-device alerts enabled, the app
  attempts to send the disarm notification. Connectivity and system delivery still apply.
  (Eligible disarms that could not be sent while offline can be retried later; among such late disarms one alert is raised per upload pass, for the newest,
  so a backlog does not raise one alert each.) The PIN also opens Settings: a PIN-holder can weaken the *next*
  session's configuration — every tripwire but Touch, the camera, the Guided Access
  requirement and the jamming response. Turning off account-wide cross-device alerts
  additionally requires fresh device authentication. Since 1.4 such changes attempt
  an audit record ("Camera switched off in Settings"), written when Settings closes or,
  if not recorded then, at the next arm. The first launch remembers the existing configuration
  before Settings can edit it, without inventing an audit row; later launches preserve that
  baseline so an unreported change is still caught (ADR 0019). On Pro the audit records follow
  the usual verified, account-bound iCloud upload path. Only those settings leave a record (the
  tripwires, the Guided Access requirement, cross-device alerts, the jamming response; iCloud backup
  has its own entries). Sensitivity, the response mode, illumination, the battery mode, the grace
  period, Face ID unlock and the cloud storage setting change with no record, so a PIN-holder can
  make the next session less sensitive or silent without a trace in the log. A PIN-holder can still
  weaken the configuration; these audit attempts help make changes visible but can fail.
- **Guided Access passcode:** can close the app. On the next eligible launch, the app
  attempts a "Monitoring interrupted — the app was closed or crashed while armed"
  record and an authorized Pro notification. These need successful storage and delivery. Evidence already pushed has already escaped. It also
  exposes the ordinary on-device storage control for the cloud copy: with Guided Access ended and the device
  unlocked, iOS Settings → iCloud → Manage Account Storage offers **Delete Data from
  iCloud** for this app, with no Apple ID password asked (verified on device).
  That deletion is the same wholesale loss described under iCloud credentials below —
  it removes the app's cloud data rather than editing an individual event. It does not cause an immediate alert; a later eligible launch
  may detect missing records and report recovery. It does not reach the
  other devices' local copies of what they had already mirrored, nor this device's own log.
- **iPhone passcode:** a forced restart, which nothing can block (*Non-goals*), ends Guided
  Access and the watch, and the passcode then unlocks the phone. With it, someone can delete
  and reinstall Malinois, which removes the local log with the app, then choose a new
  Malinois PIN with **Forgot PIN?** and verify iCloud access: both accept the passcode as
  device authentication (ADR 0040, ADR 0039). That opens the iCloud copy of the evidence, the
  cross-device alerts and iCloud backup switches, and iOS's **Delete Data from iCloud** for
  the app. What happened before the restart is normally recorded and, on Pro with iCloud
  backup on and a connection, uploaded with its alert; the PIN reset and the new installation's verification
  raise no alert on the other devices, and the heartbeat's silence raises none either (ADR
  0020). A Guided Access passcode different from the device passcode stops this person from
  ending Guided Access on the screen, not from forcing a restart. Without the passcode, a
  forced restart leaves the phone locked.
- **iCloud credentials and authorized clients:** ordinary iCloud.com and iOS storage
  controls do not provide an individual-record editor for Malinois. Account access
  can enable wholesale deletion, including an encrypted-data reset; on an unlocked
  device, the per-app **Delete Data from iCloud** control needs no further password
  (see the Guided Access bullet above). These UI limits are not guarantees against
  selective alteration by an authorized client. Apple documents inspecting, editing
  and deleting one's own private records through its developer tools when the
  developer has access to the relevant app container. An unrelated developer account
  does not by itself grant that access or access to another person's private data.
  [Apple's container-data documentation](https://developer.apple.com/documentation/cloudkit/handling-an-icloud-container-s-data).
  An encrypted-data reset can trigger recovery when an authorized write reports the
  relevant error. The ordinary storage-settings deletion
  path raises no corresponding zone-removal error (the app writes to the default zone, which such a deletion empties but
  does not remove), so since 1.4 the app looks: at each launch it asks iCloud for its newest
  records that went up, by name, and when most are gone it can requeue eligible local
  records for upload and say so on Home. Cloud verification and account checks apply;
  requeueing does not mean that the subsequent upload has succeeded. It does so only while the device is signed into the account those
  records went to (remembered the first time it found them in place); under another account it
  declines that recovery requeue and says so. Since 1.5.1 ordinary uploads are bound as
  well: each event carries the account it was captured under, and evidence whose account
  is unknown or different stays on this device instead of uploading to the signed-in
  account (ADR 0039; *Installation enrollment* under Cloud). Until the next
  launch, and on a device that never held the rows, the loss shows only to someone who consults
  the cloud copy. Missing records indicate loss, not its cause. An authorized client
  capable of writing the account's records could also submit fabricated records.
  Malinois treats downloaded records as clamped, labeled mirrors: never
  superseding first-hand evidence, timestamps believed at most a day ahead of the
  record's own server stamp, and first against the retention cap. Insertion buys
  distraction in the log, not reach into the on-device record (fourth pass, R2-F3 +
  R3-4).

**Tier 3 — professional adversaries (outside the guarantees, stated honestly).** The
realistic top of this app's threat ladder is not a government — it is the private-sector
surveillance industry: investigators and private-intelligence firms working a divorce, a
custody dispute, a lawsuit, or corporate espionage, with budgets for commercial spyware and
device-forensics tooling. Malinois does not claim to defeat this tier; here is where the
lines fall:
- **An intact phone can still detect ordinary handling.** The same tripwires apply
  regardless of the person's occupation or equipment. That is not a defense against
  spyware or forensic compromise: physical handling is not a prerequisite for every
  compromise, and detection or upload need not finish before monitoring is defeated.
  Already-uploaded evidence may remain available, subject to the cloud boundaries below.
- **What fails: the device itself.** Spyware or an exploit with sufficient access can
  read local evidence and app memory, and may alter the local record. A compromised
  device is outside Malinois's guarantees, including any guarantee that its cloud
  copy cannot be altered. Existing cloud copies may remain available, but the app
  cannot promise they are beyond an attacker controlling an authorized client.
- **Credential theft:** the outcome depends on the credential and interface obtained.
  Ordinary storage controls permit wholesale deletion; access through an authorized
  cloud client can have broader consequences. The app's verification and account-binding
  checks are not cryptographic proof of a record's originating device or integrity. The
  same goes for alerts: any device signed in to the same Apple Account with Malinois can
  raise a genuine tamper or disarm alert on the owner's other devices, since an alert
  carries no proof of which device sent it.
- **Where the data lives:** local evidence uses iOS Data Protection as described under
  [Evidence at rest](#evidence-at-rest). Cloud fields, media and device backups have
  separate protection rules; see [Encryption and backups](#encryption-and-backups).
  Malinois does not require a particular ADP setting.

</details>

<a id="protection-tiering-free-vs-pro"></a>
<details>
<summary>Protection tiering: free vs Pro</summary>

*(A security-relevant invariant, not just a billing detail.)*

Malinois is monetized (a one-time Pro unlock, 30-day trial from first launch — though during
**Early-Access**, 1.3 onward until the owner closes it, every install has Pro free and
permanently, and the trial applies only to installs after that; ADR 0009), and the split is
drawn so that **the paywall never silently reduces protection**:

- **Always free:** all core detection (motion / power / proximity / touch tripwires),
  on-device capture, the PIN-gated local event log, the brute-force lockout, Guided
  Access support and its optional arming gate, the siren, the anti-flood/coalescing
  logic, and jamming detection's *local* go-loud response.
- **Pro only:** Malinois's CloudKit evidence uploads and restore, cross-device
  alerts, and additional capture options (multi-cam, 5s/until-clear clips, the Audio
  and Vision tripwires). Device backups are separate from these app features.

Two consequences matter for the threat model:

1. **Malinois's CloudKit evidence uploads require Pro.** The "two-shot exfiltration races a
   power-off" design below applies only on Pro (or in trial), and delivery can fail. A **free** or
   lapsed-trial device does not upload evidence through Malinois. If that device is
   taken or wiped, Malinois has no new cloud copy of those events to restore. Device backups may contain
   separate copies, but their completion and contents are not assured by the app.
   The app and trial-end notification state the loss of Malinois cloud protection.
> **Design note — the trial clock fails toward the user.** `trialActive` treats a
> backward-moved device clock as "still in trial" rather than expiring it early. That is a
> **revenue** edge, not a security one — the "attacker" is the owner, gaining only the
> upload of their own evidence to their own iCloud. The obvious fix (a wall-time
> high-water mark) is deliberately not taken: one accidental clock-forward excursion — a
> bad NTP sync, a child in Settings — would permanently burn a legitimate owner's trial.
> This is a trial-access decision, separate from the absence of cryptographic log
> authentication. Under Guided Access, Settings is unreachable anyway.

2. **Downgrade is never silent and never destructive.** A lapsed trial clamps
   Pro-only *behaviour* at use (`ProEntitlements`' `effective…` functions) but never
   mutates the user's saved settings or reduces core detection, and the UI surfaces
   every clamp (Home banners, the free-tier notices, the "trial ended, still
   protected" message). The security-relevant point: an expiring purchase cannot leave
   the owner *believing* they have protection they no longer have.

</details>

<a id="pin-disarm--evidence-access"></a>
<details>
<summary>PIN (disarm + evidence access)</summary>

- **What it gates.** A PIN, 4 digits by default or 6 (an existing 5-digit PIN keeps working),
  is required to **disarm** and to **view the event log**, so a snoop who reaches the app
  can't stop monitoring or delete evidence. Setting one that is among the easiest to guess
  (repeated digits, runs like 1234, repeated pairs, mirror images, keypad lines, years)
  draws a warning with "Use Anyway" (1.6); nothing is blocked. The setup screen also advises
  a code different from the iPhone passcode and the Guided Access passcode.
- **How it's stored.** As **PBKDF2-HMAC-SHA256, 120,000 iterations**, with a per-install random
  16-byte salt, in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`).
  The PIN itself is never stored. Comparison is constant-time.
- **Legacy hashes upgrade in place.** Hashes written by older builds (a single salted
  SHA-256) are verified, then upgraded to PBKDF2 on the next correct entry — no lockout,
  no reset. **Both hash generations depend on the stored salt, and verification is
  strictly read-only**: a lost or malformed salt fails closed and routes to
  device-authenticated recovery, rather than minting a replacement salt over the gap —
  which could never match, silently bricking the PIN (fourth pass, R1-M1).
- **Brute-force lockout:** after 5 failed attempts the pad locks with escalating
  backoff (30s → 1m → 2m → … up to **1 hour**, doubling — it keeps growing rather than
  plateauing, so a determined offline brute-force stays impractical). The counter lives
  in the Keychain, so **killing the app does not reset it**, and the remaining wait is
  measured against the **monotonic uptime clock, not the wall clock** — so moving the
  device's date forward can't skip it, and a reboot is a dead end rather than a bypass
  (the full argument is a few bullets down). A correct PIN clears everything — a
  property of `KeychainService.verify` itself, not of any screen. One honest consequence,
  stated so it reads as design rather than a bug: a snoop's failed guesses lock the pad
  for the **owner** too, siren included, until the backoff passes — the wait is the price
  of the brute-force defense, and it cannot be skipped by anyone, owner included.
  On the armed screen a failed attempt also attempts a **"Wrong PIN entered"**
  event with a front-camera still (whoever is typing faces it),
  eligible for authorized Pro upload and notification like any trip — the owner's own typos
  included; an attempt typed while a capture is still running joins that capture's record.
  The lockout itself is unchanged, the right PIN adds no record of its own (the "disarmed"
  audit record already stands), and the Home gate and the other PIN pads stay
  lockout-only (ADR 0014).
- **Durable writes.** Keychain writes **update in place** rather than delete-then-add,
  so a failed write (e.g. one attempted while the device is locked) can't destroy the
  PIN hash or silently reset the lockout counter. And "no hash on file" is only
  treated as first-time setup on a genuine fresh install: if setup was completed
  before but the hash is readably missing or malformed, re-setup is **gated behind device
  authentication**, so a stranger can't just set a new PIN and open the log.
- **A surviving PIN is kept across reinstall (ADR 0040).** Missing local setup markers
  or a missing event log never authorize deleting a PIN. Entering the existing PIN repairs
  setup. Its rate limit remains in force. “Forgot PIN?” explicitly requests Face ID,
  Touch ID, or the device passcode before a replacement can be chosen; ordinary disarm
  stays app-PIN-only. The old credential stays stored until the replacement succeeds.
  Cancellation, backgrounding, unavailable device authentication and failed writes do
  not complete recovery. No device passcode means device-authenticated reset is unavailable.
  Known prior setup or surviving local evidence without a usable PIN requires recovery;
  the journal, media and attachment intents count even when `events.json` is absent.
  Empty directories alone do not count; filesystem inspection errors take the conservative
  recovery route. Recovery does not delete evidence.
  Locked Keychain reads, unexpected errors and missing success payloads defer judgment.
  Only an explicit item-not-found result is absence. Verification does not count an
  unreadable credential as a wrong guess or mint a salt over it. A malformed hash or salt
  remains a recovery case, while a sealed component prevents classification entirely.
  Local PIN recovery does not itself grant permission to access cloud history.
  Debug builds expose a recovery preview inside authenticated Settings for cancellation
  checks. It uses the same device-authentication view, but success only updates the preview's
  message: it cannot reset the PIN, repair the setup flag, or unlock another screen. The
  preview and its entry point are compiled out of Release builds.
- **Design note — why a reboot is not a rate-limit bypass.** Two reviewers have now
  read the reboot note above and concluded that force-restarting clears an in-progress
  lockout and lets guessing resume, then proposed adding a *wall-clock* deadline alongside
  the uptime one. Both halves are wrong, so the reasoning is spelled out here:
  1. A reboot does clear the current *wait* (uptime is monotonic and resets at boot), but it
     drops the attacker at the **device-passcode prompt**, not at the Malinois PIN pad. After
     a restart iOS demands the device passcode before first unlock — biometrics don't apply,
     and `WhenUnlockedThisDeviceOnly` keeps the counter and the hash unreadable until then.
     A Tier 1 attacker doesn't have that passcode, so the cleared wait is unreachable by
     exactly the attacker it would benefit; one who has it (Tier 2) needs no guesses at all,
     since after a reinstall the passcode alone sets a new PIN. The failure *count* survives regardless, so even
     an attacker who could get back in faces a longer next lockout, never a shorter one.
  2. A wall-clock floor would be strictly **weaker**, not stronger: a wall deadline is skipped
     by moving the device clock forward, which is the F-09 attack the uptime clock was chosen
     to defeat. Adding it back would reintroduce a bypass that needs only Settings access, in
     exchange for defending one that needs the device passcode.
- **Design note — the iteration count.** A 4-digit space is only 10k candidates, so no
  KDF makes an offline crack "impossible" — PBKDF2 raises the per-guess cost, and the
  on-device lockout is the primary defense against online guessing.
- **Anti-observation (opt-in): scramble the PIN pad.** A snoop watching a disarm — the
  core anti-snoop scenario — could learn the PIN from finger *positions* alone, and fixed
  layouts also leak via smudge or thermal residue on the glass. An optional setting
  randomizes the disarm/gate keypad's digit positions on each presentation (✓ and ⌫ stay
  put; only digits carry information), defeating positional inference. It's **off by
  default**: it costs muscle-memory speed, which matters when disarming a sounding siren
  under stress, so it's the owner's choice. It composes with the pad's automatic submit
  (below). VoiceOver reads each key's digit,
  so scrambling doesn't harm assistive navigation.

</details>

<a id="evidence-integrity"></a>
<details>
<summary>Evidence integrity</summary>

- The **event log has no individual-event delete control** and is PIN-gated. This
  does not make it an indefinite archive: local storage budgets can evict events,
  and PIN-protected cloud cleanup can remove eligible old full media and heartbeat
  trails. The cloud cleanup floor does not protect local records from count or byte limits.
  (The Home button's event *count* shows without the PIN — a deliberate glanceability
  trade: it is the local count, which an iCloud-only attacker
  cannot change, and it reveals volume, never content. Since 1.4 it counts only the records
  that are new since the Event Log was last opened or closed, so only someone who can open the
  log can clear it: the PIN, or Face ID or Touch ID where the owner turned that on for the log.
  The acknowledgment happens before the authenticated navigation transition; cancelling a PIN
  prompt or receiving a late cloud result after closure does not clear unread records.)
- **Every screen that reveals configuration is PIN-gated too.** The Event Log, Settings, and
  *Test sensors* all sit behind the same gate. The owner may opt the two READ surfaces —
  the Event Log and Test sensors — into Face ID, or Touch ID on an iPhone SE (off by default);
  **Settings never accepts a face or a finger, whatever the toggle says**: it is a *write*
  surface (tripwires, response mode,
  cross-device alerts, the retention purge), and a presented face reconfiguring the
  protection posture is exactly what the boundary exists to prevent (eighth review, M1).
  Viewing is a convenience; the security boundary is unmoved: disarm, stopping a recovery
  re-arm, and ordinary PIN changes require the Malinois PIN. Explicit Forgot PIN
  recovery is a separate flow: device authentication can authorize a replacement,
  but does not separately grant iCloud access. Inside a Guided
  Access session the Face ID offer is skipped entirely and the pad stands with a caption:
  iOS defers the biometric sheet under GA without erroring, and pre-fix the
  queued request left the privacy cover over the pad — a fail-closed hang, but a
  dead-end. Test sensors records nothing, but it lists
  exactly which tripwires are enabled and renders their live thresholds — the same
  reconnaissance the Settings gate exists to deny — so gating the log and Settings while
  leaving it open would have been an inconsistency worth nothing to the owner and quite a lot
  to a snoop holding the disarmed device.
- **Design note — the outbound links.** The app's only links to the outside —
  Help & FAQ, the privacy policy, and the public source — sit at the foot of Settings,
  behind the PIN and reachable only while disarmed, so following one is harmless. Nothing on
  the armed screen can leave the app: under Guided Access that is precisely what the
  single-app lock exists to prevent, and a link there would be a door. The three
  destinations live in one place in the code (`AppLinks`), HTTPS on two pinned hosts, so
  they cannot drift from the App Store Connect entries or be quietly repointed; under
  Guided Access the section says that a tap will do nothing and offers copy-the-address
  instead.
- **Design note — no cryptographic log authentication.** A tamper-evident log chain
  was built and removed. Malinois currently provides neither that chain nor
  device-authenticated record signatures. The app has no individual-event delete
  control, and its cloud cleanup preserves facts and recent evidence, but those
  app policies do not make local or cloud records immutable. CloudKit account
  isolation does not prove which device created a record or that an authorized
  client has not altered it. Wholesale cloud loss can be noticed on a later check;
  absence alone does not prove tampering. Stronger record authentication would be
  a separate design change, not a property of the current app.
- **Retained first-hand facts and annotations.** The core facts of an event —
  `id`, `startDate`, `motionTrace`, `audioTrace` — are
  `let` properties in the event value. Other fields change during capture, coalescing,
  attribution and synchronization, including: `triggeredSensors` (flood coalescing folds later sensors into the open event),
  `endDate` and `sustainedCount` (how long the handling went on), and `ownerAttributed`
  (set when a correct PIN follows, so an owner disarm is *labelled* rather than removed).
  Storage caps can evict entire records. For records that remain, a re-downloaded full-resolution capture *attaches* media to an event, never
  replaces or removes anything — and that survives later refreshes: when a newer cloud
  copy supersedes a mirror, it inherits the locally-downloaded media reference rather
  than erasing it (eighth review, M3). Store updates as a class preserve monotonic
  fields: owner attribution and an advanced sync state can never be walked back by a
  stale in-flight copy (sixth review, F2 — ADR 0006).
- **Two-shot exfiltration** *(Pro)* races a power-off: the instant a tamper is
  logged with verified cloud access and an eligible account binding — for *every*
  capture mode, *before* the camera capture even starts — a tiny
  metadata record ("the fact") starts uploading at `.userInitiated` QoS; the full-res media (and a thumbnail) follow. Every push attempt is
  **deadline-bounded (20 s)**: a network path that *stalls* without failing — CloudKit's
  own resource timeout is measured in days — is cancelled and counted as a network-class
  failure, so a stall can neither wedge the per-event pipeline nor mute the
  observed-failure escalation by never technically failing (sixth review, F1). The
  account-status preflight ahead of each push is bounded the same way (10 s), so no step
  of the chain — check or write — can hang it (fourth pass, R3-1). The event is also queued for the on-device store before capture (an asynchronous write — a runtime persist failure raises a Home banner rather than passing silently, F6), so a successful event write can preserve the detection even if capture fails — and on the **free
  tier** that on-disk write is the whole story, since the iCloud pushes are Pro-gated
  (see [Protection tiering](#protection-tiering-free-vs-pro)). A still takes ~1 s to shoot
  and write and a clip far longer, so pushing the fact first (not just for clips)
  gives metadata a head start in every capture mode, without a delivery guarantee. **Writes for one event are serialized** (ADR
  0003): each starts only after the previous write for that event has finished, so a
  stalled early write can never land after — and overwrite — a richer later one;
  different events' uploads stay concurrent.
- **Partial camera evidence.** A Both-camera attempt keeps each successfully saved capture
  and records why front or rear coverage was missing, including a file that could not be
  saved or fallback to the front camera. These are original-attempt reasons and remain after
  a later retry. The encrypted metadata carries them to compatible receiving versions; older
  versions ignore the extra field. A receiver that already holds a same-revision sparse record
  accepts newly present `captureFailure` on an equal revision; this is a specific
  enrichment rule, not a general acceptance of every changed field. Each camera's saved
  evidence raises the record's revision on its own, so a device holding the copy with one
  camera takes the later copy that adds the other, which can arrive after it as late
  evidence. This is not a guarantee that either camera always succeeds.
- **Bounded retry.** Because a single dropped push at trigger time can mean lost
  evidence — a stolen device never comes back to retry — each push retries transient
  CloudKit failures (network loss, throttling) with backoff, honoring the server's
  retry-after, but capped to a few attempts and to 4 s per wait to limit time spent
  racing a shutdown. These limits do not guarantee completion within iOS's background
  execution window. An unfinished eligible upload remains pending locally. For verified cloud access and matching account bindings, the
  pending sweep retries uploads at launch, on every
  foreground, when a network path returns, and when the owner opens the log. The sweep
  has no power-off to race, so it is patient where the trigger-time push is not: it
  honors the server's retry-after in full (2–120 s), stops handing out records the
  moment the server names a wait, and makes follow-up passes by itself until the backlog
  is up or it stops getting anywhere (at most 20 passes, 3 in a row that land nothing).
  See ADR 0003's amendment.
- **Cached account status does not replace authorization.** Every upload needs verified
  cloud access and an eligible account binding. Within that boundary, a stale or transient
  cached status is rechecked rather than disabling uploads for the whole watch. Unknown
  ownership, a different account or unavailable authorization keeps evidence local.

</details>

<a id="evidence-at-rest"></a>
<details>
<summary>Evidence at rest</summary>

- **Encrypted at rest.** Local evidence (JSON + media) is written with **Data Protection
  `completeUnlessOpen`** — encrypted while the device is locked, unless a file is
  currently open for an in-flight upload. This is stronger than the container
  default. Media is written (and recorded clips are *moved*) into the store off the
  main actor, with the protection class re-applied after the move **as one
  transaction — a clip whose protection cannot be applied is removed, never left on
  disk under-protected** — so a large clip never lands in memory or blocks the UI at
  the moment of capture.
- **Recordings waiting to be attached are protected less.** A clip records into
  Application Support/PendingCameraEvidence, which uses `completeUntilFirstUserAuthentication`:
  readable whenever the phone has been unlocked once since it started, so a finished clip
  can still be read and attached if the screen locks first. The store moves each clip out
  as it attaches it, under `completeUnlessOpen` as above, so only a clip no event took stays
  there; such a clip is removed at launch once it is 30 days old.
- **Retention has separate budgets: 500 incidents and 100 recent status entries**,
  with the existing shared ~2 GB media cap. Arm/disarm, settings and interruption
  history cannot displace incidents, and incident flooding cannot consume status
  slots. Mirrored copies go first within either budget, so cloud input cannot evict
  first-hand evidence. Incidents then discard coalesced flood records, synced
  evidence and finally pending evidence, oldest first within each class. Status
  entries discard the oldest first-hand entries after copies. The **newest first-hand
  row in each budget stays**, including an in-flight flood anchor. An event or status entry
  whose upload is running is left alone by both limits (an event's media too), and no newer
  row or media goes in its place; the limits apply again when the upload ends, by when it is
  usually synced (1.7). On Pro, when the incident limit removes events this phone was meant to
  upload and had not fully uploaded (pending, or waiting for iCloud verification), the log
  keeps a status entry saying so, once per watch or once a day while disarmed (kept across
  relaunches); it does not say how many. A trim made while the log loads at launch is reported
  too, once the Pro check has answered (normally within seconds); if the app ends before then,
  that report is lost. On upgrade a
  readable legacy log adopts these limits; old status history beyond 100 is removed
  locally even if unsynced. Count trimming does not delete records from iCloud. The
  cloud-cleanup minimum age of 30 days does not apply to these local storage limits.
  A copy previously marked synced may no longer exist remotely; re-download is
  possible only while that cloud copy remains. A
  pending capture the byte cap must discard in a storage emergency is
  **marked on its event** so the loss is visible. A launch-time
  sweep also reclaims media files no event references (true leaks); it deletes nothing
  while a corrupt-log backup exists — after a corruption, an unreferenced file may be
  evidence whose metadata was lost — and never touches referenced or recent files. Since
  1.7 (70) no backup is deleted automatically, and no limit deletes a file a backup refers
  to, so its photos and clips stay with it (and, while one exists, so do true leaks). Until then a launch deleted a backup 30 days old, or
  all but the newest three, and the sweep then deleted the media only that backup referred to.

</details>

<a id="detection-reliability"></a>
<details>
<summary>Detection reliability</summary>

- Tripwires latch on firing and are re-armed after the trigger or by a half-second
  sweep. That addresses stale latches, not every cause of missing sensor data. And a trip that lands
  **while a capture is already running is folded into that event's record** rather
  than dropped: a grab-then-unplug lists both sensors even when the second step falls
  inside the 1–5 s capture window (34-review M1 — previously the one hole in
  "any enabled tripwire fires on its own").
- The **capture caller has an independent whole-attempt deadline**, including light
  and interruption queries and finalization. Expiry logs the failure, requests
  shutdown, and quarantines the camera until its old worker and shutdown drain.
  It does not prove a blocked Apple camera API stopped; a permanent stall may need
  relaunch. Later incidents can still be logged, but new evidence capture is refused
  while that camera is recovering. Late media retains its original event destination
  and cannot be consumed by a replacement capture, and once stored it starts an upload pass
  of its own (after any pass already running), rather than waiting for the next launch,
  foreground or reconnect. See ADR 0038.
- Clip lengths are measured from each returned movie, independently for each lens.
  Saved partial or unverified files carry a per-camera explanation; unknown duration
  stays unknown. A missing thumbnail or a delegate error alone does not discard bytes.
  Unclaimed movie files stay in protected Application Support/PendingCameraEvidence,
  outside temporary-file cleanup; termination before finalization still does not
  guarantee playable footage or automatic attachment after relaunch. Nothing attaches a
  clip still there later, so one 30 days old is removed at launch. A separate pending
  allowance of 1,200 files / 2 GB limits admission. A clip is checked against it before
  its capture starts the camera, so when it is full (or holds an unreadable entry) that
  capture starts no camera and lights nothing: the event records that clip storage is full,
  Home says so, and photos are unaffected. A camera the watch already keeps ready, and the
  Vision tripwire, run apart from this check. The torch lights only once a recording has been admitted; unreadable or
  linked entries refuse new recordings without deleting retained evidence. Both lenses share one reservation
  snapshot, and each movie output receives its share as a maximum file size. The limit
  is admission plus AVFoundation's stopping policy, not an exact disk reservation.
- **No arming gap after go-live.** The sensors start watching the moment calibration
  finishes — the brief "calibration complete" review the owner sees is not an unprotected
  window. A tamper during it fires normally (and drops the review straight to
  covert), rather than being missed until the review times out. The scope is stated
  precisely (eighth review, L6): the ~3 s **calibration itself** — inside the owner's own
  set-down window, right after the deliberate grace period — is when baselines are
  learned, so power/proximity/touch adopt the settled state rather than tripping on it;
  watching begins at go-live, not at the ARM tap. This also applies to automatic
  recovery countdowns. Actions wholly inside these windows can be missed.
- **Detection keeps running through PIN entry — bar one sensor — and suppression needs
  *active* entry.** Revealing the disarm pad pauses exactly one tripwire, proximity, because a
  covered proximity sensor blanks the display — hiding the pad the owner is typing on; motion,
  sound, vision and power keep detecting, and capture keeps running. The pad also replaces the
  covert touch surface while it is open, so keypresses are not themselves touch trips — the
  5-second hold that revealed the pad was already logged as one on press-down (32.R7).
  Suppression covers only the *presentation* — the capture flash and the start of a
  fresh on-screen alert, which would fight the raised pad brightness — and only while a
  keypress landed in the last 20 s (A-02/H1); the 5-second hold that opens the pad counts as
  the first keypress — one window per logged hold, not renewable without another. An idle
  pad past that window (it stays up 30 s past the last keypress, to a 120 s ceiling) and a
  mere touch on the glass do not qualify; owner
  *attribution* still uses the wider any-touch window, but presentation was deliberately
  narrowed to actual typing (F1). Residual, accepted: someone tapping keys holds suppression
  for the pad's lifetime — while standing over an armed device whose motion, sound and vision
  tripwires are live.
  Detection and capture run underneath throughout (proximity excepted, as above); anything
  captured while the pad was open
  is flagged **owner-attributed** only if a correct PIN follows — a wrong PIN's own record
  included, so an owner's typo followed by the right PIN reads as theirs; the pad auto-returns to
  covert on inactivity; and the tamper alert names the reveal hold only until the owner's first
  disarm from the black screen, as a tip for a new install (an install that had armed before 1.6
  never shows it; the hold opens the pad and nothing more). The suppression rule is
  presentation-only by construction: one pure function (`alertAction`) *always* keeps an
  already-running alert/siren alive and only ever gates the start of a fresh one — a screen
  touch can never silence a sounding siren.
- **The siren ramps rather than suppressing.** In Siren mode a tamper alarm opens quiet,
  holds ~10 s, then rises to full over ~10 s. The owner's own disarm (a 5-second hold plus
  a PIN) fits inside the quiet phase, so handling your own device isn't punished — while
  anyone who doesn't disarm gets the full alarm. Escalations do **not** ramp: suspected
  jamming and sensor floods go to full volume immediately, and an escalation arriving
  mid-ramp overtakes it, and the alert window is extended to cover the whole ramp **plus** a
  period at full volume — otherwise the alarm would be stopped before it was ever loud. The
  ramp can be turned off (*Settings → Tripwire Response*) for instant maximum volume.
  **Siren mode uses photo attempts rather than video clips, including before the alarm
  starts** (F4), and the arming screen says so before you commit. Camera availability,
  repeated-trigger handling and capture failures can limit the images produced. Recording a clip needs the
  microphone, and a capture session holding a mic input takes the app's audio session — so a
  clip capture would silence the siren. That made *further tampering quieten the alarm*:
  picking the device up fired a new trigger whose clip seized audio and stopped the siren.
  During an alarm Malinois therefore requests photos instead of clips, so capture does
  not take the microphone away from the siren. This does not guarantee a saved image for
  every trigger or uninterrupted system audio. Little is lost — a clip's audio
  track during a blaring siren records the siren. **Only the microphone is released, not the
  camera**: the video pipeline keeps running through the alarm, so the next trigger pays no
  cold start and the vision tripwire keeps watching between captures. Its coverage during a
  sustained alarm is bounded, stated honestly: every capture suppresses vision for ~5 s (the
  scene being recorded must not judge itself), so under continuous tampering the other
  tripwires carry detection; vision's win here is the quiet stretches and the warm restart. (Siren is
  **not** the default response — Alert, a silent on-screen warning, is; Siren is opt-in.)
- **The siren attempts to resume after an audio interruption.** Guided Access and
  iOS behavior vary: owner checks have seen both diverted calls and a call banner,
  and Siri has appeared without interrupting Malinois. These observations do not
  establish that calls or Siri can never interrupt audio. When iOS interrupts playback,
  the player can stop for the duration of that interruption. Malinois observes `AVAudioSession.interruptionNotification` and, when the
  interruption ends, restarts the alarm if it should still be sounding — **at full volume**,
  never re-granting the ramp's quiet window (so a stream of interruptions can't keep it quiet),
  and independent of the system's `.shouldResume` hint. A siren the owner disarmed meanwhile
  stays silent. (Without GA, an *answered* call backgrounds the app and iOS suspends monitoring
  for the call's duration — the documented foreground limitation, distinct from this. Under GA
  behavior should be checked on the target iOS/device rather than assumed.)

Sensor thresholds and calibration reduce nuisance alarms; they also bound detection.
Small or slow movement can stay below a threshold. Vision uses sampled pixel changes,
not person recognition, and can miss low-contrast or small scene changes. Its capture
suppression and re-anchoring can absorb a changed scene. On Auto battery operation,
the cold camera means Vision has no continuous frames; unplugging can change that
coverage mid-watch. Watchdog restarts do not establish complete sensor-health reporting.
These are limits to evaluate, not promises that environmental bypasses are impossible.

</details>

<a id="environmental-attacks-the-trigger-pattern-is-a-signal"></a>
<details>
<summary>Environmental attacks (the trigger pattern is a signal)</summary>

A stationary armed device pushes the viable attacks into the non-contact category,
where the tell is the *pattern* of triggers, not any single one:

- **Sensor flooding** (a vibration motor on the table leg, a loop of noise to
  overflow the 500-incident budget): a sustained high trip rate — set well above a plausible
  *human* tamper rate (~6/min) so an ordinary burglary isn't misread — is treated as an
  attack. This is checked **both per-sensor and in aggregate**: an attacker could
  otherwise stay under the per-sensor bar by alternating two sources (say a motor and a
  speaker at ~8/min each), and every one of those trips would become an ordinary event,
  indistinguishable from real evidence at prune time and quietly pushing genuine events
  past the retention caps. The aggregate check counts *triggers*, not raw sensor trips,
  so a genuine tamper firing motion + touch + proximity together still counts once and
  can never be misread as synthetic noise (F3). Repeats **coalesce** into one "sustained
  activity" counter event instead of hundreds, and the app **goes loud** (abandons Stealth with an on-screen warning; the siren joins only in Siren mode — suspected jamming is the one escalation that always sirens). Crucially, coalescing suppresses **log spam and upload volume, not
  evidence**: capture continues on a bounded cadence (a photo every ~20 s) so a real
  tamper that looks like a flood still gets capture attempts, subject to camera
  availability and the cadence limit. A
  **byte-aware retention cap** keeps synthetic clips from filling storage (their log
  entries are kept), and **both** the media (byte) cap **and** the event (count) cap
  prefer dropping coalesced flood records before ordinary incidents. This reduces
  displacement; it does not prevent sustained below-threshold activity or ordinary
  storage pressure from eventually evicting old evidence, including pending records. The
  coalesced counter's *disk write* is itself throttled (~2 s cadence, final count flushed on
  clear) so a flood can't be converted into a whole-log-rewrite storm (F2).
- **Audio baseline poisoning** (a slow noise ramp to walk the trip bar up and mask
  handling sounds): the rolling baseline may adapt for legitimate ambient change but
  is **clamped to the calibrated quiet + a fixed drift** — including the warm-up
  window right after `start()` (and after every siren stand-down), which sets the
  initial rolling value — so the bar can be moved by at most that much, never more. The
  clamp limits the bar from above only, so a microphone that is down is treated as missing
  data, not as silence: while it is not recording, its floor reading neither trips, nor moves
  the baseline, nor counts toward calibration or the warm-up. It used to sink the bar, and
  the unchanged room tripped a false Sound event when the microphone came back.
- **Vision-tripwire poisoning** (Pro; the camera watching its own field of view while
  plugged in): the obvious attacks are (a) a slow illumination ramp to mask an approach, and
  (b) creeping into frame below the per-frame threshold so the adaptive baseline absorbs the
  intruder. Against (a), frames are **mean-normalized** before comparison, so a change that
  affects every pixel equally — lights dimming, auto-exposure settling, the capture flash —
  is never motion; that is also the guard against the *illegible* false positive (a trip
  whose photo shows an empty room). Against (b), the rolling baseline is **clamped per pixel
  to the calibrated session anchor**, and the anchor itself carries a **cumulative limit**
  that trips on its own — the AudioMonitor's drift clamp and the MotionMonitor's session-tilt
  defence, in two dimensions. The detector is suppressed around every capture (the scene
  being recorded must not judge itself) and re-anchors on resume. Every trip stores a
  `visionTrace` (changed-fraction per frame) so it can show *why* it fired. Scope is honest:
  it runs only while the camera is warm, nothing is stored while watching, and the RECORDING
  indicator is already showing in that mode — the feature adds no new covert surface.
- **Camera blinding / low light**: a face-down placement with the rear camera hides
  the lens position (targeted IR is much harder) and brings its own LED light; the
  sensor traces evidence the tamper regardless of frame quality.

</details>

<a id="signal-jamming--exfiltration-blackout"></a>
<details>
<summary>Signal jamming / exfiltration blackout</summary>

Malinois cannot guarantee detection of every loss of service. It cannot force
bits out of a jammed radio, and iOS exposes no signal-strength API — so it detects
the **symptom** (total loss of every network path), never the cause. The
discriminators below make that meaningful for a stationary anti-theft deployment
rather than jumpy:

- **Canary baseline.** It records whether a usable path existed *at arm*. Only the
  *loss* of a path it demonstrably had is treated as suspicious — a device armed
  offline never escalates on "no signal."
- **Stationary + debounced.** Escalation requires the motion sensor to confirm the
  device *hasn't moved* (a moved-then-lost device is the tamper-carried-away case,
  handled by the normal trigger) and the loss to persist ~30 s (riding out
  registration flaps). Requiring loss of **all** interfaces rules out a lone Wi-Fi
  or cell blip. This is strongest with an active **cellular** connection; a
  Wi-Fi-only device is weaker (a router reboot looks the same). The check is not tied
  to a quiet moment: a loss that begins during a capture or the calibration card is
  examined again the moment the watch is armed, so a jam timed to the last seconds of a
  capture is not missed (1.3.2).
- **Go loud.** On the gold trigger — or when a real tamper fires and can't be
  exfiltrated — Malinois **abandons covertness**: it sounds the siren (which no
  jammer can block) and shows an on-screen interference warning. Every new escalation
  first attempts to write a separate **Signal loss** entry, including when an offline capture or a
  terminal network-class upload failure starts the alarm. Repeated triggers during the
  same escalation do not duplicate it. The timed canary also attempts a frame; paths
  attached to an existing capture keep that capture and add only the signal-loss record.
  The diagnostic's own upload failure cannot start another alarm, even if it completes
  after reconnect or in a later watch; its record remains available for upload retries.
  The alarm is silenced only by the PIN, or
  stands down if connectivity returns. This inverts the attack: the jammer meant to
  suppress your upload and instead triggered the loudest possible alarm. The
  escalation re-arms after stand-down. Any online transition clears the current
  offline interval and stands down this alarm. Repeated short outages can therefore
  evade the continuous-loss debounce; a reported path also does not prove CloudKit
  is reachable. Upload-failure escalation is a separate signal.
- **Retry on reconnect.** When a path returns, pending evidence with verified cloud
  access and a matching account binding is retried (metadata-first); reconnection does not confirm delivery. Events captured during a blackout are flagged
  (`capturedOffline`) to record observed connectivity, not an attacker or motive. The
  cross-device push subscriptions (tamper, and since 1.3 disarm) are also re-established
  through the authorized cloud path on reconnect — if either failed to set up at arm (the network was briefly down then), the owner's other devices
  would otherwise get no alert for the whole session. Caveat: subscription setup is a
  background task started at arm, so a tamper in the very first moments of the *first*
  arm of a session can beat it and miss the *proactive* push. If the separate evidence
  upload succeeds, other authorized devices can fetch that record later. Arming deliberately does **not**
  block on this network round-trip; the ~15–20 s of grace + calibration before the watch
  goes live covers it in practice.

Honesty: this infers interference, it does not prove deliberate jamming. The logged
entry says **Signal loss**. Its **captured offline** flag reflects the observed network
path; a failed request can cause escalation while the path still looks online, in which
case that flag stays false. The on-screen deterrent uses stronger wording. A simultaneous carrier
+ Wi-Fi outage is a rare false positive whose cost is a recoverable "disarm to
silence." Off-device escape remains the only real durability — local copies do not
survive a device wipe.

</details>

<a id="cloud-cloudkit"></a>
<details>
<summary>Cloud (CloudKit)</summary>

**Installation enrollment.** Cloud evidence access and account-wide controls require
an installation-bound grant for the resolved CloudKit account. The owner explicitly
verifies with iOS device-owner authentication (Face ID, Touch ID, or device passcode).
Existing cloud users verify once after migration; a new installation cannot obtain a
grant from Pro membership, a newly selected app PIN, or a surviving Keychain item.
Until verified, local monitoring remains available and cloud operations are paused.
The grant file is atomic, protected, and excluded from backups. Read/write errors,
cancellation, unavailable authentication, and unknown account identity fail closed.

Cloud service entry points, queued writes, retry pages, downloads, subscription changes,
and cleanup carry account/generation checks. Account changes invalidate pending work;
stale results cannot be applied to local evidence. Already accepted server operations
cannot be recalled. First-hand evidence is bound at capture to an enrolled account;
migration retains only known previous account bindings, and unknown history remains
local rather than being silently adopted by a different account. The Event Log separates
held evidence from retryable uploads and explains the hold without exposing account IDs.
This presentation is not authorization: every upload still requires a fresh account lease.
An explicit alerts-OFF
requires fresh device authentication; a cancellation changes neither the saved setting
nor subscriptions. CloudKit failures can leave a partial server change, which is reported.

This policy trusts this device's owner credentials. It does not authenticate the producer
of a cloud record, sign evidence, revoke older clients on Apple's servers, prevent app
deletion, or prevent deletion through Apple's iCloud controls. Ordinary disarm still
requires the Malinois PIN. See ADR 0039 for migration and notification-extension boundaries.


> Malinois's CloudKit evidence uploads and cross-device alerts are **Pro** features.
> Free or lapsed-trial devices keep evidence local rather than uploading it through
> Malinois. Device backups are a separate copy mechanism.

- Evidence goes to the user's **private CloudKit database** (`privateCloudDatabase`),
  which CloudKit scopes to the signed-in iCloud account. Malinois also applies its
  installation verification and account-binding checks. These controls do not prove
  that a particular device created a record or that it has never been altered by an
  authorized client. Developer access to a container does not grant routine access
  to every customer's private records. A developer with the appropriate container
  access can inspect and alter their own private records through Apple's tools.
  The cross-device push subscription is scoped to the owner's private database.
- **Evidence comes back, not just up (1.1).** After a reinstall — or on another of the
  owner's devices — after cloud verification, the app attempts to restore the log's facts
  and thumbnails at launch (1.3: everything the
  local cap allows when the log is empty, one page otherwise) and on pull-to-refresh, and each
  event's full photo/clip can be **downloaded on demand** from its detail view when
  account authorization permits and the cloud copy still exists. Retrieval
  fetches the photo records by their deterministic record names (no query, no schema
  dependency — ADR 0002), and a downloaded capture gets the same at-rest protection as a
  fresh one. This closes the loop on the Pro promise: evidence that survived the device
  can be *recovered*, not merely proven to exist. Retrieval and restore never confuse
  failure with absence (ninth review, R3-3): "iCloud holds nothing" is claimed only when
  every slot actually answered, and a fetch that couldn't check everything says so and
  offers a retry instead of presenting a partial result as the whole story. The app keeps no
  device identity, so after a reinstall or an erase (a DFU restore included) the device's own
  earlier records come back as copies, labelled with the name they were stamped with, as another
  device's records are. Images that come back are cloud input, so they decode within explicit
  bounds (1.6): the size a file declares is read before any pixel is decoded, a photo over 50
  million pixels or a thumbnail over 4 million is not shown, and accepted images are decoded
  at display size. Thumbnails of new captures are made the same way.
- **Full-media retention is the owner's policy, floored for safety (1.2).** A Settings
  picker keeps full-resolution cloud media forever, prunes it manually, or auto-deletes
  it past 1–12 months (default 12). Only photo records (and old heartbeat trails, below) are
  deleted by this cleanup — it retains facts, thumbnails and audit records — and no EVENT newer than **30 days** can
  have media deleted by Malinois cleanup: the floor lives inside the purge entry point.
  Both the selected month policy and the floor use a lower bound from CloudKit system
  creation dates on existing audit/fact records. Device clock changes cannot advance
  that cutoff. An old observation delays cleanup; no usable observation means no deletion.
  This is not a fresh-server-time claim and does not constrain external iCloud deletion. (Precisely: eligibility keys on the event's age —
  a photo record that finished uploading late for an old event follows its event's age,
  which avoids treating upload delay as a new capture; eighth review, L2.) A purge whose walk couldn't
  read every candidate record reports failure rather than "Deleted" — under-deletion
  stays the safe direction, but observably so (ninth review, R3-3). The auto modes also
  delete the per-beat heartbeat records of this phone's past watches, keeping each watch's
  latest beat (ADR 0022). A trail goes only when its watch's last beat, by the server's
  clock, is older than the setting. The trim independently obtains the same conservative
  server-time lower bound, and the same floor lives inside its own decisions, so no beat newer than 30 days is deleted in any mode; a watch that beat inside
  the window keeps its whole trail. Only this phone's own watches are trimmed, from a list it
  keeps as each goes live: another device's keep their trails, and so do this phone's own
  from before a reinstall, which come back as copies (the safe direction again; a restore
  from a device backup brings the list back, and those are trimmed as before).
- **Notification health is surfaced, not assumed (34.H7).** The cross-device alert fires
  server-side, so the *sending* device needs no notification permission — but a device
  with Notifications denied for Malinois, or a failed push registration, cannot **show**
  the alert. That state used to be invisible behind a green "iCloud ready"; Home now says
  plainly that alerts from other devices won't appear on this one, re-checked on every
  foreground because a toggle flipped in iOS Settings is unobservable while suspended. Since
  1.3 (40) the permission itself is asked in context on the receiving side — Home's "Allow
  notifications" line (shown only once another device's evidence has arrived, hideable, mirrored
  under Settings → iCloud), or the Cross-device alerts switch — never at launch.
- **Generic alerts preserve the enrollment boundary (ADR 0039).** The notification service
  extension immediately delivers the subscription's fixed content and never reads private
  CloudKit records. Device/sensor details and Vision-only quieting from ADR 0017 are suspended
  from 1.5.1 on. Generic tamper alerts keep the subscription's sound and wording; from 1.6 the
  extension shows them Time Sensitive, decided from the subscription the push names without
  reading the record (ADR 0045), so a Vision-only trip is Time Sensitive too; routine arm records
  remain silent. This avoids an unenrolled background
  reader and introduces no shared authorization storage or new signing capability. Older
  installed builds retain their previous alert behavior.
- **The Apple Watch app only receives (1.6, ADR 0042 and 0043).** It registers its own push
  token, so the subscriptions' fixed alerts from the owner's other devices reach the wrist.
  iCloud does not send a watch a change made by its own iPhone while the watch is connected
  through that iPhone, so the armed iPhone also sends its own alerts straight to its paired watch
  over WatchConnectivity (Bluetooth or shared Wi-Fi, never iCloud), while this iPhone's
  Cross-device alerts setting is on and Pro is active; the message carries only the fixed alert
  text, the event's ID and its time. A relayed alert arriving more than a minute late shows the
  event's time, and a relayed tamper alert is Time Sensitive (ADR 0045). The watch shows each
  relayed alert once, remembering it only after the post succeeded: a later copy of one it
  failed to show is shown, and a copy arriving while the first is being posted is not posted
  twice. The setting is per iPhone: turning alerts off from another device stops the iCloud
  alerts at once, but this iPhone keeps relaying to its own watch until its own switch is turned
  off, and its next arm restores the subscriptions as before. The log read at unlock after a launch
  while the phone was locked is not relayed again. The watch reads no event records (its one server call lists the
  account's subscriptions to confirm the tamper alert exists), writes nothing, never arms or
  disarms, and compiles none of the iPhone app's cloud code; a test pins that. Nothing reaches
  the wrist beyond the fixed alert text, so the watch needs no Malinois PIN: its own passcode
  and wrist detection are its boundary. It names the iPhone app's container literally and uses
  the production push environment in release builds.
- **Heartbeat records (1.4; ADR 0020).** While a watch is live on Pro, online, and
  authorized for its cloud account, the phone attempts to send a small encrypted record to the owner's private iCloud every five
  minutes, one created once for each beat and one per watch that is saved over. Another of the
  owner's devices shows on that watch's arm record when the phone was last heard from, by the
  server's clock. If a prior beat reached iCloud and remains available, it provides a
  last-heard time even if the phone never returns; it is not the exact time monitoring stopped. A beat that cannot be sent is
  dropped, never sent late: a gap is a gap, not a backlog. A gap is a fact with a time, not a
  verdict (a lost connection makes one too), and it never sounds anything on the phone.
  CloudKit can observe these records' existence and server timing. Their content follows
  the [encryption rules below](#encryption-and-backups), including the ADP distinction.
  The free tier has no heartbeat, because Malinois does not upload its evidence to CloudKit. In the retention setting's
  auto modes, once a watch's last beat is older than the setting, the watch keeps only its latest
  beat (ADR 0022): the time it was last heard from stays, the gaps in its old trail do not.
- **An encrypted-data reset is recovered, not looped on (34.H13).** If the owner resets
  their iCloud encrypted data, Apple purges the app's records and saves start answering
  `zoneNotFound`. That is classified as a refusal (never a siren — ADR 0001), and the
  recovery requeues eligible FIRST-HAND events this device still holds, with a Home
  notice saying the cloud copies were cleared. Uploads require verified cloud access
  and the original account binding; unknown or different-account evidence is not adopted.
  Requeueing is not confirmation that a new upload succeeded. The
  recovery runs at whichever cloud write first sees the signal — evidence, fast fact, or
  an arm/disarm record — so a reset can't sit detected-but-ignored through a session
  with no tamper events (fourth pass, R3-2).
  Mirrors are deliberately excluded (eighth review, M4): the capturing device owns its
  evidence's re-upload — re-publishing a mirror would stamp this device's name on another
  device's evidence and could race the capturing device's richer copy. This is the one
  sanctioned exception to sync-state monotonicity — a deliberate global truth-restoration,
  not a late duplicate's failure.
<a id="encryption-and-backups"></a>

**Encryption and backups**

- **Cloud fields and media.** Malinois writes event metadata through CloudKit's
  `encryptedValues` API and stores thumbnails and media as `CKAsset`. CloudKit encrypts
  asset content automatically; assigning an asset through an ordinary record property
  does not mean its bytes are unencrypted. Records written by 1.0 retain their ordinary
  fields; ADP does not convert those into encrypted fields.
  [Apple: encrypted values](https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues).
- **Apple access depends on the protection category.** For these encrypted CloudKit
  fields and assets, standard protection permits Apple access through service keys
  held in its data centers. With **Advanced Data Protection (ADP)** enabled, Apple
  says those fields and assets are protected end to end. This does not mean iCloud
  Keychain becomes readable by Apple when ADP is off: Keychain protection and CloudKit
  service-key custody are distinct. This describes documented capability, not evidence
  that an Apple employee viewed a recording. Malinois does not require ADP.
  [Apple: iCloud encryption](https://support.apple.com/guide/security/icloud-encryption-sec3cac31735/web),
  [Advanced Data Protection](https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web).
- **Activity and timing remain visible.** CloudKit processes record identifiers,
  types and server timestamps. Record names embed event or session identifiers, and
  a purpose-specific record type can reveal an activity category. For example,
  `TamperEventDisarmV2` reveals that a disarm signal exists even though its payload
  fields are encrypted. Payload encryption does not conceal all metadata or make
  records immutable. These protections are not a blanket defense against lawful process.
  [Apple: implicit record fields](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow).
- **Device backups are separate.** Depending on settings and file eligibility, iCloud
  Backup may include local app data. Backup content is protected end to end when ADP
  is enabled; under standard protection Apple holds backup service keys. Local iOS
  file protection does not determine the protection of a backup copy. “Local-only”
  describes Malinois's uploads, not a guarantee that evidence exists only on one device.
  [Apple: iCloud data security](https://support.apple.com/en-us/102651),
  [what iCloud backs up](https://support.apple.com/en-us/108770).
- **Developer access.** Malinois has no developer-operated evidence server. Cloud
  evidence resides in the user's private iCloud database; container administration
  does not grant routine access to customers' private data. This is distinct from
  Apple's documented service-key access and a developer inspecting their own records.
- **Historical observation.** On 2026-08-25 the owner reported plaintext `deviceName`
  and `duration` fields in CloudKit Console for new V2 records on a non-ADP account.
  That observation was not independently reproduced for this review and does not by
  itself establish key custody or access to other users' records.

</details>

<a id="covert-operation"></a>
<details>
<summary>Covert operation</summary>

- Camera can't run in the true background on iOS, so covert mode keeps the app
  foregrounded with the screen forced black (brightness 0 + overlay + idle timer
  disabled). **Guided Access** (owner-enabled) locks the device to Malinois and
  restricts app-switching and ordinary power-off in the tested configuration. Call
  and Siri behavior has varied across owner tests; neither is an unconditional
  no-interruption guarantee. Guided Access remains the recommended configuration. Its Options should also disable the Side Button
  (Sleep/Wake Button on older phones): with it on (the default), one press locks the screen and suspends the watch until
  the owner unlocks — recorded as a lock, and the tripwires compare the live state with
  their baselines on resume, but nothing is watched meanwhile (README, *Enable it*). With it off, a
  press only shows the iOS banner that Guided Access is on and how to exit; the tripwires keep
  running, and ending Guided Access still needs its passcode.
- **Disarmed under Guided Access, the screen stays on for ten minutes** (since 1.4,
  ADR 0021). iOS can wake a phone that slept under Guided Access into a stuck notification
  screen, so after Guided Access starts, a disarm or a cancelled countdown, or the app's return
  to the screen, Malinois turns auto-lock off for ten minutes. For those minutes a disarmed
  phone left alone stays awake on Malinois's Home screen instead of going to sleep and
  locking. Home shows counts and times, never the evidence; the Guided Access passcode still
  keeps anyone inside Malinois, and the Malinois PIN still guards the Event Log, Settings and
  the sensor test. With Guided Access off, auto-lock is never held while disarmed.
- **Covertness has a hard, deliberate bound: the recording indicator.** Whenever any
  capture session is live, the app shows a non-disableable `REC` badge (on the armed screen,
  in Test Sensors, and since 1.7 (70) on the arming screens, where the camera can start at the
  ARM tap) and, while armed, floors screen brightness at 0.33; iOS draws its own camera indicator in the Dynamic Island or the top
  corner whatever the app does with the status bar, which stays hidden. It is derived from `AVCaptureSession` lifecycle
  notifications, so no code path can run the camera without it (App Store guideline 2.5.14).
  iOS's indicator appears the moment the camera starts; the badge follows a moment later, once
  the app has seen the start and redrawn. Nothing holds a shot until the badge is drawn: it is up
  first because a capture from a camera that was not already running waits 0.8 s for the
  exposure to settle, and a camera already running has shown the badge since it started. The
  consequence is easy to understate: under the default Battery mode (*Auto*)
  on a **charging** device the camera is held warm for the *entire* armed session, so the
  badge is up the whole time — a plugged-in armed phone does not look switched off. Only
  *Battery saver*, or *Auto* on battery, gives a genuinely black screen, at the cost of a
  cold-start delay on the first frame. This is the single largest limit on covert operation,
  it is not defeatable from inside the app, and it is not meant to be: the alternative was
  not shipping. A second, smaller one: with the Sound tripwire on, the microphone is open
  for the whole watch — metered, never stored — and iOS shows its orange indicator for the
  whole watch (one indicator at a time: green takes over while the camera is live, verified on
  device). The screen is black; the device is not idle.
- **The intended configuration, enforced by default.** Guided Access is what the armed
  threat model assumes; without it the app can be swiped away or force-quit and monitoring
  stops — and, found on device, even the side-button press of a force-restart
  backgrounds the session first. *Require Guided Access* makes the app **refuse to arm**
  while it is off. It shipped **off** through 1.2 so a first run worked without configuring
  iOS accessibility first; from 1.3 it ships **on** (owner ruling, 2026-09-02), because the
  one-arm lift below makes the strict default humane. The **first arm on a fresh install
  auto-applies that lift** (owner ruling, 2026-09-04, ADR 0010): a brand-new user reaches the
  countdown with no tap and no accessibility setup, the lift is logged like any other so the
  first session's record is honest about having run without the requirement, and every arm
  after the first enforces it — the post-session nudge teaches Guided Access with context.
  While a lifted arm proceeds, automatic or chosen, the arming screen and the countdown say
  plainly that anyone who picks up the phone can leave Malinois and use it unlocked, and to
  stay nearby (owner ruling, 2026-10-13, ADR 0010). A
  first arm made with Guided Access already on gets no lift and no record. Turning the requirement off for good is an explicit choice
  in Settings. Two deliberate carve-outs: the blocked arming screen offers both remedies
  inline (enable Guided Access, or lift the requirement **for that one arm** — the stored
  setting never changes from the arming screen, the lift expires with the arming screen or
  session, and a lift is logged and pushed as an audit record, so it cannot be a silent
  permanent downgrade by whoever holds the unlocked phone; eighth review, M2. Repeat taps
  with no arm in between coalesce into that one record — ninth review, R3-8 — so the
  "someone poked at it" signal stands without handing the holder a mint-records-forever
  primitive) so it never dead-ends, and
  **crash-recovery re-arm ignores the requirement** — a crash can end Guided Access, and
  refusing to re-arm there would leave the device silently unprotected, the exact failure the
  automatic re-arm exists to prevent. Exiting Guided Access mid-session does **not** disarm,
  either; that would hand a snoop a kill switch.
- **Voice Control is the one accessibility feature GA does *not* neutralize** (verified on
  device). A pre-enabled Voice Control session persists under Guided Access, and its
  "Close application" command can *close* Malinois. Important bounds: it does **not** escape
  GA — it can't reach another app, exit Guided Access, or touch any data — so it's a
  denial-of-monitoring action, not evidence destruction or a covert-defense bypass. Back Tap,
  by contrast, does **not** fire under GA (verified). Mitigation: the arming coaching
  instructs users to turn Voice Control off; with it off, the command doesn't exist. And a
  close-while-armed is no longer silent — see the interruption record below.
- iOS's own **green camera indicator** joins the REC badge whenever a session is live —
  equally non-suppressible, equally intentional: Malinois is an anti-theft tool, not
  covert surveillance of others. In every battery mode, eligible Pro events with
  verified cloud access and matching account bindings attempt metadata upload before
  capture. A cold camera delays the photo/clip; it does not delay that upload attempt.
  This ordering does not guarantee preservation or delivery.

</details>

<a id="non-goals--known-limitations"></a>
<details>
<summary>Known limitations</summary>

These are out of scope by design — Malinois does not claim to defend against them:

- **Hardware force-restart.** Holding the buttons to force a restart cannot be
  blocked by any app or by Guided Access. Mitigation, not prevention: the
  early metadata upload is a race, not a guarantee of delivery before shutdown.
- **Induced shutdowns that trip no sensor.** Thermal shutdown is the one "power-off" an
  attacker can cause without touching the device: heat it until iOS kills itself — slow,
  conspicuous, and nothing in the public APIs lets an app veto it. In the same family: an
  OS crash (SpringBoard "text-bomb"-class bugs end Guided Access and the app together) and
  plain battery death. None can be prevented from inside an app, and all three end a session
  without a tripwire firing. On a later launch, Malinois attempts a
  "Monitoring interrupted" record and, when authorized, a cross-device notification.
  Storage and delivery can still fail. The record distinguishes a **device restart** from the
  app ending (a boot-time stamp planted at arm is compared at relaunch), so a
  battery death or an OS panic reads differently from a force-quit. After a restart the
  record appears once the phone is unlocked (normally when Malinois is next opened), not at
  the restart: the app cannot read its own log before the first unlock. A phone can also be
  heated until iOS shuts it down: while a watch is live, iOS's thermal state reaching
  "serious", and then "critical", each prompts a recording attempt when iOS supplies the
  notification in time (authorized Pro sessions also attempt an upload). Each capture's record
  carries the thermal state it was made in. It never sounds the siren: ambient heat looks like
  induced heat (ADR 0001). Related, found on device (iOS 26.6): triggering the
  five-press Emergency SOS flow under Guided Access froze the phone until a force-restart —
  it can end monitoring like a force-restart. Handling may trip a sensor first, but
  neither detection nor upload before the freeze is assured.
- **A compromised / jailbroken device.** With code execution, an attacker can read
  the Keychain-protected hash, the on-disk evidence, and app memory. Data Protection
  and PBKDF2 raise the cost but don't stop a rooted attacker.
- **An attacker at the unlocked home screen can delete the app,** and the on-device log
  goes with its container — no credential beyond reaching that screen, no record left. A
  Guided Access passcode holder gets there by ending Guided Access; with Guided Access off,
  so does anyone, and the first arm is Guided-Access-free by design. Guided Access is the
  control, iOS's Screen Time restriction on deleting apps the belt to it; Pro's cloud copy
  can remain available for restore after reinstall and cloud verification.
- **An attacker who can reach the cloud copy** can delete the off-device evidence from
  the user's CloudKit database — with the iCloud credentials from anywhere, or, on the
  unlocked device itself, from iOS Settings (Manage Account Storage → Delete Data from
  iCloud, no password asked), which a **Guided Access passcode** holder can
  reach once they end Guided Access. There is no immediate deletion alert. Later
  missing-record checks can report loss and requeue eligible retained events after
  account verification. The on-device log is untouched by the cloud deletion, and so
  are copies other devices had already downloaded. The
  **Malinois PIN** does not provide an individual-event delete control. It does open
  Settings, including cleanup of eligible old cloud media and heartbeat trails;
  Malinois's cloud deletion is limited to the owner's retention policy over **old
  full-resolution media and old heartbeat trails only** — facts, thumbnails, audit records
  and each watch's latest beat have no deletion path inside the app, and nothing newer than
  **30 days** can be deleted by these cleanup paths (server-date-anchored policy and floor
  are enforced inside each deleting call, not the UI; unavailable time defers deletion). So a PIN-holder cannot use "free
  up iCloud space" to destroy the evidence of what they just did. What the PIN defeats is
  narrower — it stops *future* monitoring and silences the response; the GA passcode
  unlocks the single-app restriction. Recorded interruptions and notification
  attempts depend on the app running or being reopened; they cannot block deletion. Detection
  continues during disarm, and Touch cannot be switched off (ADR 0015), so a PIN-holder's
  handling — the hold that reveals the pad — normally creates a record and starts
  an authorized Pro upload attempt (flagged owner-attributed, not redacted). The armed
  pad attempts to record each wrong PIN, joining the existing event when capture is
  underway (ADR 0014). Both attempt photography unless the camera was switched off in Settings
  beforehand, which needs the PIN and since 1.4 leaves a record of its own (ADR 0019). And every arm and
  disarm is written to the log as an explicit **"Monitoring
  armed"/"disarmed"** record, so a PIN-holder who turns protection off leaves proof of
  when the app recorded it, provided that record survives retention and storage or
  is successfully uploaded. These timestamps are not proof of an unaltered device clock.
  The one residual gap is *avoidance*, not destruction: a PIN-holder who disarms while
  triggering no sensor can then snoop with monitoring off — but even then the disarm is
  normally logged and the re-armed session has a different start time. If the phone
  stays offline and the app is deleted before uploading, the local disarm record is
  lost; a previous cloud arm/heartbeat may be the only remaining indication.
- **No network / jamming at trigger time.** The app attempts to keep evidence locally.
  Eligible evidence is retried after connectivity returns and cloud authorization
  succeeds, and a suspected blackout triggers the go-loud
  response (see *Signal jamming* above) — but if the device is destroyed before the
  jam lifts, the local-only copy doesn't escape. Off-device delivery is the only
  durability; jamming is mitigated, not defeated.
- **Very low light with illumination off.** Stealth-mode shots may be too dark to
  identify a face; the sensor traces still evidence the tamper.
- **A hard crash while covert.** Covert mode forces the *system* screen brightness
  to 0; the app restores it on disarm and on backgrounding, but a crash or an
  out-of-memory kill gives no chance to run that restore, so the device can be left
  dark until the owner raises brightness (or auto-brightness intervenes). Already
  committed evidence can survive, but a crash can interrupt capture, persistence or
  upload. Relaunch attempts automatic re-arm with its guards and countdown; there
  is no monitoring while the app is stopped or during the new countdown/calibration.
- **Siren volume.** iOS gives no app a way to override the hardware volume buttons,
  so a thief can turn the siren down. The `.playback` category defeats the silent
  switch, and the on-screen warning + already-escaped evidence are the deterrents
  that don't depend on audio — but the alarm's loudness itself isn't guaranteed.
  Mitigations shipped: the arming screen tells Siren-mode users to disable **Volume
  Buttons** in Guided Access → Options (so the siren's volume can't be lowered while
  armed), and a low-volume warning is now re-sampled at go-live — not just at the
  start of arming — so it reflects the volume the device will actually alarm at.
- **Power tripwire is bidirectional but connection-state only.** The Power / Cable
  tripwire fires on a power-connection change in **either** direction — unplugged, or
  plugged in (the latter catches a device armed on battery being connected to a computer
  or forensic tool). Which direction is live follows the arm-time state, so the single
  tripwire is never inert. Known limits, by design of the public APIs: iOS exposes **no**
  way to tell a charger from a computer, or to see a data connection at all — detection is
  inferred purely from battery state. So a **hot-swap while powered** (already charging,
  cable swapped for a laptop with no loss of power — e.g. a passthrough hub) does **not**
  trip, since `batteryState` never leaves `.charging`; a normal physical swap has a
  disconnected moment and trips twice (unplug, then re-plug). Wireless charging counts as
  "connected," so lifting the phone off a Qi pad also trips.
  **Recommended mitigation for the hot-swap gap:** set iOS to **ask before new wired
  accessories** connect (Settings — search "Accessories"). A new wired device then
  cannot open a data connection silently — it needs an on-screen Allow, and a computer
  additionally needs the device passcode to pair ("Trust This Computer") — so the
  undetected variant of this attack is also the unprofitable one: it reaches hardware
  that can maintain power, not data. Honest limit: the connection *attempt* still
  produces no Malinois indication; the setting gates what the connection can do, not
  whether Malinois sees it.

</details>

<a id="resilience-notes-added-after-red-team-review"></a>
<details>
<summary>Resilience notes (added after red-team review)</summary>

- **The event log is never silently overwritten.** If `events.json` is genuinely
  corrupt at launch, it's preserved as a timestamped backup rather than clobbered by
  the next write. Home says so until the next launch that reads a log cleanly. Since 1.7 (70)
  the backup and the photos and clips it refers to are kept until the app is deleted; nothing
  reads the backup again, and it cannot be exported yet. One record that does not decode (for
  example a value an older build does not know) sets aside the whole log. A file that's merely *unreadable because the device hasn't been
  unlocked since boot* (Data Protection) is treated differently: a silent CloudKit push
  can background-launch the app before first unlock, and the healthy-but-encrypted log
  must not be mistaken for corruption and renamed away. The two are told apart by what
  can be read: a file whose contents read but do not decode is damaged whatever the lock
  state (a sealed file cannot be read at all) and is set aside at once; a file whose
  contents cannot be read is deferred — writes are blocked and the load is tried again
  at the unlock or when the app is opened — and is set aside only once iOS reports the
  phone unlocked and it still cannot be read. Being on screen alone is not taken to mean
  unlocked: a tap on a lock-screen alert can open the app an instant before the keys
  arrive (ADR 0016).
- **A suspected-jamming blackout attempts a Signal loss record**, even with the camera
  disabled. This records the observed loss, not proof of an attacker. Event storage and
  authorized Pro upload attempts do not depend on a successful frame; they can still fail.
  A device armed *offline to begin with* (a dead-zone arm) is not treated as jamming: a
  real tamper there attempts local storage and an eligible upload on reconnect, without force-sirening
  a Stealth-mode device.
- **Interruption reporting after termination.** If the armed app is terminated without a
  clean disarm — a force-quit, Voice Control "Close application", or an OS/OOM crash — the
  kill itself captures nothing (the app is gone). But an armed marker persists from the
  moment the watch goes live — under the calibration card, not from the black screen — and the next
  launch's crash recovery attempts a **"Monitoring interrupted"** event and authorized
  Pro notification. A local record needs successful storage; an alert needs delivery. When the app is
  opened, the recovery runs straight away. When a notification wakes it in the background,
  iOS can report the phone as locked even when it is not, and the recovery then waits for
  the unlock or for the app to be opened, whichever comes first (ADR 0016): a record written
  while the phone really is locked could be lost before it is saved. The record is written
  *before* the crash-loop guard runs, so even when a rapid series of kills correctly stops
  the auto-re-arm (to avoid re-arming into a loop), each eligible recovery can still
  attempt a record and authorized notification. Neither outcome is guaranteed. The
  record also says **what ended the session**: the kernel's boot time is stored
  beside the armed marker, and at the next launch a pure, unit-tested rule compares it with
  the current one — a jump of more than 30 s, or uptime that shrank, means the device
  restarted; otherwise the app alone was closed or crashed. Sending an active session to the
  background is its own cause — named a lock when Guided Access was on, since the lock
  button is the only exit there; on resume the tripwires compare the live state with their
  baselines, so a plug or unplug during the lock still trips. Cancelling a countdown, and a
  kill during one, leave records too: the one needs no PIN and used to leave nothing. A marker from a build before the stamp stays a bare
  "interrupted" rather than a guess. The one thing that can mislead the rule is a manual
  clock change of more than 30 s between arm and relaunch, which Guided Access rules out
  while armed; after a restart the record appears once the phone is unlocked (normally when
  Malinois is next opened), since the app cannot read its own log before then.
- **The PIN pad submits once the PIN's length is typed (1.6, ADR 0041)**, as the iPhone's
  passcode does, so the length is not secret. Every such entry is checked exactly like the
  explicit submit it replaces: a wrong one counts toward the lockout and, on the armed pad,
  is a wrong-PIN record with its photo, so submitting automatically gives no free guesses.
  The length used is one a successful PIN change or entry confirmed; a PIN change
  unconfirms it first, so a stale length can never submit early, and without a confirmed
  length the pad shows the explicit submit. The pad still shows one dot per typed digit.
  Hiding the length was worth little: a guesser starts with 4-digit PINs anyway, and the
  lockout, not the length, is what limits online guessing.
- **Keychain writes update-in-place** so a failed write can't destroy
  the PIN or reset the brute-force counter — and an in-process mirror of the count and the
  deadline means a refused write cannot lower either. The brute-force lockout is enforced inside
  `KeychainService.verify` itself, which both refuses a locked-out attempt **and counts
  the failed guess** — callers must not count it again. Rate limiting is therefore a
  property of the service, not of any screen: a non-UI caller cannot get unlimited
  guesses, and a unit test drives `verify()` with no view in the loop to prove the
  lockout still engages (F2).
- **A journal reduces event loss after process termination.** The event's birth record is
  appended to a write-ahead journal synchronously at detection — before capture, push, or
  response — and the next launch folds back anything the (async) full log write never
  landed. A force-quit, Voice Control "Close application", or OOM kill in that window used
  to erase the record entirely on the free tier; now the journal line survives the process,
  a successful full write retires it, and a torn final line (the kill arriving mid-append)
  is skipped without voiding the rest; since 1.7.1 the next append starts on a line of its
  own, so the fragment cannot swallow it. A completed write survives the *process*, but it sits
  in OS caches until the kernel flushes — an undocumented interval that can be tens of
  seconds — so **every append is followed by a full disk sync before anything else
  proceeds** when storage succeeds. A line is retired only after the replacement
  full log has synced. This reduces loss windows; it does not guarantee survival
  of storage failure or abrupt power loss. The sync
  costs are logged so they can be re-read on a device (ADR 0005, as amended).
- **Completed first-hand media has an attachment recovery record (ADR 0037).** The
  event must already exist. A protected, synced intent identifies its event, start time,
  physical camera, primary/secondary slot and media filename before publication. A
  staging file becomes attachable only after complete bytes, protection and file sync.
  Relaunch (including deferred unlock) validates the intent and file, enriches only the
  matching first-hand event, and reopens cloud sync. It never creates an event from a
  manifest or guesses between conflicting slots. The intent retires only after a synced
  event snapshot contains the attachment. Recovered in-memory references can prevent
  aging but cannot authorize retirement. Unresolved intents suspend orphan sweeping;
  bounded cleanup cannot age out a complete file still eligible for attachment. This
  does not authenticate local files against an attacker who can rewrite the app's data,
  guarantee directory-rename durability under abrupt power loss, or identify legacy
  orphan media. Downloads retain their separate current-record merge behavior.
- **Capture failures can carry a reason** (ADR 0008). The record carries the
  reason — permission denied, the camera would not start or did not start in time, the shot
  or clip failed, the session was interrupted (with the system's reason: the app left the
  foreground, another app took the camera or the microphone, iOS shed the camera under
  pressure), the file could not be written, or the owner disarmed while the capture was in
  flight — and the event's detail view reads it out.
  An interruption-class failure, or a shot refused because an earlier capture still
  owns the camera, gets **one bounded retry**: when the interruption ends — or
  at once, if it ended while the shot was still failing — if the session is still armed, the
  event is recent and still without media, and no other capture owns the camera, a single
  still is taken and attached, labelled as the second attempt; the slot is cleared before
  the eligible attempt, so it is one try, never a loop. A busy camera preserves the
  opportunity until release, within the same watch and retry window; expiry, camera
  disablement, existing media or disarm ends it. Queued work is bound to its original
  incident/watch, and an old attempt cannot stand down a replacement watch's camera.
  A camera
  session killed by a runtime error — previously down and unlogged until the next trigger
  (32.R9) — leaves a "camera session failed" audit record, is surfaced on Home, and is
  re-warmed per the readiness policy, at most once per minute so a storm of errors cannot
  become a storm of records. In until-clear mode, a trip that extends the recording is now
  folded into the record's sensor list rather than only into the clip's length.
- **App updates end an armed session like any other process kill** (owner-observed on the
  2026-08-30 TestFlight pair). The next launch attempts an interruption record and
  recovery re-arm, as for a force-quit — but nothing resumes until the app is
  opened once, so update, then open. Existing server-side subscriptions do not require
  that sending watch to keep running, but notification delivery still depends on iOS
  and connectivity.
- **Crash-recovery re-arm is deferred to the foreground.** After a crash/force-quit
  while armed, the app re-protects itself with a *visible, cancellable* grace countdown.
  If the app is instead background-launched (by a push) it waits until the owner brings
  it forward, so the device never goes armed-and-covert while nobody is watching. That
  owed re-arm is **persisted**, not just held in memory, so if iOS terminates the
  background launch before the owner foregrounds it, the next launch still recovers rather
  than silently dropping the re-arm (M4). The crash-loop guard is timed against actual
  re-arm *attempts*, so a re-arm that was only deferred never counts toward it.
- **The recovery countdown itself leaves a marker (F1, external review round 11).** The window
  between consuming the owed re-arm flag and re-engaging covert used to hold no persistent
  state, so killing the app a second time *during* the visible recovery countdown left the next
  launch blind — no log entry, no re-arm. A recovery-in-progress marker now covers that window:
  a kill there leads to another interruption-record attempt and owes a fresh re-arm, with the attempt-timed
  crash-loop guard still breaking kill loops. The first interruption already had its
  record and authorized upload attempted before the window opened; this closes an
  additional re-arm gap.
- **Go-loud observes the real push result (F3), and only for the network class (ADR 0001).**
  The trigger-time decision keys on network-path reachability, which a hostile router can keep
  "satisfied" while blocking CloudKit or its DNS. The engine also escalates when a push
  actually exhausts its retries while a path held at arm still looks up — but only when the
  terminal failure is consistent with interference (no path, a request that vanished). A
  **refusal** — iCloud answering no: a full quota, an auth lapse, a schema mismatch, an
  encrypted-key reset — reached the server, so nothing is jammed; it is surfaced on Home
  instead of sounding a permanent false alarm in the owner's absence.

</details>

<a id="build-hygiene-not-a-runtime-property"></a>
<details>
<summary>Build hygiene (not a runtime property)</summary>

- **`DEVELOPMENT_TEAM` must be stripped before the project is shared — expect it to be
  present the rest of the time.** Xcode's Automatic signing re-writes your team ID into
  `project.pbxproj` on **every device deploy**, and a team ID is *required* to build,
  archive, and submit — so a working tree will normally contain one, and that is not a
  defect. The rule is a release step, not a steady state: strip it (and any
  `CODE_SIGN_STYLE`/provisioning specifics) immediately before publishing the source, then
  verify with `grep -n "DEVELOPMENT_TEAM" Malinois.xcodeproj/project.pbxproj`. Note what
  a *correct* result looks like: in a published tree that grep still returns hits, but with
  **empty** values (`DEVELOPMENT_TEAM = "";`) — that is the stripped state, not a leak, and
  an absent key would only make Xcode's signing UI stranger for a fresh cloner.
  `CODE_SIGN_STYLE = Automatic` is deliberately left in place: it carries no identifying
  information and it is what prompts a cloner to pick their own team under Signing &
  Capabilities.
- **Push entitlement is per-configuration.** Debug signs with `Malinois.entitlements`
  (`aps-environment` = `development`); Release signs with `Malinois-Release.entitlements`
  (`production`). A shipped build carrying the development value would receive an APNs
  *sandbox* token, and the CloudKit subscription that alerts the owner's other devices
  would silently never arrive. Keep the two files in sync when adding capabilities (both
  carry Time Sensitive Notifications since 1.4). The alert extension signs with its own file,
  which names the app's CloudKit container and nothing else: the Time Sensitive level it sets
  on tamper alerts works through the app's capability, as device tests in 1.4 and 1.6 showed
  (ADR 0045). Apple does not document that, so a signing change calls for that device test again.

</details>
