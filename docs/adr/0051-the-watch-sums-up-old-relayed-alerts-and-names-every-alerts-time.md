# ADR 0051: The watch sums up old relayed alerts, and every relayed alert names its event's time

- **Status:** accepted (the owner's ruling, 2026-10-18, BACKLOG 134: "1 a 2 a 3 b"); for 1.8 (73). Amends ADR 0043
  (decision 3: the late-alert time becomes a time on every relayed alert, and old alerts are summed up). The wording
  approved as drafted, with one change to how the summary arrives (the owner, 2026-10-18: "approved, and make the
  screen light up/tap"; decision 2). Amended the same day after Codex's review of `c56952a`: decisions 3 and 5 (X1,
  each alert counted once whatever came after it; X2, one record), path 4 (X4), and the tap's TestFlight check (X3);
  and after its second look at `90b4251`: decisions 3 and 5 again (Y1, the summed-up alerts kept whichever summary
  counted them; Y2, 1.6's key written before the record); and after its third look at `1c3deeb`: decisions 3 and 5
  again (Z1, the summed-up alerts kept by their events' times; Z2, the merge takes 1.6's key's order); and after its
  fourth look at `a568ed0` (W1: what happens past the 1,000 stated per copy).
- **Amended 2026-10-19 by ADR 0052** (1.8 (75)): path 4 below is out of date. iCloud reaches the watch from its own
  iPhone also while connected through it, and each iCloud push now passes through the watch's alert extension; an
  old alert joining the summary removes iCloud's copy of its event from the list.
- **Date:** 2026-10-18

## Context

After TestFlight 1.8 (72) the owner turned on an Apple Watch that had been off for four days, and every tamper alert
of those days came through, one by one: "which at that point isn't helpful". The owner also saw disarm alerts
without a time.

Both follow from ADR 0043. The armed iPhone queues every alert for its watch with WatchConnectivity's
`transferUserInfo`, which watchOS delivers in full and in order when the watch comes back, and the watch showed each
one, once per event. A relayed alert named its event's time only when it arrived more than a minute late, so an alert
that arrived promptly, often a disarm, read without one. iCloud's alerts never carry a time: ADR 0046's attempt
stopped iCloud's pushes and was removed in 1.6 (67).

Options put to the owner (BACKLOG 134): for old alerts, one quiet summary with a fixed hour (A), the same with a
setting (B), or dropping them with no summary (C); for the time, on every relayed alert (A) or only when late (B);
in the release after 1.8 (A) or in 1.8 as build 73 (B). Ruled: A, A and B.

## Path inventory: every way an alert reaches the watch

1. **WatchConnectivity `sendMessage`**, the live copy the iPhone sends while the watch app is reachable. Lands in
   `session(_:didReceiveMessage:)`. Covered by decisions 1 to 5.
2. **WatchConnectivity `transferUserInfo`**, the queued copy the iPhone sends of every alert. Lands in
   `session(_:didReceiveUserInfo:)`, in a background wake that is held until the alert is handled (ADR 0043), or at
   launch. After days off, the whole queue arrives in order, possibly over several wakes and launches. Covered by
   decisions 1 to 5.
3. **The iPhone's outbox**: alerts sent while the iPhone's link is still activating (at most 20) go out later through
   paths 1 and 2, with their event's own time, so the same rules apply.
4. **iCloud's subscription pushes**: alerts from the owner's other devices, and from the watch's own iPhone while the
   watch is not connected through it. watchOS shows them itself, from the push; the app only records them for its
   screen (`didReceiveRemoteNotification`). Not covered and not changed: the push carries no time (ADR 0046), and the
   watch app has no notification extension that could hold an old one back. For a device that is off, APNs keeps one
   push per app, which Apple says is usually the most recent but does not promise (Codex's X4), so after days off at
   most one arrives, and it may not be the latest.
5. **iOS's forwarding of the iPhone's own notifications**: the armed iPhone stays unlocked in the foreground and does
   not forward them (ADR 0043). Not changed.

Nothing changes on the iPhone: the message, which events send it (first-hand incidents, disarms and cancelled
countdowns, with Cross-device alerts on and Pro active), the outbox and the history rule at unlock.

## Decision

1. **The age rule.** A relayed alert whose event is more than one hour old when the watch handles it, by the watch's
   clock against the event time the iPhone sent, is not shown on its own: it joins the summary. A fixed hour, no
   setting. An event time ahead of the watch's clock counts as new. Every other relayed alert is shown as before:
   with sound, and Time Sensitive for a tamper (ADR 0045).
2. **One summary, one tap.** Each old alert posts the summary again under the same identifier, with the new count and
   the latest event (by its time), which replaces the copy before it. The summary's first post lights the screen and
   taps: the ordinary level with the alert sound, as the relayed disarm alert has, not Time Sensitive (the owner,
   2026-10-18: "make the screen light up/tap"; the draft had it silent). Each later post of it is passive and silent:
   the count changes in the notification list without lighting the screen, so a burst taps once. While the watch app
   is open, the first post shows as a banner, as other alerts do, and the quiet updates are listed only. An old alert
   handled more than an hour after the summary last changed starts a new summary under a new identifier, which taps
   again, so a later absence is not added to an earlier one, and an earlier summary is never replaced by a smaller
   count.
3. **Across wakes and launches.** The summary (its identifier, its count, its latest event's kind and time, and when it
   last changed) is kept on the watch, so old alerts delivered over several background wakes, or after watchOS ended
   the app, join the same summary. It is kept in one record with the alerts shown on their own and the alerts summed up
   (`com.malinois.watch.relayMemory`), written once after each post, so an interruption cannot keep one without the
   others (Codex's X2: in two writes, a crash between them could leave the shown alerts ahead of the summary, which
   then lost a count and its latest event). The alerts shown on their own are also kept under 1.6's key, for 72
   installed over this build, written before the record and only when they change, so that key is never behind the
   record: what it holds at launch, and the order it holds it in, is the newer (a post the watch stopped between the
   two writes, or 72's). The merge puts the alerts only the record holds first, then the key's in its own order, and
   keeps the newest 500 (Codex's Y2: written after the record, the key could be left behind, and at the 500 the merge
   then brought back an alert already forgotten and pushed out one still remembered; Codex's Z2: keeping the record's
   place for an alert in both, the merge pushed out one 72 had just shown again). A record that cannot be read is
   ignored; a summary in it that cannot be trusted (a count out of range, an identifier that is not a summary's) is
   dropped, and the next old alert starts a new summary.
4. **The time on every relayed alert.** Every relayed alert shown on its own names its event's time, tamper and disarm
   alike, on time or late: "Tamper detected on your device at 9:04 PM.", with the date when the event was on another
   day ("... at Oct 15, 3:42 PM."). This replaces ADR 0043's "more than a minute late".
5. **One at a time, each event once.** Relayed alerts are handled one after another, live and queued alike, in the
   order the watch app hands them to the inbox, so an earlier post that finishes late cannot overwrite a later count.
   Each event is handled once, by two memories kept across launches. The watch remembers the alerts summed up, the
   1,000 with the newest events, whichever summary counted them, so a copy of one is not counted again, in that
   summary or a later one (Codex's Y1: kept in the summary itself, they were forgotten when a new summary started).
   They are kept by their events' times, not as they arrived. An alert outside the 1,000 kept (as old as, or older
   than, every alert remembered) is counted each time a copy of it arrives, since nothing remembers it, but it is
   never kept, so it pushes out no alert remembered and starts no chain (Codex's Z1: kept as they arrived, each such
   copy pushed out the next, and a replay of 1,001 was counted in full; Codex's W1: "counted once" said only what one
   copy does). The ledger remembers
   the alerts shown on their own: the newest 500 (50 until this build), so the late queued copy of an alert shown
   live is recognized. A summed-up alert is remembered among the summed-up ones only, never in the ledger: a burst of
   old alerts cannot push out the shown alerts whose queued copies are still to come (Codex's X1: with one shared list
   of 50, the late copies of 51 alerts shown live each pushed out the next one's memory, and all were counted). Past
   the 500, the late copy of a shown alert forgotten arrives old and is summed up, as above, pushing nothing out of
   the ledger; arriving within the hour it would be shown again, and pushing out the next only if more than 500
   alerts had been shown in that hour with their copies still to come. An alert is remembered, and
   the summary kept, only once its post succeeded (ADR 0043, 65); a copy that arrives while the first is being posted
   now waits for it, and is posted only if the first failed.
6. **A damaged time.** A message whose time is not a finite number is not one this app sent, and is ignored like any
   other unknown message.
7. **Where the code lives.** The handling moves from `WatchAppDelegate` into `WatchRelayInbox`
   (`MalinoisWatch/WatchRelayInbox.swift`), which the test target compiles as it does `WatchAlertStatus.swift`, with
   the clock, the stored state and the notification centre passed in. `WatchAppDelegate` keeps the link, the wakes
   and the screen's record.

## The wording (approved by the owner, 2026-10-18)

- Tamper, shown on its own: "Tamper detected on your device at 9:04 PM."
- Disarm or cancelled countdown, shown on its own: "Malinois was disarmed on one of your devices at 9:04 PM."
- The summary, title "Malinois": "While your watch was away: 5 Malinois alerts, the latest a tamper at Oct 15,
  3:42 PM. See your iPhone's Event Log." With one alert: "While your watch was away: 1 Malinois alert, a tamper at
  Oct 15, 3:42 PM. See your iPhone's Event Log." "a disarm" when the latest is a disarm or a cancelled countdown.
- Times as above: the time alone when the event was on the day the text is written, otherwise the date too.

## Consequences

- After days off, the wrist shows the last hour's alerts as before, now with their times, and one summary for the
  rest, which taps once; the iPhone's Event Log holds the detail.
- An alert that really did wait more than an hour (watchOS delayed its wake, or the watch was out of range) is summed
  up too, and taps only if it starts a summary: the owner chose a fixed hour. While the watch was away from its
  iPhone, iCloud's copy, if the watch had its own connection, arrived earlier.
- The summary's first post carries the alert sound, which is what makes the watch tap; like the other relayed alerts
  it sounds as well unless the watch is silenced. It is not Time Sensitive, so a Focus can hold it.
- On the watch the two paths now read differently: an alert from its own iPhone always names a time, one through
  iCloud never does.
- The rule compares two clocks, the iPhone's (the event) and the watch's (now); they normally agree, since the watch
  takes its time from the iPhone.
- Stored data: one new value on the watch, the record (`com.malinois.watch.relayMemory`, at most 500 shown alerts'
  and 1,000 summed-up alerts' identifiers, the latter with their events' times, about 120 KB). 1.6's key
  (`com.malinois.watch.shownRelayIDs`) is written
  before it with the alerts shown on their own, when they change, and read at launch beside it (decision 3): the
  first launch of this build takes the alerts 72 remembered, and after 72 is installed over this build and this build
  again, what 72 added is recognized.
  The watch app updates with the iPhone app; an older watch app (or a TestFlight tester going back) ignores the record
  and shows every alert, and the message is unchanged, so every iPhone version from 1.6 works with this watch app and
  this iPhone with older ones.
- Tests: pure tests of the rule and the texts, and tests through `WatchRelayInbox` with an injected clock, store and
  poster (the order of posts, the replacement, the first post's tap and the quiet ones after, wakes and relaunches,
  each event once within both memories' limits, across a new summary, and what happens just past each limit, the one
  record, an interruption after either write of a post at the 500, failed posts). WatchConnectivity's real deliveries,
  background wakes, whether watchOS replaces a delivered notification silently, and the tap itself are covered only
  by TestFlight. Codex's X3: Apple promises that a post was scheduled, not shown, before the next one under the same
  identifier replaces it, so a fast burst could take the first post's tap before watchOS shows it. TestFlight checks
  for exactly one tap and the full count; if the tap is lost there, the first update will wait until watchOS lists
  the summary as delivered.
- Not taken: a setting (option B); dropping old alerts without a word (option C); posting the summary once at the end
  of a wake (a wake can end early, and nothing says when the last of several wakes has come); one fixed summary
  identifier (a later absence's smaller count would replace an unread larger one).
