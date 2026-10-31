# ADR 0056: Face ID or Touch ID unlock is bound to the faces or fingers enrolled when it is turned on

- **Status:** accepted (the owner's ruling on BACKLOG 152, 2026-10-22: 1.8.1 takes the audit's recommended fixes;
  lead 4). In 1.8.1 (78), BACKLOG 145 step 13.
- **Date:** 2026-10-22

## Context

Since item 30 (option A) the owner may open the two read surfaces, the Event Log and Test Sensors, with Face ID or
Touch ID instead of the PIN; the setting is off by default, and Settings, disarming and changing the PIN never
accept a face or finger. The pad evaluated iOS's biometric policy and opened on any success. iOS lets whoever knows
the iPhone passcode add a face (an alternate appearance) or a finger in iOS Settings, so someone who knows that
passcode but not the Malinois PIN could add their own and open, export and clear the log, with no record of the
open (the audit's lead 4; SECURITY.md says the PIN, the Guided Access passcode and the device passcode are separate
controls, and PIN setup advises a code different from the iPhone passcode). Whether iOS lets the passcode alone add
a face on a given configuration is a device fact; the binding is cheap either way.

iOS reports the enrolled set as an opaque state that changes when a face or finger is added or removed
(`LAContext.domainState.biometry.stateHash` on iOS 18 and later, `evaluatedPolicyDomainState` before, both set after
a successful `canEvaluatePolicy` for a biometric policy), leaves the comparison to the app, and warns that the value
can change between major iOS versions even when nothing was enrolled or removed.

## Decision

1. **Turning the unlock on binds it.** Settings' toggle (behind the PIN) records the state iOS reports at that moment
   in the Keychain, this device only, readable while the phone is unlocked (`KeychainService.enrolledBiometricState`).
   Turning it off clears the record. With nothing to read (no biometric enrolled) or a write refused, the unlock turns
   on unbound.
2. **The pad offers the biometric only while bound.** After the four existing gates (the caller allows it, the owner
   opted in, no lockout, no Guided Access) and iOS's own check that a biometric can be evaluated, the pad compares the
   state iOS reports now with the record (`BiometricBinding.verdict`, pure): equal is bound, nothing on record is
   unbound, anything else is changed. Bound, the offer goes ahead as before.
3. **Unbound or changed, the unlock turns off and the pad says why.** The setting turns off and the record is cleared
   before any prompt; the pad keeps the PIN pad standing with a caption: for a change, that a face or finger was added
   or removed and that Settings turns the unlock on again; with nothing on record, that this version ties the unlock
   to the enrolled set and Settings turns it on again. The PIN is never blocked. Off stays off until the owner, behind
   the PIN, turns it on again, which binds it afresh.
4. **An install updating with the unlock on is asked once.** Nothing is on record at the update, so the first offer
   turns the unlock off with the second caption, and the owner turns it on again in Settings. The alternative, seeding
   the record at the update's first launch, would trust whatever is enrolled then without the owner's word; the
   owner's precedent (ADR 0054, option A over B) prefers the explicit step. The toggle's caption says the unlock is
   tied to the enrolled set and turns off when it changes.

## Path inventory

Nothing here leaves the phone: no upload, no record in the log, no alert, nothing to the watch.

- Writers of the record: Settings' toggle through `BiometricBinding.setUnlock` (on records, off clears); the pad's
  `checkBeforeOffer` (clears when it turns the unlock off); the Debug-only test wipe.
- Readers: the pad, before every offer (`PINEntryView.tryBiometrics`, after `canEvaluateBiometrics`). The gates that
  never offer a biometric (disarm, the recovery re-arm's pad, the change-PIN pad, Settings, the ARM tap's pad of ADR
  0054) never reach it.
- The setting itself: `AppSettings.biometricUnlock`, written by Settings and now by the pad (off), saved by the
  autosave; not a protection setting (item 91 records no change for it, as before).
- Older versions: a 1.8 build installed over 1.8.1 ignores the Keychain item and offers the biometric as before; the
  item lingers and is harmless. The reinstall recovery (ADR 0040) does not count it among the PIN's fragments.
- Not covered: a real change of enrolment (a TestFlight check: add an alternate appearance, open the Event Log, the
  caption shows and the toggle is off; turn it on again, the offer returns); a major iOS update changing the state
  without an enrolment change (the SDK's warning), which reads as a change: the unlock turns off once and the owner
  turns it on again.

## Consequences

- A face or finger added with the iPhone passcode after the opt-in opens nothing in Malinois; the PIN does.
- The owner meets the caption once after an enrolment change, after a major iOS update that changes the state, and
  once after updating to 1.8.1 with the unlock on; each time Settings turns it on again with the PIN.
- The simulator enrolls nothing, so the tests inject iOS's state and the evaluation answer through Debug seams and
  drive the real pad; the Keychain tests skip on an unsigned build, as the suite's others do.
- Not chosen: a Keychain item with `.biometryCurrentSet` access control (its documentation names added fingers and
  Face ID re-enrolment but not alternate appearances, and it would move the PIN's fragments); seeding the record at
  the update (decision 4); turning the unlock off at launch rather than at the pad (the pad is where the owner can
  read why, and where the PIN is at hand).

## Amendment (2026-10-25, 1.8.2): a change of the unlock is recorded

Since 1.8.2's step 22 (ADR 0019's amendment of 2026-10-24), Face ID unlock is one of the protection settings whose
change leaves a record in the log at the next comparison (Settings closing, or the next arm): switched on or off in
Settings, or switched off by the pad when the enrolled faces or fingers changed, its "off" not saying "in Settings".
The record uploads as every status record does, with iCloud backup on. The binding's Keychain item still stays on
this phone and goes nowhere. The path inventory's "no record in the log" and "not a protection setting" are superseded
on that point (Codex's codex-5 on the full review of 1.8.2, BACKLOG item 165's F2).

## Amendment (2026-10-29, 1.9): iOS 18 is the minimum

The iPhone app now requires iOS 18. `BiometricBinding.state(of:)` always reads
`LAContext.domainState.biometry.stateHash`; the iOS 17 `evaluatedPolicyDomainState` branch is removed.
The state comparison, Keychain item, PIN fallback and explicit re-enrolment remain unchanged. A stored hash
that differs after an operating-system upgrade still turns biometric unlock off and leaves the PIN available;
it is never silently rebound. The existing tests inject the same state and evaluation seams on both supported
simulator runtimes; real biometric enrolment and major-OS-upgrade behavior still require device checks.
