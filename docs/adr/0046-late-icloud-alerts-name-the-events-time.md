# ADR 0046: A late iCloud alert names its event's time

- **Status:** rejected after the device test (2026-10-13). Built in 1.6 (66) (the owner's ruling, option 1);
  with it, iCloud sent no alert pushes on the owner's devices, so 1.6 (67) removed it (the owner: "go").
  Kept as the record of the attempt (see "Outcome"); the rule that every custom field is encrypted, and
  ADR 0039's generic delivery, stand as before.
- **Date:** 2026-10-13

## Context

The owner's other devices learn of a tamper or a disarm from a CloudKit subscription push whose
words are fixed when the subscription is made ("Tamper detected on your device.", "Malinois was
disarmed on one of your devices."). When the armed phone uploads late (offline, or iCloud switched
off for Malinois), the alert arrives late and iOS shows its arrival time, so it reads as live. The
owner found this in the iCloud check of 2026-10-13 and asked for the time. The watch's alerts from
its own iPhone already name it when more than a minute late (ADR 0043, build 61).

Nothing in the push can say when: every custom field is encrypted, an encrypted field cannot ride a
push, and the extension reads no record (ADR 0039: it cannot check the installation's enrollment).
The record's server creation time is no help either: for a late upload it is the upload's time.

Options put to the owner: (1) a time field in the clear that the push carries, used by the extension
only when the alert is late; (2) the time written into every alert's text by CloudKit, which would
also reach the watch's iCloud alerts but in the sender's time zone, and which older app versions may
show badly; (3) no change, the Event Log showing the time. Ruled: (1), in 1.6.

## Decision

1. **One field in the clear.** The tamper record (`TamperEventMetaV2`) and the disarm signal
   (`TamperEventDisarmV2`) carry `occurredAt`: the event's start, as whole seconds since 1970
   (Int64), in the plain namespace. The encrypted `startDate` stays the record's own copy; nothing
   reads `occurredAt` back into a log.
2. **The subscriptions ask for it.** Both put `occurredAt` in the push (`desiredKeys`). An existing
   subscription that does not is saved again under its own ID at the next arm (`isCurrent`), which
   replaces it; older app versions save only a missing or non-mutable subscription, so they leave
   the new one alone.
3. **The extension words a late alert.** It reads `occurredAt` from the push (`recordFields`), and
   when the alert arrives more than a minute after the event it appends the time, and the date if
   another day, exactly as the watch's relayed alerts do: "Tamper detected on your device at
   3:42 PM." An on-time alert, or one without the field, reads as sent. The tamper alert stays Time
   Sensitive.
4. **The time never costs the record.** Production refuses a save naming a field its schema lacks,
   record and all. So a tamper or disarm record refused as malformed (`invalidArguments` or
   `serverRejectedRequest`) is saved again without the time, and once that lands, later records leave
   it out until the next launch. The schema change (`store/CLOUDKIT_SCHEMA_1_1.md`, Part 6) is still
   deployed to Production before the build is tested on TestFlight, so the fallback is a safety net,
   not the plan.

## Consequences

- A late alert on an iPhone or iPad says when its event happened, so it no longer reads as live.
  The watch's iCloud alerts from other devices still carry no time (the watch has no notification
  extension); its alerts from its own iPhone already do.
- Apple can see when each tamper and disarm happened. It already sees when each record is saved,
  the same moment for an on-time alert, and the record types reveal the kind of event; for a late
  upload the field adds the true time. With Advanced Data Protection on, the encrypted fields and the
  media stay end to end; this field does not. The Pro welcome says so ("apart from when each
  happened"), and SECURITY.md's encryption section names the exception.
- Both receiving and sending devices need 1.6 (66) or later: an older sender writes no time, and an
  older receiver's extension ignores it. The first arm on 66 updates the account's subscriptions.
- A one-time schema step for the owner in the CloudKit Console: create the field on both types in
  Development, deploy to Production, before TestFlight.
- Paths not taken: option 2 (above); a second "late" subscription keyed on a plaintext flag (one bit
  per event, and still no time); reading the record in the extension (ADR 0039's boundary).

## Outcome (2026-10-13)

On TestFlight 66, with `occurredAt` deployed to Production, iCloud sent no alert pushes: the iPad got
none, and neither did the watch with its Bluetooth off (which hears its iPhone's alerts from iCloud),
while every record showed "iCloud synced" on the iPhone and the watch's direct link still delivered.
Deleting and recreating the subscriptions (Cross-device alerts off and on) did not help; reinstalling
65 on the iPhone brought immediate alerts back. Apple documents no such behavior (searched); which half
stopped the push, the field on the records or the request in the subscriptions, is not known.

1.6 (67) removes the field, the request and the extension's wording, and keeps only the Pro welcome's
correction (without the time clause). Tests now pin that the tamper and disarm records hold nothing in
the clear but the thumbnail and that the subscriptions ask for no field. The Production schema keeps
`occurredAt` on both types, unused (a deployed field stays); records 66 wrote in the owner's account
carry it.

Before any second attempt: prove on two devices in the Development environment that the push still
arrives with the change, before it goes into a release build.
