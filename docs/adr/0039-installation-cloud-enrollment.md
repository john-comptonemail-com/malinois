# ADR 0039: Device-owner verification before cloud enrollment

- **Status:** accepted; shipped in 1.5.1 (58), released 2026-10-12. Build 56 phone checks passed; switching iCloud accounts on
  hardware is untested (owner-accepted limitation) and initial enrollment cancellation was waived. Amended by ADR 0045
  (1.6): the extension shows tamper alerts Time Sensitive, decided from the push's subscription without reading a record.
  Its design as it stands in 1.11, with the fifteen sections added after its decision (2026-10-11 to 2026-10-30, 1.5.1
  to 1.10), is stated by ADR 0076 (BACKLOG item 186); the sections are listed at the end.
- **Date:** 2026-10-11

## Context

Deleting and reinstalling an app must not turn a new app PIN into access to old iCloud evidence.
A surviving PIN must be preserved, but that alone cannot protect a new phone or an installation
whose Keychain history is absent. UI-only checks miss background restores, notification reads,
and account-wide subscription changes.

## Decision

The owner selected option B in `docs/design/reinstall-recovery-options.md`: preserve surviving
PINs and use iOS device-owner authentication (Face ID, Touch ID, or device passcode) to enroll
each installation and iCloud account. Existing cloud users verify once after migration. Local
monitoring and ordinary PIN-only disarm remain available without cloud enrollment.

The cloud service resolves account identity before each entry point and requires an enrollment
lease. Queued work, retries, and returned results retain that account/generation; account changes
invalidate leases and cancel tracked operations. Identity failure is never proof of permission.
Enrollment and explicit account-wide alert removal are foreground actions. The latter always
requires fresh authentication and changes the saved toggle only after CloudKit reports success.

The grant lives in an atomic, protected file in the app container, excluded from backups. A
surviving Keychain item cannot silently recreate a grant after reinstall. Failed persistence,
corrupt state, cancellation, and unavailable authentication remain local-only. No background
callback displays an authentication prompt.

Each local event and watch has a durable account binding established at capture time. Migration
uses the previous release's remembered account only when known; unknown old records stay local
(superseded in 1.8.2: the rebuild holds every record; ADR 0076, section 6).
Offline captures retain their verified owner until a different account is positively observed.
That observation places subsequent captures on a durable hold, including across offline relaunch.
Resolving the original identity or explicitly enrolling the new account allows future captures
to bind; already-held evidence is never adopted automatically. Changing accounts never adopts
old evidence automatically. Returned mirrors retain their source
account binding; stale results cannot merge into the log or attach downloaded media.

The owner selected generic notifications for this maintenance update. The notification extension
returns the subscription's content immediately and never fetches private records. Device/sensor
wording and Vision-only quieting are deferred until a shared authorization design is separately
reviewed and tested across reinstalls. Generic alerts retain the sound and interruption level
sent by the subscription. No shared-storage or signing capability is added.

## Consequences

- Existing users temporarily lose cloud backup/restore until verification completes. Local
  evidence remains on the phone and monitoring/disarm remain available.
- A device without a passcode cannot enroll. Canceling or failing authentication changes nothing.
- People who can satisfy device-owner authentication can authorize recovery and cloud access.
  This is not record signing, producer authentication, server-side revocation, or protection
  against modified clients, older builds, iOS compromise, or deletion through Apple's controls.
- Unknown-account evidence is deliberately held. No records are deleted to simplify migration.
- Already accepted server requests cannot be recalled; cancellation and generation checks stop
  later work and reject stale results, without promising a transaction across Apple account changes.
- Reinstall, account switching, OS authentication, and background delivery need physical-device
  checks in addition to regression tests. Submitted 1.5 (55) is unchanged.

## Added sections, now ADR 0076

From 2026-10-11 to 2026-10-30 this record took fifteen sections after its decision, from the reviews and audits of
1.5.1 to 1.9 and the owner's reports: three on the screens, one on a transient identity failure, ten amendments and
an implementation note. ADR 0076 states the design they built, as it stands; the BACKLOG items named hold each defect,
the review that found it and the owner's ruling. The sections, for what cites them (the code and its tests cite the
fourth and the eighth):

1. 2026-10-11, 1.5.1: the Event Log's presentation (ADR 0076, section 8).
2. 2026-10-19, 1.8 (73): Settings under Guided Access (item 135; ADR 0076, section 1).
3. 2026-10-19, 1.8 (74): Home's presentation, in item 168's words since 1.8.2 (item 140's codex-1; ADR 0076,
   section 8).
4. 2026-10-22, 1.8.1: a transient identity failure is not an account change (item 152's lead 1; ADR 0076, section 3).
5. 2026-10-22, 1.8.1: the other entry point, and a throttle is an answer (item 155's A2 and A3; ADR 0076, section 3).
6. 2026-10-23, 1.8.1: an account not ready yet, and the sweep's first lookup (item 155's S2 and S3; ADR 0076,
   section 3, and ADR 0075, section 5).
7. 2026-10-24, 1.8.2: the iCloud-copies check follows the enrollment (item 152's lead 13; ADR 0076, section 7).
8. 2026-10-24, 1.8.2: the bindings of records gone from the log are pruned (item 153's MAL-08; ADR 0076, section 4).
9. 2026-10-24, 1.8.2: the binding reaches the medium before the journal line (item 153's MAL-07; ADR 0076,
   sections 1 and 4).
10. 2026-10-24, 1.8.2: a fetch that brings nothing new writes nothing (item 152's lead 20; ADR 0076, section 4).
11. 2026-10-24, 1.8.2: a restore holds every restored record, superseding the decision's sentence on migration (item
    163's codex-7; ADR 0076, section 6).
12. 2026-10-26, 1.8.2: an "off" supersedes the automatic setups (item 165's A3; ADR 0076, section 2).
13. 2026-10-26, 1.8.2: a restored record's upload history is unknown (item 166's codex-29, codex-31 and codex-32;
    ADR 0076, section 6).
14. 2026-10-29, 1.9: an implementation note on the storage cap's words for a capture marked lost (ADR 0006's 1.9
    amendment).
15. 2026-10-30, 1.10: a restored record makes no claim for a read (item 180's A6; ADR 0076, sections 5 and 6).
