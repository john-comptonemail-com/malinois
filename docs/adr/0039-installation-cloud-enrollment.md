# ADR 0039: Device-owner verification before cloud enrollment

- **Status:** accepted; shipped in 1.5.1 (58), released 2026-10-12. Build 56 phone checks passed; switching iCloud accounts on
  hardware is untested (owner-accepted limitation) and initial enrollment cancellation was waived. Amended by ADR 0045
  (1.6): the extension shows tamper alerts Time Sensitive, decided from the push's subscription without reading a record.
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
uses the previous release's remembered account only when known; unknown old records stay local.
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

## Event Log presentation (2026-10-11)

Held records are counted separately from eligible local uploads. Retry is shown only for
eligible uploads; event details distinguish unknown ownership, a different account,
verification needed, and unavailable enrollment storage. The read-only presentation uses
known ownership/grant state; it does not prompt, resolve an account, or grant upload access.
Same-account offline captures remain retryable using their durable grant, while the actual
upload still obtains and validates a current lease. No ownership/adoption policy changed.

## Settings under Guided Access (2026-10-19, 1.8 (73))

iOS holds the device-owner authentication sheet while Guided Access is on (BACKLOG 44), so
`deviceAuthentication` refuses at once rather than leave a request waiting. Settings' Verify
iCloud access did nothing visible then (BACKLOG 135, the owner's report). It is now greyed out
while Guided Access is on, its caption saying why, and comes back when Guided Access ends. A
verification that still fails with Guided Access on (started during the attempt; read when it
fails) says so, instead of the generic "retry while disarmed". No grant, lease or ownership rule
changed.

## Home presentation (2026-10-19, 1.8 (74))

Home said "iCloud verification needed" and "events recorded before then stay on this iPhone"
whenever access was not current (BACKLOG 140, Codex's codex-1). A verified installation offline,
or relaunched before iCloud answers, binds new events to its granted account, and they upload
once iCloud names that account again. `CloudEnrollment.newEventsBindToVerifiedAccount` reports
that, by the very rule `register` binds with; Home's row then says "Waiting for iCloud" and the
orange line stays away. The line shows only while new events are tied to no account (never
verified, another account seen), and not with iCloud backup off, whose own line says new events
stay on this iPhone. No grant, lease or ownership rule changed.
