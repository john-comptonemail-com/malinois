# ADR 0058: Apple's rating request after the third calm disarm

- **Status:** accepted
- **Date:** 2026-10-24

## Context

Malinois had one App Store rating and never asked for one: nothing in the app called Apple's rating request. Visitors
read an app with no ratings as untested, and Apple weighs ratings in search (BACKLOG 136 and 137). Guideline 5.6.1
allows only Apple's own request, and iOS decides whether to show it, at most three times a year. The moment matters: a
security app must never put a prompt in front of the owner while a watch starts, after a tamper, at a PIN pad, or under
Guided Access, when the owner is setting the phone down or dealing with what happened.

## Decision

1. **Apple's request only** (StoreKit's `requestReview`, from SwiftUI's environment), never a custom prompt or a
   pre-prompt.
2. **After a calm disarm, from the third on.** A disarm that ended a live watch (`armedSince` set) with no incident in
   it counts as calm; the owner's own handling at the pad, which the disarm marks as the owner's, and other devices'
   copies do not make it a tamper. A countdown cancelled before it went live is not a watch. The count lives on this
   device (UserDefaults, `com.malinois.rating.calmDisarms`); a watch with an incident resets nothing, it simply does not
   count (`MonitoringEngine.noteDisarmForRatingRequest`, `ratingRequestDue`, pure).
3. **Home makes the request**, once a calm disarm has flagged it, when nothing else is on screen: no PIN pad up and
   Guided Access off (`HomeView.mayAskForRating`, pure); otherwise when Home appears again, Guided Access ends or the
   pad closes. Each calm disarm from the third on flags it again; iOS limits what is shown. A request still waiting
   when the next watch starts lapses, and a watch with an incident leaves none: it was for the calm watch that raised
   it (Codex's codex-16 found one surviving a later tamper and asked just after it).
4. Nothing is sent or tracked; Malinois never learns whether a rating was left.

## Consequences

- An owner who arms and disarms routinely is asked, by Apple's sheet, after the third quiet watch, and at most three
  times a year after that, as iOS decides.
- An owner whose watches keep catching tampering is not asked: that is not a moment to ask, and the count does not
  move.
- Not taken: asking at a launch or after a set number of days (no link to a good moment); asking after a tamper the
  owner reviewed (the wrong mood); a custom "Do you like Malinois?" pre-prompt (guideline 5.6.1, and a dark pattern).
- Tests: `Item137RatingRequestTests` (the rules, and the engine's count across calm, tampered and cancelled watches).
  The request itself is Apple's and is not observable in a unit test.
