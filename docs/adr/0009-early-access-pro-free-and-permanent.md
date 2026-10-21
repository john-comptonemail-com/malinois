# ADR 0009: Early-Access — Pro is free and permanent for every install made while the program is open

- **Status:** accepted
- **Date:** 2026-09-04

## Context

Malinois is monetized by a one-time $9.99 Pro unlock behind a 30-day trial (the paywall
spec; SECURITY.md "Free vs Pro"). On 2026-09-04, with four installs on the store and 1.3 about
to ship, the owner ruled that the goal for now is a user base — "say 1,000 installs" — before
Pro matters, that monetization should still come eventually, and that the way there has to be
the most ethical one available. Three constraints bound the design:

- Apple offers no way to price an in-app purchase at zero, and its promo codes are
  single-use and expiring, so "free for the first X" cannot be expressed in App Store Connect.
- The app has no account and no server (the privacy policy's whole premise), so "who was
  early" has to be answerable on the device and, ideally, follow the person to a new device.
- Nobody may later lose what they were told they keep, and nobody may pay for something that
  is free at the time — the two rules that make a free period honest rather than a hook.

## Decision

1. **The program is a build-time flag.** `ProEntitlements.earlyAccessProgramOpen` is `true`
   in 1.3. While it is true, `resolvedStatus` grants `.earlyAccess` — Pro for every gate — to
   any install that has not purchased, and a first launch writes a **membership marker**.
2. **The marker is a promise to the person.** `KeychainService.earlyAccessMember` is a
   Keychain item, so it survives deletion, written as a *synchronizable* item so iCloud
   Keychain carries it to the owner's next phone, with a device-only fallback if the
   synchronizable write is refused. It is never cleared by the app.
3. **Closing the program cannot demote a member.** The build that ends Early-Access flips
   the flag and changes nothing else: `resolvedStatus` returns `.earlyAccess` for a member
   whether the program is open or closed. Only installs after that build see the 30-day
   trial and the paywall, which stay in the code, dormant, for that day.
4. **The purchase stays, as support.** The IAP remains visible and buyable during early
   access (so App Review can exercise it, and so a user who wants to can support the project),
   and every screen that shows it says that buying adds nothing the owner does not already
   have. The owner's ruling: "Nothing extra beyond support."
5. **The wording is the same everywhere it matters:** *Early-Access installs get Pro free,
   permanently. If Pro ever becomes a paid unlock, that will apply to new installs only.*
   Home, the support screen, the Settings row, the welcome screen, the App Store listing, the
   README and SECURITY.md carry it.

## Consequences

- Existing 1.2 installs — whose 30 days may already have run out — are Pro again under 1.3,
  because the program is open when they first launch it; they become members like anyone else.
- The trial-end local notification is cancelled for members; the first-launch date is still
  recorded, since it is the install date a newcomer's trial would run from later.
- A locked-device background launch before first unlock cannot read the marker (it is
  after-first-unlock, not always-accessible); while the program is open that costs nothing,
  because the open program alone grants Pro. The closing build must keep that in mind (a
  member's Pro must not flicker to `.trial`/`.free` for one background launch).
- The store screenshots taken at "30 days left" on 2026-09-04 show a trial line that no
  longer exists; Home and the support screen are retaken on build 37.
- Paths not taken: removing the IAP and re-adding it later (loses nothing but the purchase
  path, and does not answer who was early); publishing a promo code (single-use, expiring);
  lengthening the trial (gives the free period to everyone who ever installs, not the early
  users, and leaves a clock running). Multi-use offer codes for one-time purchases, if App
  Store Connect offers them, would be a complement — a $0 transaction is the strongest
  possible grandfather — but they are friction for every user and not the main path.

## Home branding clarification — 2026-10-11

Owner approved showing the same small **Pro** label and collar for both a purchase and
Early-Access. Purchasing must not make Pro branding disappear. The purchased badge is
informational; the Early-Access badge keeps its support-screen action. Trial and expired
trial messaging remain separate. This changes presentation, not entitlement resolution.
