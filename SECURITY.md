# Security Model — Malinois

This document is the single source of truth for Malinois's threat model, the
mechanisms that defend it, and the things it explicitly does **not** protect
against. It's written for reviewers and future maintainers so the design intent
doesn't have to be re-derived from the code each time.

> Use Malinois only on **your own device**. It is a personal anti-theft / anti-snoop
> tool, not a tool for surveilling other people.

---

## The model on one page

**Threat:** someone with brief physical access to your unattended, unlocked iPhone —
picking it up, unplugging it, plugging it into a computer, searching around it, or
trying to power it off before the evidence escapes.

**Adversary tiers:**
- **Tier 1 — opportunistic snoop or thief, no credentials.** The design target; every
  guarantee below applies in full.
- **Tier 2 — someone holding one of the owner's credentials.** Bounded outcomes: a PIN
  holder can stop *future* monitoring but deletes nothing and is photographed doing it;
  a Guided Access passcode holder can close the app, which is logged and alerted; iCloud
  credentials can wholesale-delete the cloud copy but never edit it — and a suddenly
  empty cloud log beside a surviving local one is itself loud.
- **Tier 3 — professionals (spyware, device forensics).** The core objective survives:
  the tripwires still fire, and the record exists — usually off-device (Pro) — before
  any toolchain can finish. What ends is the vault, not the tripwire: a compromised OS
  reads everything. Stated honestly below.

**Core guarantees:**
1. **Detection never silently stops** — not for PIN entry (the open pad pauses just one
   sensor, proximity, which would otherwise blank it — see the resilience notes), not for
   a capture in flight, not for a lapsed paywall.
2. **Evidence precedes response.** The record is written before any alert or siren
   fires, and (Pro) the tamper *fact* reaches iCloud sub-second — a race against
   power-off the design exists to win.
3. **The log only accumulates.** No delete affordance, no destructive merge; changes
   attach and label, never erase.
