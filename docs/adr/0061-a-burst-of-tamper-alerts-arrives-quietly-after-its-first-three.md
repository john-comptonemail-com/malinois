# ADR 0061: A burst of tamper alerts arrives quietly after its first three

- **Status:** accepted (the owner's ruling, 2026-10-27: "16 - 1", on BACKLOG 163's step 16, item 153's MAL-04, after
  check C on 1.8.1); for 1.8.2 (79). Amends ADR 0045 (a tamper alert in a burst is not Time Sensitive) and ADR 0052
  (the watch's alert extension applies the same rule to iCloud's tamper alerts).
- **Amended 2026-10-28** (BACKLOG 169's codex-3, the owner: "1 - yes"): each alert path counts its own record of
  tamper arrivals, not the notification list (decision 1), and the watch app applies the rule to the alerts its iPhone
  relays (path 3). Codex's review of the first version found the list emptied under the count: by the owner's clearing,
  and on the watch by the app's own tidy-up, which removes iCloud's copy of an event it showed relayed, so a re-upload of
  such events stayed loud there; and relayed alerts under an hour old, too young for ADR 0051's summary, tapped one by
  one.
- **Amended again 2026-10-28** (BACKLOG 170's codex-5, the owner: "rest yes"): a running burst is kept apart from the
  bounded record, its last arrival under a key of its own, so it lasts while each tamper alert follows the one before by
  less than 150 seconds however long it runs. Before, it ended when its first three left the record (fifty arrivals,
  an hour), and a long, sparse burst turned loud again with no gap. An arrival dated before the burst's last (the clock
  moved back) does not continue it. The watch app counts a relayed tamper alert once it is shown (BACKLOG 170's
  codex-4): alerts it could not show used up a burst's first three.
- **Amended a third time 2026-10-28** (BACKLOG 171's codex-1 and codex-2, the owner: "as recommended"): an arrival dated
  before any the record holds (the clock moved back) starts the record afresh from it, and taps; before, the record's
  older arrivals could still quiet a lone alert, an edge the rule had had since step 16. The arrivals and the running
  burst's last are one value, written at once; a record in the second amendment's form, two values, is read once and
  rewritten.
- **Date:** 2026-10-27

## Context

After "Delete Data from iCloud" in iOS Settings, the phone's next launch finds its records gone and uploads them again
(BACKLOG 87). Each re-created record fires the tamper subscription, whose pushes the alert extensions show Time
Sensitive (ADR 0045). Item 153's MAL-04 suspected one alert per record; check C on 1.8.1 (the owner, 2026-10-27)
confirmed it: the iPhone uploaded 334 records again, and the iPad received one Time Sensitive alert per tamper record.
The same kind of burst follows an encrypted-data reset's requeue, and a phone uploading a backlog after a spell offline.

The extensions cannot tell a re-upload from a new trip: they read no record (ADR 0039), and every field but the
thumbnail is encrypted. A field in the clear on re-uploaded records, read by the subscription's predicate or carried in
the push, is what 1.6 (66) tried for another purpose; with it iCloud sent no alert pushes at all (ADR 0046), whose rule
is that any second attempt is proven first on two devices in the Development environment.

Options put to the owner (2026-10-27): (1) a rule in the alert extensions that quiets a burst after its first alerts,
nothing changed in iCloud; (2) the re-uploads marked, with one summary alert, on ADR 0046's ground (Development builds on
two devices first, then a schema deploy to Production). Ruled: (1), in 1.8.2, with check C again on TestFlight 79.

## Decision

1. **The rule** (`AlertBurst`, compiled into both alert extensions, the watch app and the iPhone app's tests). When a
   tamper alert arrives, the path it arrives by adds its time to a short record of its own, the last hour's arrivals and
   at most fifty, in its own storage (since the amendment; first, the arrival times of the tamper alerts still in the
   notification list), and counts the times before it: the iPhone's and iPad's extension, the watch's extension for
   iCloud's alerts, and the watch app for the relayed ones; the paths do not share a record. The
   new alert arrives quietly when, back from now, the run of earlier tamper alerts, each less than 150 seconds before
   the next, holds three within 60 seconds. So the first three of a burst alert as before, Time Sensitive; the rest
   arrive quietly while each follows the one before by less than two and a half minutes. The gap is longer than the
   longest wait the sending phone's upload queue makes between passes (120 seconds), so one re-upload stays one burst.
   Once a burst runs, its last arrival is kept with the record, so the record's bounds cannot end it; an arrival dated
   before any the record holds (the clock moved back) starts the record afresh, and taps (`arrive`; the second and
   third amendments).
2. **A quiet alert** is passive, without sound, and its words say why: "Tamper detected on your device - one of many
   alerts arriving at once. The Event Log has each one." It is still delivered to Notification Center with the others,
   and the record still comes into the log.
3. **Only tamper alerts.** The disarm alert keeps its level and words (late disarms already raise one alert per upload
   pass, BACKLOG 74). On the watch, iCloud's copy of an event whose relayed copy is in the list is still shown quietly,
   with its words as sent (ADR 0052).
4. **Nothing changes in iCloud:** the records, the subscriptions and the schema are as before, so the rule holds
   whatever version the sending device runs.

## Path inventory: every way a burst of tamper alerts reaches a device

1. iCloud's pushes to an iPhone or iPad, through its alert extension: decision 1.
2. iCloud's pushes to a watch, through the watch's alert extension (ADR 0052): decision 1.
3. The relay's copies on the watch (WatchConnectivity): a backlog of alerts more than an hour old is summed up (ADR
   0051); younger ones, shown on their own, follow decision 1 since the amendment (before, a 20-minute backlog tapped
   20 times). A re-upload sends none, since the relay carries only live alerts.
4. The receiving app's background pull (the push's content-available part): it adds the records to the log and posts
   nothing.
5. The watch app's tidy-up of the list (ADR 0052), which removes iCloud's copy of an event shown relayed: it no longer
   touches the count, kept apart from the list since the amendment.

## Consequences

- A re-upload of hundreds of records raises three Time Sensitive alerts on each of the owner's other devices, then
  quiet ones stacked in Notification Center, instead of one alert per record.
- A real run of more than three trips within a minute also goes quiet after the third; the first three still break
  through Focus, and the log has each.
- The first three alerts of a re-upload still read as tamper alerts: the extension cannot word them otherwise without
  reading the record (ADR 0039).
- Clearing the notifications no longer starts the count again (since the amendment); a burst arriving by both of the
  watch's paths is counted on each, so it can tap up to three times on each.
- An extension that does not finish in time leaves iOS to show the push as sent, as before.
- Devices on 1.8.1 or earlier keep one alert per record until they are updated.
- Tests: `Item153AlertBurstTests` (each part of the rule, both extensions, the record, the relayed backlog, the disarm
  alert left alone). Device checks: a backlog uploaded after a spell offline, the watch away for a while and back, then
  check C again on TestFlight 79.
