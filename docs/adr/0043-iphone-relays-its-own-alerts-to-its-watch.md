# ADR 0043: The armed iPhone relays its own alerts to its paired watch

- **Status:** accepted (owner's ruling, 2026-10-12, "A, go ahead"); for 1.6 (60). Amends ADR 0042:
  the watch now hears its own iPhone's alerts over a direct link, and makes one iCloud server call.
  Amended for 1.6 (61) after TestFlight 1.6 (60): decision 3's wake rule and late-alert time, the
  screen's path line, and what the TestFlight showed about reach (Consequences). Amended for 1.6
  (62) after the independent review: decision 1's terms stated exactly and the history read at
  unlock, decision 2's wait for activation, decision 3's lasting memory and wake expiration. Amended
  by ADR 0045 (63): the relayed tamper alert is Time Sensitive. Amended for 1.6 (65) after the
  1.6 reviews (BACKLOG 108, CE-03): decision 3 remembers an alert only once it was posted.
  Amended 2026-10-13 (BACKLOG 110): the complication option, and a Live Activity tried in its place, give no
  faster tap; the relay stays (Consequences).
- **Date:** 2026-10-12
- **Amended 2026-10-17** (1.8, BACKLOG 124's F10): decision 1 relays a cancelled countdown too.
- **Amended 2026-10-18 by ADR 0051** (1.8 (73), BACKLOG 134): decision 3's late-alert time becomes a time on every
  relayed alert, the watch sums up relayed alerts more than an hour old in one summary that taps once, and it
  remembers the newest 500 alerts shown on their own (decision 3's 50).
- **Amended 2026-10-19 by ADR 0052** (1.8 (75), BACKLOG 140): iCloud now reaches the paired watch also while it is
  connected through its iPhone (TestFlight 1.8 (74): iCloud's copy about 8 seconds before the relay's), so the watch
  pairs the two copies of an event: one tap, and one entry with the time.

## Context

1.6 (59) on TestFlight: the watch app signed up for pushes and the iCloud alert subscriptions
reached it, about 2 seconds after the iPhone, when the iPad mini was armed. When the watch's own
iPhone was armed, nothing reached the watch, near the phone or on Wi-Fi only, while the iPad mini
alerted at once. Apple's CloudKit note says the device that made a change receives no notification
for it (QA1917), and developer reports say this covers its paired watch. The one-iPhone owner, the
reason for the watch app, therefore got no alert on the wrist.

The armed iPhone stays unlocked in the foreground, so iOS does not forward its own notifications to
the watch either. Options weighed: a direct link from the iPhone to its watch (chosen); shipping the
watch for alerts from other devices only; holding the watch back from 1.6. A push server was ruled
out: Malinois has none by design.

## Decision

1. **The iPhone relays its own alerts.** A relay, started with the app's services before the
   monitoring engine, watches the event log. Each new first-hand incident sends the tamper alert and
   each new first-hand status entry that iCloud alerts on the disarm alert: a disarm, and since 1.8 a
   countdown someone cancelled, by iCloud's own rule (`disarmSignalWanted`; item 124's F10: the
   cancelled countdown reached no watch), while this iPhone's Cross-device alerts setting is on
   and Pro is active. Another device's events (which come through iCloud) and the other status
   entries send nothing, and neither does the log read at unlock after a launch while the phone was
   locked: that is history, not news (62). The monitoring engine is not changed. The setting is this
   iPhone's own: turning alerts off from another device removes the iCloud alerts at once, but this
   relay follows this iPhone's switch, which also restores the subscriptions at this iPhone's next arm
   (as before 1.6); gating the relay on the account's state would need a network check per alert and
   end its offline delivery.
2. **WatchConnectivity, never iCloud.** The message goes over Bluetooth or shared Wi-Fi: sent at
   once while the watch app is open, and always queued, which watchOS delivers by waking the watch
   app in the background. Alerts sent while the link is still activating (a relaunch writes its
   interruption record within milliseconds) wait, at most 20, and go out when it activates with a
   watch (62). It carries the iCloud alerts' fixed texts, the event's ID and its time; no device,
   sensor or evidence detail.
3. **The watch shows each event once.** It activates its end of the link at launch, holds each
   background wake until the link has handed over everything queued and every alert it handed over
   has been posted (the link reports nothing pending once it has handed an alert over; 61), and
   shows each relayed alert as a local notification, keyed by event and remembered across launches
   (the newest 50; 62; the newest 500 shown on their own since 1.8 (73), ADR 0051), so a repeat
   delivery is not shown twice. An alert is remembered, and
   recorded as the last alert seen, only once its post succeeded: remembered first (62), a post
   that failed was never tried again, though the iPhone sends each alert twice while the watch app
   is open. A copy arriving while the first is still being posted is not posted as well (65). Each held wake has an expiration
   handler, and a failed activation ends it (62). A relayed alert arriving more than a minute after
   its event names the event's time,
   so a copy that waited for the watch to come back in range does not read as a new event (61);
   since 1.8 (73) every relayed alert names its time, and one more than an hour old joins one
   summary instead, which taps once (ADR 0051). Its
   screen shows the iPhone link, the last alert seen and, when known, which path brought it (61).
4. **One iCloud server call.** When the watch app opens it lists the account's subscriptions,
   reading no event records, to confirm the tamper alert exists; its screen says if Cross-device
   alerts are off or the check failed.

## Consequences

- Reach, as TestFlight showed it (owner, 2026-10-12). On 60: with the watch nearby the relay
  brought both alerts; with the phone on cellular and the watch on Wi-Fi with its Bluetooth off,
  both arrived almost at once, so iCloud's rule appears to drop a watch's alerts only while the
  watch is connected through its own iPhone. With both on the owner's guest Wi-Fi and the watch's
  Bluetooth off, 60 lost the tamper alert and brought the disarm alert about 15 s late; 61, with
  decision 3's wake rule, delivered there, so the lost alert was the wake bug, not the network. A
  home Wi-Fi was not available to test; it is expected to behave at least as well. Alerts from the
  owner's other devices still arrive through iCloud wherever the watch has a connection.
- watchOS decides when to wake the watch app for a queued message: on the owner's watch, seconds
  to minutes over Bluetooth (1.6 (65) to (67)). A watch-face complication was to get priority
  delivery, but Apple's engineers say that channel does not work with today's (WidgetKit)
  complications, and the older ClockKit kind is deprecated. A Live Activity on the armed iPhone,
  tried instead with a test app, reached the watch at once, even unlocked under Guided Access, but
  never tapped, while Malinois's own alerts do (BACKLOG 110, 2026-10-13). Neither is built; without
  a push server, the relay is the practical limit.
- The relay works without internet over Bluetooth, since the link is local: the alert can reach
  the wrist even when iCloud cannot be reached. Alerts queued while the watch was out of reach
  arrive when it is back, dated (decision 3), possibly after iCloud's copy; since 1.8 (73) those
  more than an hour old arrive as one summary that taps once (ADR 0051).
- The watch still shows the iCloud alerts from other devices, and a disarm of its own iPhone now
  reaches it through the relay, as the disarm alert reaches other devices.
