# ADR 0082: The watch writes down each relayed alert until it is shown

- **Status:** accepted. BACKLOG item 219, in 1.13 (item 240's list); the design `docs/design/1.13-fixes.md`, part 1,
  APPROVED 2026-11-12 (the owner: "as you recommend, wording approved": D1 and D2 as (a)). Supersedes in part ADR 0079
  (decision 1's last sentence, and its consequence naming item 219).
- **Date:** 2026-11-12

## Context

The armed iPhone relays each alert to its paired watch twice: live while the watch app is open, and queued
(WatchConnectivity's `transferUserInfo`), which watchOS hands to the watch app once, waking it in the background if it
must (ADR 0043). The watch app holds that wake until the alert is handled, but gives it back after 10 seconds at the
latest, since watchOS ends an app whose wake runs past 15 (ADR 0079, item 212). Until the inbox had posted it, the
alert existed only in the app's memory: an alert whose handling the wake's end cut off was shown when the app next ran,
or lost if watchOS ended the suspended app before then (item 218's Codex-2). The live copy needs nothing of its own: the
queued copy of the same alert always follows.

## Decision

1. **Each queued alert is written down before the hand-over returns** (`WatchRelayOwed.note`, called in
   `session(_:didReceiveUserInfo:)` on the link's own thread, under a lock): its kind, its event's ID and time, in the
   watch app's settings beside the record of alerts shown.
2. **It is taken off once the inbox has handled it:** posted on its own, added to the summary, or passed over as one
   already shown or counted. It is taken off after the record of alerts shown is written; the two share the alert's
   notification identifier, so a stop between the two writes leaves it on both, and the next run passes it over: it is
   never shown twice, and never on neither.
3. **The alerts left are handed to the inbox at each launch** (before the link can hand new ones over) **and at each
   wake for the link,** oldest first, counted in flight, so a wake is held for them as for new ones and given back at
   its deadline as now. One still in hand is not handed in again. One handled more than an hour after its event joins
   the summary, as any late alert does (ADR 0051).
4. **A post watchOS refuses leaves the alert owed;** it is tried again at the next launch or wake, three tries in all,
   then dropped with a log line (the owner's D1).
5. **The list takes the newest 100 by their events' times,** with no age limit (the owner's D2). A list that cannot be
   read starts again empty, as the record of alerts shown does.

## Consequences

- An alert the wake's end cuts off is shown at the next launch or wake, also when watchOS has ended the app meanwhile.
  How soon depends on watchOS: the next wake comes with the next alert the iPhone relays, or the owner opening the app.
- A post refused three times is not shown; watchOS refuses a post only rarely (an invalid request), and an alert it
  will never take would otherwise be tried at every wake.
- The watch stores one more list on the wrist: at most 100 alerts' kinds, events' IDs and times, nothing else.
- Not changed: the 10-second deadline, the run's allowance of 2 seconds for reading the notification list (ADR 0079's
  decision 2), the iPhone's side.
- Tests: `Item219WatchOwedAlertsTests`, with the real inbox and the real wakes' keeper; the watch app's own target is
  read from the source tree, since the iPhone's suite cannot build it.
