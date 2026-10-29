# ADR 0052: The watch pairs iCloud's copy of its iPhone's alert with the relay's

- **Status:** accepted (the owner's ruling, 2026-10-19: "A", after TestFlight 1.8 (74)'s step 4; BACKLOG 140); for
  1.8 (75). Amends ADR 0043 (iCloud now reaches the paired watch also through its iPhone, and the watch pairs the two
  copies), ADR 0045 (iCloud's tamper alert is Time Sensitive on the watch too) and ADR 0051 (its path 4). Amended
  2026-10-27 by ADR 0061 (1.8.2): the watch's extension also shows a burst's iCloud tamper alerts quietly after the
  first three. Amended
  2026-10-20 after Codex's look at `62b4b31`: decision 4 (codex-1: the watch app had no remote-notification
  background mode, so no push woke it and nothing tidied; now it has the mode, and also tidies when it opens and at a
  repeat; every pairing or clean-up read of the list has a deadline) and decision 5's exception (e) (codex-2: an
  old event's two taps). Its second look at `a4d2c95`: "proceed to archive"; the deadline's scope stated exactly, and
  the repeat's tidy-up in the alerts' queue written down for 1.8.1 (Consequences). Amended 2026-10-20 for 1.8 (76)
  (BACKLOG 141): that tidy-up now runs beside the queue. Amended 2026-10-20 for 1.8 (77) after TestFlight 76 (the
  owner's "A"): decisions 3 and 5. The relayed copy always asks for an alert as in 74, since the list says iCloud's copy arrived,
  not that it tapped; on the owner's watch, with the app closed, tamper alerts came silently.
- **Date:** 2026-10-19

## Context

TestFlight 1.8 (74), step 4: each tamper reached the watch twice, "one without the time and one time-sensitive one
with the time". Again with the watch connected through the iPhone: iCloud's copy came first, "roughly 8 seconds
before the timestamped alert". In 1.6 (60) iCloud left out a watch's copy of its own iPhone's alert while the watch
was connected through that iPhone (ADR 0043); it no longer does. The relay's copy is queued (`transferUserInfo`) and
arrives when watchOS wakes the watch app, after iCloud's push. Neither route changed in 73 or 74; 73's time on the
relayed copy made the two copies look different.

The two copies name the same event. iCloud's push carries, in the clear beside the subscription's ID, the name of the
record that fired it: `meta-v2-<event>` for a tamper, `disarm-v2-<event>` for a disarm (`CloudExfiltrator`'s
`makeMetaRecord` and `makeDisarmSignalRecord`). The relay's copy is posted under `malinois-relay-<kind>-<event>`. The
event's ID is a random UUID.

A tamper alert must still break through a Focus (ADR 0045). On the watch only the relay's copy did: watchOS shows
iCloud's copy itself, from the push, at the ordinary level, since the watch had no alert extension (ADR 0046). So the
relay's copy could not simply be made quiet.

Options put to the owner: (A) a watch alert extension like the iPhone's, with the watch app pairing the copies; (B)
the watch app alone (one entry with the time, but the tamper's second tap kept for the Focus); (C) the double alert
documented, (A) in 1.8.1. Ruled: A.

## Path inventory: every way an alert reaches the watch

1. **WatchConnectivity `sendMessage`**, the live copy while the watch app is reachable, and
2. **WatchConnectivity `transferUserInfo`**, the queued copy of every alert, in a held background wake or at launch
   (ADR 0043, ADR 0051). Both reach `WatchRelayInbox`: an alert more than an hour old joins the summary, the others are
   shown on their own. Changed: before an alert is posted, the watch's notification list is read for iCloud's copy of
   the same event (decision 3).
3. **The iPhone's outbox**: alerts sent while the link activates go out later through paths 1 and 2. Not changed.
4. **iCloud's subscription pushes**: alerts from the owner's other devices, and from the watch's own iPhone, also while
   the watch is connected through it. Changed: each now passes through the watch's alert extension before watchOS
   shows it (decision 1), and can wake the app, which has the remote-notification background mode since `cca8bf3`;
   the app then tidies the list (decision 4). Whether and when a push wakes the app is up to watchOS.
   For a watch that is off, APNs keeps one push per app (ADR 0051's path 4).
5. **iOS's forwarding of the iPhone's own notifications**: the armed iPhone does not forward them (ADR 0043). Not
   changed.

Nothing is stored: the pairing reads the system's list of delivered notifications each time, right before it acts
(in the extension for each iCloud push; in the app before each relayed post, at a repeat, at each iCloud wake and
when the app opens), and the inbox's memory (ADR 0051), unchanged. Each pairing or clean-up read in the app has a deadline (decision 4). Nothing changes on the iPhone, so an older iPhone app relays the same message
and writes the same record names. The extension ships inside the watch app, so a watch app before 75 has none and
behaves as 74.

## Decision

1. **The watch's alert extension** (`MalinoisWatchNotificationService`) handles each iCloud alert before watchOS shows
   it, from the push and the watch's notification list alone. It reads no record (ADR 0039), stores nothing and never
   changes the words. When the relay's copy of the same event is already in the list (the relay's came first and
   tapped), iCloud's copy is shown quietly: the passive level, without sound. Otherwise a tamper alert is shown Time
   Sensitive, as on the iPhone (ADR 0045), so the first copy breaks through a Focus, and anything else as sent. If the
   extension does not finish in time, watchOS shows the push as sent.
2. **The pair, by event.** An iCloud alert is matched by its subscription's ID and by its record's name, with the
   prefix that subscription's records have (`WatchAlertPairing`). A push from the tamper subscription whose record
   name does not match is not paired but still shown Time Sensitive; a push from neither subscription is left as sent.
3. **A relayed alert, with iCloud's copy already in the list.** Shown on its own, it is posted as before, a tamper Time
   Sensitive with sound, a disarm at the ordinary level with sound, whatever the list holds (since 1.8 (77)). Once it
   is posted, iCloud's copy of the event is removed from the list, which keeps the relay's copy, with the time. An
   old alert joining the summary (ADR 0051) is posted as before, and iCloud's copy of its event is removed too: the
   summary counts it. In 75 and 76 the relayed copy was posted quietly (passive, without sound) when iCloud's copy
   was listed at least as loud as it would be; TestFlight 76 showed that a listed copy need not have tapped: with the
   watch app closed, tamper alerts often came with no tap at all.
4. **Tidying the list.** The watch app removes from the list each iCloud alert for an event it has already handled,
   shown on its own or summed up, or whose relayed copy is in the list: when an iCloud push wakes it (the
   remote-notification background mode, in `MalinoisWatch/Info.plist`), when it becomes active, and when a repeat of a
   relayed alert it has handled arrives (the queued copy after the live one, which is the order when the watch app
   is open). Every pairing or clean-up read of the list in the app (before a post, at a repeat, in each tidy-up) has
   a deadline of 2 seconds: without an answer, a relayed alert is
   posted as in 74, Time Sensitive with sound, nothing is removed, and a background wake still ends in time.
5. **An alert asked for each time; one entry per event.** When the relayed copy comes first (the watch app open), one
   alert: iCloud's later copy is shown quietly. When iCloud's comes first (the watch app closed, the usual order), both
   ask for one, as in 74, and the list keeps one entry, with the time. Both also do: (a) when the two arrive within the
   moment it takes to read the list and post; (b) when the owner cleared the first copy from the list before the
   second arrived; (c) when watchOS does not let the extension read the list; (d) an old event: iCloud's copy, and the
   summary's first post when the relayed copy then starts it (ADR 0051). watchOS and the notification settings
   (haptics, Time Sensitive, a Focus) decide the actual tap: a listed copy need not have tapped (TestFlight 76), and
   Codex's look at 77 asked that no document promise more. An entry left over waits for the next tidy-up.

## Consequences

- iCloud's tamper alerts from the owner's other devices are Time Sensitive on the watch too, as on the iPhone and the
  iPad: they break through a Focus on the wrist.
- A new target: bundle ID `com.johncompton.Malinois.watchkitapp.NotificationService`, registered by Xcode at the
  archive. No entitlements of its own (the watch app's Time Sensitive entitlement covers it, as the iPhone app's
  covers its extension) and no App Group: the list is the only shared state.
- The stale iCloud push a watch gets when it is turned on still taps beside the summary (the extension cannot see
  the summary's memory, exception (e)); the app removes it from the list once the queued copy of its event joins the
  summary.
- The background mode lets iCloud's pushes wake the watch app; it does nothing else, and the app asks for no other
  background time.
- A repeat's tidy-up waited its turn in the queue new alerts use (Codex's second look at `a4d2c95`, observation 1):
  were list reads to stall, each repeat ahead of a new alert could hold it back by up to the deadline. Not seen on a
  device, and reads of the list are local. Since 1.8 (76) it runs beside the queue, each repeat's after the one before
  (`WatchRelayInbox.repeatTidy`; `Item140WatchPairingTests`). So a repeat now returns before its tidy-up ends, and
  watchOS may suspend the app first (Codex's look at 76, not seen on a device): the duplicate entry then stays until
  the next tidy-up, when an iCloud push wakes the app or it opens. The watch
  screen's own read of the newest alert (`refreshLastAlert`, unchanged) has no deadline; it decides nothing.
- Not covered by tests: real CloudKit pushes and their timing on a watch, whether watchOS lets the extension read
  the list (exception (d)), and whether and when it wakes the app for a push. TestFlight 75's steps check both
  orders: the watch app closed (iCloud's copy first) and open (the relay's first).