4. **Recording is always indicated** (the REC badge and iOS's camera dot) — covertness
   has a deliberate, non-negotiable bound.
5. **Failures are loud.** Interrupted sessions, refused uploads, degraded persistence,
   and silent-clip conditions all surface to the owner instead of passing quietly.

**Honest limits:** a hardware force-restart can be raced but not blocked; no network at
trigger time means local-only until reconnect; a compromised OS is out of scope; free-tier
evidence never leaves the device.

Passages marked **Design note** record *why* something is built (or deliberately not
built) the way it is — skip them on a first read; return to them before proposing changes.

---

## Contents

- [Threat model](#threat-model)
- [Defenses](#defenses)
  - [Protection tiering: free vs Pro](#protection-tiering-free-vs-pro)
  - [PIN (disarm + evidence access)](#pin-disarm--evidence-access)
  - [Evidence integrity](#evidence-integrity)
  - [Evidence at rest](#evidence-at-rest)
  - [Detection reliability](#detection-reliability)
  - [Environmental attacks](#environmental-attacks-the-trigger-pattern-is-a-signal)
  - [Signal jamming / exfiltration blackout](#signal-jamming--exfiltration-blackout)
  - [Cloud (CloudKit)](#cloud-cloudkit)
  - [Covert operation](#covert-operation)
- [Non-goals / known limitations](#non-goals--known-limitations)
  - [Resilience notes](#resilience-notes-added-after-red-team-review)
  - [Build hygiene](#build-hygiene-not-a-runtime-property)
- [Reporting](#reporting)

---

## Threat model

**Who:** an opportunistic snoop or thief with brief **physical access** to your
unattended, unlocked iPhone while you're away from it. They can pick it up,
tilt/move it, unplug it (or **plug it into a computer** to pull data off it), make
noise near it, tap the screen, or try to power it off.

**What they want:** to handle or take the device without leaving a trace, and — if
they realize it's monitored — to destroy the evidence before it escapes the device.

**What we protect:** the *fact and evidence* of tampering — a timestamp, which
sensors tripped, sensor traces, and a photo/clip — captured and pushed to the
owner's iCloud fast enough to survive the device being powered off afterward.

**Adversary tiers.** Three, each analyzed and *bounded* below:

**Tier 1 — the design target (full defense).** The opportunistic snoop or thief above, with
no credentials. Every guarantee in this document applies.

**Tier 2 — credentialed insiders (in scope, with bounded outcomes).** A partner, colleague,
or repeat visitor who has obtained one of the owner's credentials. Each credential buys
something specific and leaves something behind (details in
[Non-goals](#non-goals--known-limitations)):
- **Malinois PIN:** can disarm — stopping *future* monitoring — but cannot delete anything,
  and the disarm itself becomes an undeletable, timestamped record. Detection continues
  during PIN entry, so even the disarm is photographed.
- **Guided Access passcode:** can kill the app; the kill is logged as "Monitoring
  interrupted" on the next launch and alerts the owner's other devices (Pro). Evidence
  already pushed has already escaped.
- **iCloud credentials:** cannot *browse* the log — Apple exposes no web or Settings UI for
  a third-party app's CloudKit records (verified against Apple's iCloud.com feature list and
  data-export documentation), and signing in on a new device additionally requires defeating
  two-factor. What they can do is **wholesale-delete** the app's iCloud data (Settings →
  Manage Storage → Delete Data from iCloud). There is no selective-edit or single-record
  path — and a suddenly-empty cloud log beside a surviving local log is itself loud
  evidence. **Absence of evidence is evidence.** They can also **insert** fabricated
  records — but this device merges those only as clamped, labeled mirrors: never
  superseding first-hand evidence, timestamps believed at most a day ahead of the
  record's own server stamp, and always first against the retention cap. Insertion buys
  distraction in the log, not reach into the on-device record (fourth pass, R2-F3 +
  R3-4).

**Tier 3 — professional adversaries (outside the guarantees, stated honestly).** The
realistic top of this app's threat ladder is not a government — it is the private-sector
surveillance industry: investigators and private-intelligence firms working a divorce, a
custody dispute, a lawsuit, or corporate espionage, with budgets for commercial spyware and
device-forensics tooling. Malinois does not claim to defeat this tier; here is where the
lines fall:
- **What still works: the core objective — you find out.** A professional still has to
  physically handle the device to image it, implant on it, or search around it — and
  detection, capture, and the sub-second fact push run exactly as for any other adversary;
  jamming still forces the go-loud response. Compromise is not instantaneous: the first
  touch trips before any toolchain finishes, so by the time an implant could silence
  Malinois the record already exists — and with Pro it has usually already left the
  device. Tampering *silently* therefore requires all three at once: ensuring the device
  has no network before the first trip (to beat the sub-second push), gaining full
  read-write control of an up-to-date iPhone, and laundering the app's local state without
  leaving a seam. (On the free tier the first leg comes free — the record is local-only —
  but the other two still stand.) Each leg sits at the edge of commercial capability, and
  failing any one leaves loud evidence: a gap, an interrupted session, an armed record with
  no disarm. Against this tier Malinois remains a functioning **tripwire** — what it stops
  being is a **vault**.
- **What fails: the device itself.** Mercenary spyware or an exploit chain on the phone
  reads everything the phone can read — the log, the media, app memory — and with full
  control could in principle edit the local record. The cloud copy (Pro) stays beyond its
  reach either way: there is no selective-delete path into the private database, only the
  tier-2 wholesale delete, which is loud. No app defends a compromised OS, and this one
  doesn't claim to.
- **Credential theft feeds tier 2, not a new tier.** Pretexting and phishing — the
  private investigator's actual toolkit — yield at most the tier-2 outcomes above:
  wholesale-visible destruction, never silent editing.
- **Where the data technically lives** (stated descriptively, not as advocacy): the
  on-device log is readable only on the unlocked device — Apple states it cannot extract
  data from a locked modern iPhone. In iCloud, media assets are encrypted toward keys held
  in the owner's own Keychain, and as of 1.1 the event metadata is written the same way —
  though how much that protects depends on the account's Advanced Data Protection setting,
  not on this app (see *Key custody* below). Users make their own choices about iCloud
  account settings; Malinois takes no position and works the same either way.

---

## Defenses

### Protection tiering: free vs Pro

*(A security-relevant invariant, not just a billing detail.)*

Malinois is monetized (a one-time Pro unlock, 30-day trial from first launch), and the
split is drawn so that **the paywall never silently reduces protection**:

- **Always free:** all core detection (motion / power / proximity / touch tripwires),
  on-device capture, the PIN-gated local event log, the brute-force lockout, Guided
  Access support and its optional arming gate, the siren, the anti-flood/coalescing
  logic, and jamming detection's *local* go-loud response.
- **Pro only:** whether evidence **survives** (iCloud backup), **travels**
  (cross-device push), or is **richer** (multi-cam, 5s/until-clear clips, the Audio and
  Vision tripwires).

Two consequences matter for the threat model:

1. **Off-device durability is a Pro property.** The "two-shot exfiltration races a
   power-off" guarantee below holds only on Pro (or in trial). A **free** or
   lapsed-trial device keeps evidence **local-only**, which does not survive the device
   being taken or wiped — it defends "who touched my phone?", not "recover evidence
   after theft." This is stated plainly in-app and in the trial-end notification, not
   hidden.
> **Design note — the trial clock fails toward the user.** `trialActive` treats a
> backward-moved device clock as "still in trial" rather than expiring it early. That is a
> **revenue** edge, not a security one — the "attacker" is the owner, gaining only the
> upload of their own evidence to their own iCloud. The obvious fix (a wall-time
> high-water mark) is deliberately not taken: one accidental clock-forward excursion — a
> bad NTP sync, a child in Settings — would permanently burn a legitimate owner's trial.
> Same trade as the removed hash chain: defending a marginal threat by hurting real
> owners. Under Guided Access, Settings is unreachable anyway.

2. **Downgrade is never silent and never destructive.** A lapsed trial clamps
   Pro-only *behaviour* at use (`ProEntitlements`' `effective…` functions) but never
   mutates the user's saved settings or reduces core detection, and the UI surfaces
   every clamp (Home banners, the free-tier notices, the "trial ended, still
   protected" message). The security-relevant point: an expiring purchase cannot leave
   the owner *believing* they have protection they no longer have.

### PIN (disarm + evidence access)

- **What it gates.** A 4–6 digit PIN is required to **disarm** and to **view the
  event log**, so a snoop who reaches the app can't stop monitoring or delete evidence.
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
- **Durable writes.** Keychain writes **update in place** rather than delete-then-add,
  so a failed write (e.g. one attempted while the device is locked) can't destroy the
  PIN hash or silently reset the lockout counter. And "no hash on file" is only
  treated as first-time setup on a genuine fresh install: if setup was completed
  before but the hash is unreadable, re-setup is **gated behind device
  authentication**, so a stranger can't just set a new PIN and open the log.
- **Both directions of a Keychain/flag disagreement are gated (M2).** `setPIN` writes the
  Keychain hash first and the `UserDefaults` setup flag second, and `UserDefaults` persists
  asynchronously — so a crash in between leaves a *legitimately set* PIN with no flag. That used
  to be treated as a fresh install: the PIN was silently wiped and an **open** setup screen
  presented, letting whoever held the unlocked device choose a PIN that then gated the still-
  present event log. It also destroyed the owner's own PIN, a reliability bug in its own right.
  The two producers of that state are told apart by whether an event log survives on disk — a
  genuine reinstall has none (the container went with it, so nothing is left to protect and
  wiping stays correct), while a lost flag has both the PIN and the log. The latter now goes
  through device authentication, which **repairs the flag** rather than re-running setup, so
  nothing is destroyed. `KeychainService.recoveryKind` is pure and unit-tested. The
  recovery gate **fails closed** (sixth review, F4): if device authentication cannot run
  at all — no device passcode set — recovery refuses and says a passcode is required,
  rather than treating "cannot authenticate" as authenticated; setting a passcode in iOS
  Settings re-enables it immediately, so the owner is never trapped. And "PIN present"
  means *verifiable* (seventh review, #2/#3): the stored hash must carry the current
  version byte and, for the PBKDF2 format, its salt — a lost or malformed salt classifies
  as the recoverable lost-hash state instead of an unwinnable pad, and verification never
  mints a salt over the gap.
- **Design note — why a reboot is not a rate-limit bypass.** Two reviewers have now
  read the reboot note above and concluded that force-restarting clears an in-progress
  lockout and lets guessing resume, then proposed adding a *wall-clock* deadline alongside
  the uptime one. Both halves are wrong, so the reasoning is spelled out here:
  1. A reboot does clear the current *wait* (uptime is monotonic and resets at boot), but it
     drops the attacker at the **device-passcode prompt**, not at the Malinois PIN pad. After
     a restart iOS demands the device passcode before first unlock — biometrics don't apply,
     and `WhenUnlockedThisDeviceOnly` keeps the counter and the hash unreadable until then.
     The in-scope attacker doesn't have that passcode, so the cleared wait is unreachable by
     exactly the attacker it would benefit. The failure *count* survives regardless, so even
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
  under stress, so it's the owner's choice. It composes with the existing length
  concealment (dots-per-typed-digit + explicit submit). VoiceOver reads each key's digit,
  so scrambling doesn't harm assistive navigation.

### Evidence integrity

- The **event log is append-only from the UI's perspective** and PIN-gated — there
  is no delete affordance, so a snoop can't remove events even if they open the app.
  (The Home button's event *count* shows without the PIN — a deliberate glanceability
  trade: it is the local count, which an iCloud-only attacker
  cannot change, and it reveals volume, never content.)
- **Every screen that reveals configuration is PIN-gated too.** The Event Log, Settings, and
  *Test sensors* all sit behind the same gate. The owner may opt the two READ surfaces —
  the Event Log and Test sensors — into Face ID (off by default); **Settings never accepts a
  face, whatever the toggle says**: it is a *write* surface (tripwires, response mode,
  cross-device alerts, the retention purge), and a presented face reconfiguring the
  protection posture is exactly what the boundary exists to prevent (eighth review, M1).
  Viewing is a convenience; the security boundary is unmoved: disarm, stopping a recovery
  re-arm, and changing the PIN itself never accept a
  face, because a face can be *presented* while a PIN has to be *given*. Inside a Guided
  Access session the Face ID offer is skipped entirely and the pad stands with a caption:
  iOS defers the biometric sheet under GA without erroring, and pre-fix the
  queued request left the privacy cover over the pad — a fail-closed hang, but a
  dead-end. Test sensors records nothing, but it lists
  exactly which tripwires are enabled and renders their live thresholds — the same
  reconnaissance the Settings gate exists to deny — so gating the log and Settings while
  leaving it open would have been an inconsistency worth nothing to the owner and quite a lot
  to a snoop holding the disarmed device.
- **Design note — why there is no hash chain.** A tamper-evident chain over the log was built and then
  removed: within this threat model there is no path for an attacker to delete an
  *individual* record. The app exposes no delete affordance, `CloudExfiltrator` never
  deletes a *fact* (its only record deletions are push subscriptions and the owner's
  full-media retention policy, which cannot touch anything newer than 30 days), the
  CloudKit console cannot see private databases,
  and editing `events.json` needs a jailbreak or the device passcode — both out of scope.
  What an iCloud-credential holder *can* do is wholesale-delete, which is self-evident
  (the log is simply gone) and needs no cryptography to notice. A chain would therefore have
  detected only out-of-scope attacks while staying silent on the in-scope one — at the cost
  of false "tampering detected" warnings, which teach the owner to distrust the log and so
  damage the very thing it protects.
- **Facts never mutate; changes only accumulate.** The core facts of an event —
  `id`, `startDate`, `motionTrace`, `audioTrace` — are
  `let`: fixed at capture time and unchangeable afterwards. Four fields *do* mutate, and
  the distinction that matters is that every one of them only ever **accumulates**, never
  erases: `triggeredSensors` (flood coalescing folds later sensors into the open event),
  `endDate` and `sustainedCount` (how long the handling went on), and `ownerAttributed`
  (set when a correct PIN follows, so an owner disarm is *labelled* rather than removed).
  Nothing in the lifecycle deletes a recorded fact — restoring from iCloud follows the
  same rule: a re-downloaded full-resolution capture *attaches* media to an event, never
  replaces or removes anything — and that survives later refreshes: when a newer cloud
  copy supersedes a mirror, it inherits the locally-downloaded media reference rather
  than erasing it (eighth review, M3). Store updates as a class preserve monotonic
  fields: owner attribution and an advanced sync state can never be walked back by a
  stale in-flight copy (sixth review, F2 — ADR 0006).
- **Two-shot exfiltration** *(Pro)* races a power-off: the instant a tamper is
  logged — for *every* capture mode, *before* the camera capture even starts — a tiny
  metadata record ("the fact") is pushed at `.userInitiated` QoS so it lands
  sub-second; the full-res media (and a thumbnail) follow. Every push attempt is
  **deadline-bounded (20 s)**: a network path that *stalls* without failing — CloudKit's
  own resource timeout is measured in days — is cancelled and counted as a network-class
  failure, so a stall can neither wedge the per-event pipeline nor mute the
  observed-failure escalation by never technically failing (sixth review, F1). The
  account-status preflight ahead of each push is bounded the same way (10 s), so no step
  of the chain — check or write — can hang it (fourth pass, R3-1). The event is also queued for the on-device store before capture (an asynchronous write — a runtime persist failure raises a Home banner rather than passing silently, F6), so a tamper is logged even if capture fails — and on the **free
  tier** that on-disk write is the whole story, since the iCloud pushes are Pro-gated
  (see [Protection tiering](#protection-tiering-free-vs-pro)). A still takes ~1 s to shoot
  and write and a clip far longer, so pushing the fact first (not just for clips)
  keeps the sub-second guarantee uniform. **Writes for one event are serialized** (ADR
  0003): each starts only after the previous write for that event has finished, so a
  stalled early write can never land after — and overwrite — a richer later one;
  different events' uploads stay concurrent.
- **Bounded retry.** Because a single dropped push at trigger time can mean lost
  evidence — a stolen device never comes back to retry — each push retries transient
  CloudKit failures (network loss, throttling) with backoff, honoring the server's
  retry-after, but capped to a few attempts so it always completes inside the
  background-task window. Only if it still can't reach iCloud does the event fall
  back to local-only, to re-upload when the owner next opens the log.
- **The cached account state is an optimization, not a gate.** A push always *attempts*
  unless iCloud is definitively unavailable (no account / restricted); a merely stale
  or transient state (e.g. `.couldNotDetermine` during a network transition at arm) is
  re-checked at trigger and then tried anyway, so one blip can't silently disable
  exfiltration for the whole armed session.

### Evidence at rest

- **Encrypted at rest.** Local evidence (JSON + media) is written with **Data Protection
  `completeUnlessOpen`** — encrypted while the device is locked, unless a file is
  currently open for an in-flight upload. This is stronger than the container
  default. Media is written (and recorded clips are *moved*) into the store off the
  main actor, with the protection class re-applied after the move **as one
  transaction — a clip whose protection cannot be applied is removed, never left on
  disk under-protected** — so a large clip never lands in memory or blocks the UI at
  the moment of capture.
- **Retention is capped, and evicts in order of what the log can least afford to
  lose** — 500 events / ~2 GB of media: mirrored copies from other devices first of all
  (copies, not custody — the capturing device and the cloud still hold them, and a
  re-fetch brings them back; fourth pass, R3-4), then coalesced flood records, then
  events and media already synced (locally a cache — the cloud holds them and they
  re-download), then pending, with the arm/disarm/interruption audit rows last of all,
  so a paced attacker generating ordinary-looking events can't push the audit trail over
  the boundary. The **newest event is never evicted**, whatever its class — retention sheds
  the oldest, and the record of the incident in progress outranks everything (before this
  rule, a coalesced flood record arriving at a full log evicted *itself* at birth). A
  pending capture the byte cap must discard in a storage emergency is
  **marked on its event** — it can never silently read as synced later. A launch-time
  sweep also reclaims media files no event references (true leaks); it deletes nothing
  while a corrupt-log backup exists — after a corruption, an unreferenced file may be
  evidence whose metadata was lost — and never touches referenced or recent files.

### Detection reliability

- Tripwires are one-shot (they latch on firing to avoid spamming) and are always
  re-armed — after the trigger they fired, or by a half-second sweep as the backstop —
  so nothing can leave a sensor latched and silently deaf. And a trip that lands
  **while a capture is already running is folded into that event's record** rather
  than dropped: a grab-then-unplug lists both sensors even when the second step falls
  inside the 1–5 s capture window (34-review M1 — previously the one hole in
  "any enabled tripwire fires on its own").
- Clip capture is **time-bounded** end-to-end: if the camera's recording delegate
  never returns (an interrupted session, a hardware stall), the wait is cut and the
  event is still logged, rather than wedging the trigger pipeline so no further
  tamper is ever caught. And the pipeline has one owner (ADR 0003): the trigger
  response outranks everything; the blackout and flood-cadence grabs yield to it and
  to each other, are stills by construction (a frame answers their purpose, and a
  still cannot contend for the movie output), and a recording accepts exactly one
  stop — so one event's footage can never be consumed, or the pipeline hung, by
  another's.
- **No arming gap after go-live.** The sensors start watching the moment calibration
  finishes — the brief "calibration complete" review the owner sees is not an unprotected
  window. A tamper during it fires normally (and drops the review straight to
  covert), rather than being missed until the review times out. The scope is stated
  precisely (eighth review, L6): the ~3 s **calibration itself** — inside the owner's own
  set-down window, right after the deliberate grace period — is when baselines are
  learned, so power/proximity/touch adopt the settled state rather than tripping on it;
  watching begins at go-live, not at the ARM tap.
- **Detection keeps running through PIN entry — bar one sensor — and suppression needs
  *active* entry.** Revealing the disarm pad pauses exactly one tripwire, proximity, because a
  covered proximity sensor blanks the display — hiding the pad the owner is typing on; motion,
  sound, vision and power keep detecting, and capture keeps running. The pad also replaces the
  covert touch surface while it is open, so keypresses are not themselves touch trips — the
  5-second hold that revealed the pad was already logged as one on press-down (32.R7).
  Suppression covers only the *presentation* — the capture flash and the start of a
  fresh on-screen alert, which would fight the raised pad brightness — and only while a
  keypress landed in the last 20 s (A-02/H1). Neither an open-but-idle pad (it stays up 30 s
  past the last keypress, to a 120 s ceiling) nor a mere touch on the glass qualifies; owner
  *attribution* still uses the wider any-touch window, but presentation was deliberately
  narrowed to actual typing (F1). Residual, accepted: someone tapping keys holds suppression
  for the pad's lifetime — while standing over an armed device whose motion, sound and vision
  tripwires are live.
  Detection and capture run underneath throughout (proximity excepted, as above); anything
  captured while the pad was open
  is flagged **owner-attributed** only if a correct PIN follows; the pad auto-returns to
  covert on inactivity; and the tamper alert never prints the reveal gesture. The rule is
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
  ramp can be turned off (*Settings → When triggered*) for instant maximum volume.
  **In Siren mode every trigger is photographed, not filmed — from the first one, before any
  alarm is sounding** (F4), and the arming screen says so before you commit. Recording a clip needs the
  microphone, and a capture session holding a mic input takes the app's audio session — so a
  clip capture would silence the siren. That made *further tampering quieten the alarm*:
  picking the device up fired a new trigger whose clip seized audio and stopped the siren.
  During an alarm Malinois therefore photographs each trigger instead of filming it, so the
  siren keeps sounding and every trigger is still captured. Little is lost — a clip's audio
  track during a blaring siren records the siren. **Only the microphone is released, not the
  camera**: the video pipeline keeps running through the alarm, so the next trigger pays no
  cold start and the vision tripwire keeps watching between captures. Its coverage during a
  sustained alarm is bounded, stated honestly: every capture suppresses vision for ~5 s (the
  scene being recorded must not judge itself), so under continuous tampering the other
  tripwires carry detection; vision's win here is the quiet stretches and the warm restart. (Siren is
  **not** the default response — Alert, a silent on-screen warning, is; Siren is opt-in.)
- **An audio interruption can't silence a running siren.** Under **Guided Access — the
  recommended armed config — incoming calls go straight to voicemail** (verified on device):
  no ring, no audio interruption, no disturbance, so a call can neither silence the siren nor
  suspend monitoring. This defense matters for the two cases GA doesn't cover: running
  *without* GA (supported but not recommended), and non-call interruptions that can fire even
  under GA (a Clock alarm, another app's audio). In all of those, iOS posts an audio
  *interruption* that stops our player — so without handling it, a single incoming call, even
  an accidental spam call, would permanently mute a sounding alarm with no PIN and no physical
  access. Malinois observes `AVAudioSession.interruptionNotification` and, when the
  interruption ends, restarts the alarm if it should still be sounding — **at full volume**,
  never re-granting the ramp's quiet window (so a stream of interruptions can't keep it quiet),
  and independent of the system's `.shouldResume` hint. A siren the owner disarmed meanwhile
  stays silent. (Without GA, an *answered* call backgrounds the app and iOS suspends monitoring
  for the call's duration — the documented foreground limitation, distinct from this. Under GA
  the call never reaches that point.)

### Environmental attacks (the trigger *pattern* is a signal)

A stationary armed device pushes the viable attacks into the non-contact category,
where the tell is the *pattern* of triggers, not any single one:

- **Sensor flooding** (a vibration motor on the table leg, a loop of noise to
  overflow the 500-event log): a sustained high trip rate — set well above a plausible
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
  tamper that merely *looks* like a flood is never left un-photographed. A
  **byte-aware retention cap** keeps synthetic clips from filling storage (their log
  entries are kept), and **both** the media (byte) cap **and** the event (count) cap
  drop **coalesced flood records before genuine ones** — so synthetic noise can't
  evict a real event's photo or push real evidence past the retention boundary. The
  coalesced counter's *disk write* is itself throttled (~2 s cadence, final count flushed on
  clear) so a flood can't be converted into a whole-log-rewrite storm (F2).
- **Audio baseline poisoning** (a slow noise ramp to walk the trip bar up and mask
  handling sounds): the rolling baseline may adapt for legitimate ambient change but
  is **clamped to the calibrated quiet + a fixed drift** — including the warm-up
  window right after `start()` (and after every siren stand-down), which sets the
  initial rolling value — so the bar can be moved by at most that much, never more.
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

### Signal jamming / exfiltration blackout

An adversary can't stop you from *noticing their silence*. Malinois can't force
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
  Wi-Fi-only device is weaker (a router reboot looks the same).
- **Go loud.** On the gold trigger — or when a real tamper fires and can't be
  exfiltrated — Malinois **abandons covertness**: it sounds the siren (which no
  jammer can block) and shows an on-screen interference warning, and grabs a frame
  (a jammer setting up is likely nearby). The alarm is silenced only by the PIN, or
  stands down if connectivity returns. This inverts the attack: the jammer meant to
  suppress your upload and instead triggered the loudest possible alarm. The
  escalation **re-arms after each stand-down**, so an attacker can't burn it with a
  brief jam-and-release and then jam for real in silence.
- **Retry on reconnect.** The instant a path returns, pending evidence is
  re-pushed (metadata-first), so it escapes the moment the jam lifts or the device
  is carried back into signal. Events captured during a blackout are flagged
  (`capturedOffline`) so the record shows the adversary's sophistication. The
  cross-device push subscription is also re-established on reconnect — if it failed
  to set up at arm (the network was briefly down then), the owner's other devices
  would otherwise get no alert for the whole session. Caveat: subscription setup is a
  background task started at arm, so a tamper in the very first moments of the *first*
  arm of a session can beat it and miss the *proactive* push (the evidence record still
  lands, and other devices see it on their next fetch). Arming deliberately does **not**
  block on this network round-trip; the ~15–20 s of grace + calibration before the watch
  goes live covers it in practice.

Honesty: this infers jamming, it doesn't prove it. The *logged* claim stays modest
("captured offline"); only the on-screen deterrent is punchy. A simultaneous carrier
+ Wi-Fi outage is a rare false positive whose cost is a recoverable "disarm to
silence." Off-device escape remains the only real durability — local copies do not
survive a device wipe.

### Cloud (CloudKit)

> Cloud backup and the cross-device push subscription are **Pro** features; a free or
> lapsed-trial device never writes to CloudKit and keeps evidence local-only.

- Evidence goes to the user's **private CloudKit database** (`privateCloudDatabase`),
  which CloudKit scopes to the signed-in iCloud account. **Cross-account access is
  impossible by construction** — another user cannot read or inject records, so no
  app-level record ownership/signature validation is needed. The cross-device push
  subscription only ever fires on the owner's own records.
- **Evidence comes back, not just up (1.1).** After a reinstall — or on another of the
  owner's devices — pull-to-refresh restores the log's facts and thumbnails, and each
  event's full photo/clip can be **downloaded on demand** from its detail view. Retrieval
  fetches the photo records by their deterministic record names (no query, no schema
  dependency — ADR 0002), and a downloaded capture gets the same at-rest protection as a
  fresh one. This closes the loop on the Pro promise: evidence that survived the device
  can be *recovered*, not merely proven to exist.
- **Full-media retention is the owner's policy, floored for safety (1.2).** A Settings
  picker keeps full-resolution cloud media forever, prunes it manually, or auto-deletes
  it past 1–12 months (default 12). Only photo records are ever deleted — facts,
  thumbnails and audit records are permanent — and no EVENT newer than **30 days** can
  have media deleted in any mode, by anyone: the floor lives inside the purge entry point
  itself, so no caller can violate it. (Precisely: eligibility keys on the event's age —
  a photo record that finished uploading late for an old event follows its event's age,
  which is the anti-tamper direction; eighth review, L2.)
- **Notification health is surfaced, not assumed (34.H7).** The cross-device alert fires
  server-side, so the *sending* device needs no notification permission — but a device
  with Notifications denied for Malinois, or a failed push registration, cannot **show**
  the alert. That state used to be invisible behind a green "iCloud ready"; Home now says
  plainly that alerts from other devices won't appear on this one, re-checked on every
  foreground because a toggle flipped in iOS Settings is unobservable while suspended.
- **An encrypted-data reset is recovered, not looped on (34.H13).** If the owner resets
  their iCloud encrypted data, Apple purges the app's records and saves start answering
  `zoneNotFound`. That is classified as a refusal (never a siren — ADR 0001), and the
  recovery is Apple's prescribed one: every FIRST-HAND event this device still holds is
  requeued and re-uploaded, with a Home notice saying the cloud copies were cleared. The
  recovery runs at whichever cloud write first sees the signal — evidence, fast fact, or
  an arm/disarm record — so a reset can't sit detected-but-ignored through a session
  with no tamper events (fourth pass, R3-2).
  Mirrors are deliberately excluded (eighth review, M4): the capturing device owns its
  evidence's re-upload — re-publishing a mirror would stamp this device's name on another
  device's evidence and could race the capturing device's richer copy. This is the one
  sanctioned exception to sync-state monotonicity — a deliberate global truth-restoration,
  not a late duplicate's failure.
- **Key custody, stated descriptively:** media assets (`CKAsset`) are encrypted toward keys
  held in the owner's own iCloud Keychain. As of 1.1 the metadata around them is written the
  same way: every custom field on the `…V2` record types (dates, sensors, device name,
  `metadataJSON`) goes through `encryptedValues` rather than as a plaintext field.
  Records written by 1.0 keep their plaintext fields — the app still reads
  them, since a deployed CloudKit field cannot be converted in place.
- **How much protection that is depends on the account, not on this app.** `encryptedValues`
  are encrypted with keys held in the owner's iCloud Keychain. Whether *Apple* can reach
  those keys is decided by the account's **Advanced Data Protection** setting: with ADP on,
  they are end-to-end and Apple cannot; with ADP off — the default — Apple holds them, and
  Apple-side surfaces can decrypt the fields. This is not theoretical: on 2026-08-25 the
  CloudKit Console displayed `deviceName` and `duration` from freshly-written `…V2` records
  in plain text, on a non-ADP account. Malinois takes **no position** on how anyone should
  configure their iCloud account; this is recorded here so the guarantee is not overstated.
- **What it does *not* cover, stated plainly.** This is data minimization, not a claim of
  end-to-end encryption, and it is **not** a defense against lawful process. Three things
  stay visible to the platform regardless of ADP: a record's **creation timestamp**, its
  **record name** (which embeds the event UUID), and the fact that the record exists at all.
  So the existence, count and timing of tamper records remain observable — at best what is
  hidden is *what* each one says. Assets are also unencrypted *fields* (a `CKAsset` cannot be
  an encrypted value); their content is encrypted toward the owner's keys by the private
  database, which is why the media was never the exposed part. Note also that iCloud **Backup** includes the app's local
  container per Apple's documentation, so "on-device only" describes where the app writes,
  not every copy the owner's own account settings may make.
- The developer has **no server and no access** to this data — it lives in the
  user's own iCloud. This is why the privacy manifest declares no data collection.

### Covert operation

- Camera can't run in the true background on iOS, so covert mode keeps the app
  foregrounded with the screen forced black (brightness 0 + overlay + idle timer
  disabled). **Guided Access** (owner-enabled) locks the device to Malinois and
  blocks app-switching and the soft power-off. It also **routes incoming calls to
  voicemail** (verified on device) and disables Siri, so neither can background the app
  or interrupt monitoring — which is a large part of why GA is the recommended armed
  configuration rather than merely a nicety.
- **Covertness has a hard, deliberate bound: the recording indicator.** Whenever any
  capture session is live, the app shows a non-disableable `REC` badge, un-hides the status
  bar, and floors screen brightness at 0.33. It is derived from `AVCaptureSession` lifecycle
  notifications precisely so that no code path can record without it (App Store guideline
  2.5.14). The consequence is easy to understate: under the default Battery mode (*Auto*)
  on a **charging** device the camera is held warm for the *entire* armed session, so the
  badge is up the whole time — a plugged-in armed phone does not look switched off. Only
  *Battery saver*, or *Auto* on battery, gives a genuinely black screen, at the cost of a
  cold-start delay on the first frame. This is the single largest limit on covert operation,
  it is not defeatable from inside the app, and it is not meant to be: the alternative was
  not shipping.
- **The intended configuration, not enforced by default.** Guided Access is what the armed
  threat model assumes; without it the app can be swiped away or force-quit and monitoring
  stops. *Settings → Require Guided Access* makes the app **refuse to arm** while it is off —
  the owner holding themselves to that configuration rather than the app deciding for them. It ships **off**,
  so a first run works without configuring iOS accessibility first; turning it on is an
  explicit choice. Two deliberate carve-outs: the blocked arming screen offers both remedies
  inline (enable Guided Access, or lift the requirement **for that one arm** — the stored
  setting never changes from the arming screen, the lift expires with the arming screen or
  session, and every lift is logged and pushed as an audit record, so it cannot be a silent
  permanent downgrade by whoever holds the unlocked phone; eighth review, M2) so it never
  dead-ends, and
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
  covert surveillance of others. The battery-vs-latency trade never weakens durability:
  the tamper *fact* is pushed before capture in every mode, so a cold camera delays only
  the photo/clip.

---

## Non-goals / known limitations

These are out of scope by design — Malinois does not claim to defend against them:

- **Hardware force-restart.** Holding the buttons to force a restart cannot be
  blocked by any app or by Guided Access. Mitigation, not prevention: the
  sub-second first upload is a race Malinois is built to win, not a guarantee.
- **Induced shutdowns that trip no sensor.** Thermal shutdown is the one "power-off" an
  attacker can cause without touching the device: heat it until iOS kills itself — slow,
  conspicuous, and nothing in the public APIs lets an app veto it. In the same family: an
  OS crash (SpringBoard "text-bomb"-class bugs end Guided Access and the app together) and
  plain battery death. None can be prevented from inside an app, and all three end a session
  without a tripwire firing. What Malinois does instead: the next launch writes a
  "Monitoring interrupted" record and pushes a cross-device alert, so the gap is logged
  rather than silent. A thermal sentinel that alarms on the way *up* — before the OS gives
  out — is tracked in the project's backlog. Related, found on device (iOS 26.6): triggering the
  five-press Emergency SOS flow under Guided Access froze the phone until a force-restart —
  for evidence purposes it behaves like the force-restart race, because five button presses
  are handling, and handling trips the sensors first.
- **A compromised / jailbroken device.** With code execution, an attacker can read
  the Keychain-protected hash, the on-disk evidence, and app memory. Data Protection
  and PBKDF2 raise the cost but don't stop a rooted attacker.
- **An attacker who has the iCloud credentials** can delete the off-device evidence
  from the user's CloudKit database — that is the one credential that defeats the
  *evidence* itself. The **Malinois PIN** and the **Guided Access passcode** do **not**:
  the app exposes no way to delete an event, and cloud deletion is limited to the
  owner's retention policy over **old full-resolution media only** — facts, thumbnails
  and audit records have no deletion path at all, and nothing newer than **30 days** can
  be deleted in any mode (the floor is enforced inside the purge itself, not the UI). So
  neither credential can erase evidence that already escaped, and a PIN-holder cannot
  use "free up iCloud space" to destroy the evidence of what they just did. What they defeat is narrower — the PIN stops *future* monitoring and silences
  the response; the GA passcode unlocks the single-app lock (and exiting it is itself
  captured). Detection continues during disarm, so even a PIN-holder's handling is
  photographed and pushed (flagged owner-attributed, not redacted). And every arm and
  disarm is now written to the log as an explicit, non-deletable **"Monitoring
  armed"/"disarmed"** record, so a PIN-holder who turns protection off leaves proof of
  exactly *when* — the owner doesn't have to infer it from a re-armed session's start time.
  The one residual gap is *avoidance*, not destruction: a PIN-holder who disarms while
  triggering no sensor can then snoop with monitoring off — but even then the disarm is
  logged, the re-armed session shows a **later start time than the true arm**, and a device
  left disarmed is itself a tell, so the disarm can't be cleanly hidden.
- **No network / jamming at trigger time.** Evidence is kept locally and re-pushed
  the instant connectivity returns, and a suspected blackout triggers the go-loud
  response (see *Signal jamming* above) — but if the device is destroyed before the
  jam lifts, the local-only copy doesn't escape. Off-device delivery is the only
  durability; jamming is mitigated, not defeated.
- **Very low light with illumination off.** Stealth-mode shots may be too dark to
  identify a face; the sensor traces still evidence the tamper.
- **A hard crash while covert.** Covert mode forces the *system* screen brightness
  to 0; the app restores it on disarm and on backgrounding, but a crash or an
  out-of-memory kill gives no chance to run that restore, so the device can be left
  dark until the owner raises brightness (or auto-brightness intervenes). Evidence
  is unaffected — it's already on disk and, for a real tamper, in iCloud. On relaunch
  the app also **re-arms automatically** (unless it's crash-looping), so a crash
  doesn't silently leave the device unprotected.
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

### Resilience notes (added after red-team review)

- **The event log is never silently overwritten.** If `events.json` is genuinely
  corrupt at launch, it's preserved as a timestamped backup rather than clobbered by
  the next write. A file that's merely *unreadable because the device hasn't been
  unlocked since boot* (Data Protection) is treated differently: a silent CloudKit push
  can background-launch the app before first unlock, and the healthy-but-encrypted log
  must not be mistaken for corruption and renamed away. That case is deferred — writes
  are blocked and the load retries the instant the device unlocks.
- **A suspected-jamming blackout is always logged**, even with the camera disabled —
  the fact of interference is recorded and pushed regardless of whether a frame is grabbed.
  A device armed *offline to begin with* (a dead-zone arm) is not treated as jamming: a
  real tamper there is stored locally and uploaded on reconnect, without force-sirening
  a Stealth-mode device.
- **Being killed while armed is not silent.** If the armed app is terminated without a
  clean disarm — a force-quit, Voice Control "Close application", or an OS/OOM crash — the
  kill itself captures nothing (the app is gone). But an armed marker persists, and the next
  launch's crash recovery logs a **"Monitoring interrupted"** event and pushes it, so the
  interruption leaves a local record and alerts the owner's other devices. This is recorded
  *before* the crash-loop guard runs, so even when a rapid series of kills correctly stops
  the auto-re-arm (to avoid re-arming into a loop), each one still alerts the owner.
- **The disarm PIN pad never reveals the stored PIN length** (no placeholder dots; an
  explicit submit), and Keychain writes update-in-place so a failed write can't destroy
  the PIN or reset the brute-force counter. The brute-force lockout is enforced inside
  `KeychainService.verify` itself, which both refuses a locked-out attempt **and counts
  the failed guess** — callers must not count it again. Rate limiting is therefore a
  property of the service, not of any screen: a non-UI caller cannot get unlimited
  guesses, and a unit test drives `verify()` with no view in the loop to prove the
  lockout still engages (F2).
- **A detected event survives its own process dying.** The event's birth record is
  appended to a write-ahead journal synchronously at detection — before capture, push, or
  response — and the next launch folds back anything the (async) full log write never
  landed. A force-quit, Voice Control "Close application", or OOM kill in that window used
  to erase the record entirely on the free tier; now the journal line survives the process,
  a successful full write retires it, and a torn final line (the kill arriving mid-append)
  is skipped without voiding the rest. A hard power cut in the same instant remains the
  cloud fact push's race to win (ADR 0005).
- **App updates end an armed session like any other process kill** (owner-observed on the
  2026-08-30 TestFlight pair). The interruption is logged and the recovery re-arm runs at
  the next launch, exactly as for a force-quit — but nothing resumes until the app is
  opened once, so update, then open. Receiving cross-device alerts is unaffected (the
  subscription lives server-side); it is the *sending* device's watch that stops with its
  process.
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
  a kill there is logged as another interruption and owes a fresh re-arm, with the attempt-timed
  crash-loop guard still breaking kill loops. (The first interruption was always logged and
  pushed before the window opened — this closes the re-arm gap, not an evidence gap.)
- **Go-loud observes the real push result (F3), and only for the network class (ADR 0001).**
  The trigger-time decision keys on network-path reachability, which a hostile router can keep
  "satisfied" while blocking CloudKit or its DNS. The engine also escalates when a push
  actually exhausts its retries while a path held at arm still looks up — but only when the
  terminal failure is consistent with interference (no path, a request that vanished). A
  **refusal** — iCloud answering no: a full quota, an auth lapse, a schema mismatch, an
  encrypted-key reset — reached the server, so nothing is jammed; it is surfaced on Home
  instead of sounding a permanent false alarm in the owner's absence.

### Build hygiene (not a runtime property)

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
  would silently never arrive. Keep the two files in sync when adding capabilities.

---

## Reporting

This is a personal-use project. If you find a security issue, note the file and a
concrete failure scenario (inputs → wrong outcome) so it can be reproduced.

---

## Reporting a vulnerability

Report suspected vulnerabilities to **support@comptonemail.com**. Please don't open a
public issue for anything security-sensitive. You'll get an acknowledgement, and fixes
ship through the App Store — this repository mirrors each shipped release's source, so
the fix appears here when the release does.
