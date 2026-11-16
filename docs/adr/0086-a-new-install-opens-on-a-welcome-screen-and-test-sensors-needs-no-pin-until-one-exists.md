# ADR 0086: A new install opens on a welcome screen, and Test sensors needs no PIN until one exists

- **Status:** accepted. BACKLOG item 240, round one; the design `docs/design/onboarding.md`, APPROVED 2026-11-12 (the
  owner: "D1-D3 and V1-V3 (a), wording approved"). Built in round one (red `dbed2847`, fix `9e5c84e8`); written down on
  2026-11-13, when the round's documents were found missing before 1.13's review (the owner, 2026-11-13: "wording
  approved").
- **Date:** 2026-11-13

## Context

A new install opened on "Create a PIN", and nothing said what Malinois does. Test sensors, the safe way to see it work,
was behind the PIN: it lists the tripwires that are on and their live thresholds, which an owner's settings should not
show a stranger (SECURITY.md).

## Decision

1. **Only on an install with nothing to protect,** Malinois opens on a welcome screen: no PIN in the Keychain and no
   sign of an earlier install (no completed setup, no events in its folder, no piece of an earlier PIN in the Keychain:
   `KeychainService.pendingRecovery`). A reinstall that kept its PIN goes to PIN continuity (ADR 0040), and a missing
   PIN with events goes to recovery, as before, so an owner's phone is never brought back to it.
2. **The welcome screen** shows the App Store description's first sentence and the own-device sentence, with **See it
   work** and **Set a PIN**.
3. **See it work opens Test sensors without a PIN,** since none exists; Done returns to the welcome screen. Nothing is
   recorded. A new install's tripwires (motion, power, proximity and touch) need no permission, so no prompt appears.
4. **Set a PIN** opens PIN setup, then Home. From then on Test sensors is behind the PIN (or the face or finger the
   owner allowed for it), as before.
5. **After the first disarm,** Home shows a card once, leading to the Event Log through the usual gate; only an install
   that had not armed before sees it.

## Consequences

- Test sensors' list of tripwires and thresholds can be seen without a PIN only while it shows a new install's
  defaults; SECURITY.md's gate sentence says "once a PIN exists".
- Tests: `Item240OnboardingTests`, among them the welcome screen only with no PIN, a reinstall going to PIN continuity
  and never to the welcome screen, the routing and only the welcome screen opening Test sensors, and the card once.
