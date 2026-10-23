# ADR 0055: Settings that cannot be read yet are not the owner's choices

- **Status:** accepted (the owner's ruling on BACKLOG 152, 2026-10-22: 1.8.1 takes the audit's recommended fixes;
  lead 3 with lead 17 and hardening note (a)). In 1.8.1 (78), BACKLOG 145 step 12.
- **Date:** 2026-10-22

## Context

A silent CloudKit push, or iOS's prewarming after a restart, can start Malinois before the phone's first unlock.
The event log has handled that since 1.3.3: a sealed file is told from a damaged one and the load waits for the
unlock (ADR 0016). The settings did not. They live in the preferences store, which reads as empty before the first
unlock, and `AppSettings.load` took an empty read for a fresh install and returned the defaults: iCloud backup on,
media retention Auto-delete after 12 months, the Sound and Vision tripwires off, Alert. The whole process then ran
on those. An upload could go out although the owner keeps backup off; the retention pass could run on 12 months
with Keep forever chosen; the launch seeds (the disarm tip, the first-arm screen's parts) and the protection-settings
baseline (item 91) were written from the defaults, so the tip could show again and the next arm could record
changes nobody made; and a Settings screen closed later in the same run saved the defaults over the owner's
choices. Nothing on Home said so. Whether iOS runs the app's initializer before the first unlock could not be
confirmed from the source (the audit's deciding fact); the guard is cheap either way.

A second, related gap: a settings store that does not decode is reset to the defaults, keeping the iCloud switches
where they can be read (ADR 0049) but taking retention back to 12 months and saving it at once, so a reset could
start deleting the owner's iCloud media.

## Decision

1. **A canary tells a sealed store from a fresh install.** A file in Application Support, written with first-unlock
   protection after every launch that read the settings. At launch, a canary that exists but cannot be read means
   the keys are not available yet: the store's empty answer is not a fresh install. A missing canary (a fresh
   install, or an install from before 1.8.1 at its first launch) or a readable one leaves the store's answer as it
   is. The rule is pure: `AppSettings.storeReading(canary:stored:)`.
2. **Sealed, the settings start unresolved.** `AppSettings.load` returns the defaults flagged `awaitingUnlock`, the
   one object the app shares. While the flag is set: no save (`save` returns at once, the autosave included); the
   retention pass does not run; the launch seeds and the protection baseline wait (`whenResolved`); Home's Settings
   switch for backup cannot be moved; and uploads wait without marking anything: `backupAllows` refuses every
   record, the store marks nothing kept-local, the enrollment holds nothing to no account on the switch's account,
   and no heartbeat goes out (`cloudBackupKnownOff`, `cloudBackupKnownOn`).
3. **The unlock loads the stored settings into the same object.** At the unlock notice or the app becoming active,
   whichever comes first (the log's two signals, ADR 0016), the canary is read again. Readable: the stored settings
   load (or a damaged store resets, as at launch) into the shared object, the flag clears, the canary is written
   again, the deferred work runs in order (the seeds, the baseline, the device name), and, with backup on, a
   pending sweep carries up what waited. Still unreadable: the wait goes on, unless UIKit says the phone is
   unlocked, in which case the canary is broken, not sealed, and is replaced (the log's rule, mirrored).
4. **A damaged store falls back to Keep forever.** The reset keeps the iCloud switches where they can be read (ADR
   0049) and sets retention to Keep forever, not 12 months: nothing in iCloud is deleted on the strength of a
   setting the owner never chose. Home's reset notice is unchanged.

## Path inventory

Every reader of the settings at launch, and what it does while they are unresolved:

- `MalinoisApp.makeServices`: the two launch seeds (`OnboardingState.seedHasDisarmedOnce`,
  `seedFirstArmBriefing`) run through `whenResolved`: at once on an unlocked launch, at the unlock otherwise. Until
  then the flags read as a new install's, which errs towards showing the tip and the screen.
- `MonitoringEngine.init`: the protection baseline and the device name run through `whenResolved` the same way
  (`MonitoringEngine+SettingsGuard.swift`); `recordProtectionChanges` (Settings closing, every arm) returns without
  comparing or adopting while unresolved.
- The retention pass (`enforceCloudRetentionIfDue`, the foreground pass): not run while unresolved; the next
  foreground runs it on the owner's policy.
- What leaves the phone: `backupAllows` (every upload and retry, the uploader's `backupPermits`), the store's
  `keepsNewEventsLocal`, the enrollment's `holdsNewEventsLocal`, the uploader's `backupOn` (heartbeats). All read
  the switch as known: unresolved, nothing uploads, nothing is marked, nothing is sent. An upload refused this way
  leaves the record pending for the sweep, which reads `backupAllows` afresh; the sweep at resolution carries it.
- Writers: `save` (the Settings screen's Done, its dismissal, the autosave, `setCloudBackup`) returns at once while
  unresolved; `setCloudBackup` refuses, so no "backup turned off" entry is written against the defaults.
- Screens: Home, the arming screens and Settings read the shared object and re-render when it resolves; while
  unresolved they show the defaults, as before. The PIN gate's own sealed handling (RootView: "PIN storage
  unavailable", the Keychain's items are readable only while unlocked) keeps Settings and the ARM tap out of reach
  before the unlock, so no edit can be made against the defaults in practice; the guards above hold regardless.
- Older versions: no new stored field in the settings. The canary is a file older builds never read; a 1.8 build
  installed over 1.8.1 ignores it and behaves as before. A reset's Keep forever is an ordinary stored value.
- Not covered: an event recorded during the window has no owner in the enrollment, whose own state file is sealed
  by the same protection class, so it never uploads (`register` is called at capture only); that is the behaviour
  before this decision, and no such event is expected (the launch recovery itself waits for the unlock). A canary
  that cannot be written (storage full) is logged, and a launch before the unlock reads as a fresh install until
  the next launch writes it, as before 1.8.1.

## Consequences

- A launch before the first unlock changes nothing the owner chose and sends nothing on the strength of a default.
  The owner's settings are in force from the unlock, not from the next launch.
- One launch stays as before: an install's first launch of 1.8.1, if it happens before the first unlock, has no
  canary yet and reads as fresh. The canary exists from the first unlocked launch on.
- The simulator cannot seal a file by Data Protection, so the tests plant a canary the process cannot read by its
  permissions, the one way the simulator gives "exists but cannot be read"; the rule and the wait are tested through
  the real load and the real notices. A real pre-first-unlock launch is the owner's check on a spare device, if one
  is available (BACKLOG 152's device run).
- A damaged settings store no longer starts deleting iCloud media; the owner sees the reset notice and chooses the
  policy again. ADR 0049's decision on the iCloud switches stands.
- Not chosen: trusting `isProtectedDataAvailable` at launch (it reads false on an unlocked phone inside the app's
  initializer, ADR 0016); reading the preferences file's protection directly (an implementation detail of the
  system); refusing to run at all before the unlock (the push handler's fetch and the log's own deferral are
  wanted).
