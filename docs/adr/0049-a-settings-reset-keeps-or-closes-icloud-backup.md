# ADR 0049: A settings reset keeps the owner's iCloud choices, or turns backup off

- **Status:** accepted
- **Date:** 2026-10-17

## Context

When the stored settings cannot be decoded (one damaged or unknown value fails the whole decode), the
app sets them aside and starts from the defaults, and Home says so (review finding 16). The defaults
include iCloud backup and cross-device alerts on, so an owner who had turned backup off (ADR 0047:
turning it off needs Face ID, Touch ID or the passcode, and leaves a log entry) found new events
uploading again, and Home's notice named only the tripwires and Guided Access. The top-down review of
1.7 (item 120, F12) asked for the reset to fail closed for privacy, or to say so. The usual cause of a
reset is not damage: an older build, installed over a newer one (TestFlight testers can go back),
cannot decode a value the newer one stored, while the rest of the settings, the iCloud switches
included, are still plain JSON.

## Decision

The owner's ruling (2026-10-17, option B of three):

- On a reset, the iCloud backup switch and the cross-device alerts switch are read from the damaged
  settings when they are still there as JSON booleans, and keep the owner's values.
- When the backup switch cannot be read (the data is not JSON, the key is missing, or the value is not
  a boolean), backup is off. Cross-device alerts that cannot be read keep their default (on): they
  reach only the owner's own devices; with backup off none goes through iCloud, while this iPhone's
  paired Apple Watch still gets its alerts directly (ADR 0043; ADR 0047 keeps that relay).
- The reset is still announced as before, and Home's backup-off notice (item 120, F1) says that backup
  is off whenever it is, on Pro. No new wording.

## Path inventory

What decides whether anything leaves the phone after a reset:

- `AppSettings.load()`, at launch, before any screen or the engine reads the settings: the only place
  the reset happens. It builds the defaults, applies the salvaged or closed values and stores them at
  once, over the damaged settings it has set aside. (Codex's review of 1.8, V1: the damaged settings
  used to be removed first and the new ones left to the 0.4-second autosave, so a relaunch inside that
  window found none and started from the defaults, backup on.)
- Readers of `cloudBackup`, all unchanged and all reading the loaded value: the engine's `backupAllows`
  (every upload), the store's `keepsNewEventsLocal` (an event recorded while backup is off is kept
  local for good), the enrollment's `holdsNewEventsLocal`, the uploader's `backupPermits` and `backupOn`,
  the heartbeat, and the Home, arming, countdown and Settings screens.
- Writers: `load()`, and the engine's `setCloudBackup` (the Settings switch), unchanged.
- Not a reader: the watch relay (`WatchAlertRelay`, ADR 0043) sends this iPhone's own alerts to its
  paired watch whatever the backup switch says, following the alerts switch and Pro (ADR 0047).
- Older versions: no new field. An older build reading the settings this build stored after a closed
  reset reads backup off, and keeps it off.

## Consequences

- An owner who had backup off keeps it off through a reset; an owner who had it on keeps it on where
  the switch can be read, which is the usual case.
- Where the switch cannot be read, events recorded until the owner turns backup back on are kept on
  the phone for good (ADR 0047's rule for events recorded while backup is off). That is the cost of
  failing closed; Home says backup is off from the first launch after the reset.
- A reset that turns backup off writes no "backup turned off" entry: whether it was on before cannot
  be known, and the entry would claim a change that may not have happened.
- Not chosen: backup off after every reset (option A), which would turn off an owner's backup at every
  downgrade of a TestFlight build; and keeping the defaults with a notice (option C), which uploads what
  the owner may have chosen to keep.
- Other settings still reset to their defaults on a reset, as before; reading more of them back from
  the damaged data is not part of this decision.
- Since 1.8.1 (ADR 0055) the reset sets retention to Keep forever rather than the 12-month default, so a
  reset never starts deleting iCloud media; and a store that cannot be read before the phone's first
  unlock after a restart is not a reset: the settings wait for the unlock.
