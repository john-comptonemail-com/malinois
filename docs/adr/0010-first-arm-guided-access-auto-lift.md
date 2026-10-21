# ADR 0010: The first arm on a fresh install auto-lifts the Guided Access requirement

- **Status:** accepted. Amended 2026-10-13 for 1.6 (65) (BACKLOG 108, the owner's decision 2, "A"):
  an arm under the lift warns that the phone is unlocked (see "Amendment" below).
- **Date:** 2026-09-04

## Context

From 1.3, *Require Guided Access* ships on by default (ADR-adjacent: item 61, owner ruling
2026-09-02) and is migrated on for existing installs (item 65 finding 6). With it on and Guided
Access off, a user-initiated arm is refused; the arming screen offers a logged one-arm lift
("Don't require it for this arm") so a first run still works. Even so, that first run costs the
new user a decision at the worst moment: before they have seen the app do anything, they face a
"Guided Access is required to arm" notice and must either set up an iOS accessibility feature or
find and tap the lift.

The owner's goal for 1.3 is reach — a user base before Pro matters (ADR 0009) — and with it,
minimal friction to the first arm. The owner asked whether to waive the requirement for the
first arm, noting the app already nudges Guided Access after the first session
(`GuidedAccessPromptView`), which is the moment a new user has context for why it matters.

## Decision

The **first arm on a fresh install auto-applies the existing one-arm lift**, and only then:

1. `OnboardingState.hasArmedOnce` (a per-install UserDefaults flag) records whether a watch has
   ever gone live. It flips true the first time a watch reaches covert (`startWatching`), not at
   `beginArming`, so a cancelled first attempt still gets the frictionless path on the retry.
2. `beginArming` calls the pure `shouldAutoLiftGuidedAccessOnFirstArm(hasArmedOnce,
   requireGuidedAccess, guidedAccessOn)` = `!hasArmedOnce && armingBlocked(...)`. When true it
   invokes the same `liftGuidedAccessRequirementForThisArm()` a manual tap would, so the lift is
   logged and pushed as a `gaLifted` audit record.
3. Because the auto-lift reuses `armingBlocked`, it fires **only when the requirement would
   actually block** — requirement on and Guided Access off. A user who has already turned Guided
   Access on gets no lift and no spurious record.

Every arm after the first enforces the requirement. The post-session nudge teaches Guided Access
once, with context.

## Consequences

- Zero taps between install and the first armed session, which is the friction the owner asked
  to remove. The first arm's record honestly shows it ran without the requirement (the `gaLifted`
  event), so the audit trail never overstates protection.
- The security cost is bounded to one session and is narrow: Guided Access defends against the
  app being swiped away or powered off; capture, the log, the alarm, and the next-launch
  interruption record all work without it. The first arm is almost always a desk test.
- A reinstall is a fresh first arm (the flag is per-install), which is acceptable — a reinstall
  is a fresh start, and the lift is still logged.
- Paths not taken: leaving the one-tap manual lift as the only path (kept the friction the owner
  named); moving the requirement to after the second arm (a persistent gate with worse ergonomics
  than a logged first-arm exception); making the first arm silently skip the requirement without a
  `gaLifted` record (would break the honest-trail principle). The crash-recovery re-arm path
  (`reArmAfterRecovery`) already bypasses the Guided Access check and is unaffected.

## Amendment (2026-10-13, 1.6 (65))

Two reviews of 1.6 (64) challenged this decision: armed without Guided Access, the phone is
unlocked behind a black screen, so anyone who picks it up can swipe to the home screen and use
it. Malinois records the touch and tries for a photo but cannot stop them, and monitoring ends
when they leave the app. The first arm is not always a desk test: someone whose first use is for
real, a hotel room on day one, is exposed without being told.

The owner kept the automatic lift (option A, over dropping it for the one-tap manual lift) and
added a warning. Whenever an arm goes ahead under the lift, automatic or chosen, and Guided
Access is off, the arming screen and the countdown say: "Guided Access is off for this arm:
anyone who picks it up can leave Malinois and use your unlocked phone. Stay nearby." The rule is
`ArmingView.showsUnconfinedWarning(liftedThisArm:guidedAccessOn:)`, unit-tested. The owner's
proposed wording said "this first try"; "this arm" keeps it true for the manual lift as well.
An arm with the requirement switched off in Settings shows the arming screen's existing
recommendation, not this warning: that was a deliberate choice behind the PIN.
