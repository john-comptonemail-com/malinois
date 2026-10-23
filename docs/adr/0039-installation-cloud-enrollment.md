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

## A transient identity failure is not an account change (2026-10-22, 1.8.1)

Every database entry point resolves the account's identity first (`fetchUserRecordID`, under a
10 s deadline). One lookup that failed for any reason was treated as an account change for the
whole process: every lease in flight voided, every save under way cancelled and demoted to
local-only, the pending sweep's record of transient failures erased, the verified state cleared
(the security audit's lead 1, BACKLOG 152). Nothing was lost, but on a phone left armed the next
sweep could be hours away, and under a network that passes nothing the lookup's deadline cancelled
the saves before their own deadline could give the interference verdict ADR 0001 escalates on.

The lookup now tells three answers apart (`CloudExfiltrator.identityLookup`, pure): a name
resolves the account, a different name invalidating first; iCloud's answer that there is no
account (`.notAuthenticated`, or no record) invalidates, as before, and so does anything
unclassified; a transient failure (the network class `retryDelay` names, a bare transport error,
or the deadline) denies only the caller's own request, records a network-class transient failure
for the pending sweep's follow-up, and leaves every lease in flight, every save under way and the
verified state as they are. The account-changed notice still invalidates. An evidence push denied
by a transient lookup reports the network-class verdict (`metaFailureWasInterference: true`), so
the escalation's rule sees it as it would a save that lost the network; a hold is still no
verdict. The pending sweep, whose lookup fails transiently, follows up as it does after a save's
transient failure instead of ending with records left. Path inventory: every lease taker (the
fact, meta, photo and state pushes, heartbeats, the sweep's own leases, the fetches and the
retention pass) goes through the same resolution; only the evidence push reports a verdict, and
only the sweep follows up. Device check: Network Link Conditioner at 100% loss with the path up,
the escalation fires on the lookup's failure as it did on a save's.

## Amendment (2026-10-22, 1.8.1): the other entry point, and a throttle is an answer

The fresh review of 1.8.1 (BACKLOG 155, Codex's codex-4 and codex-5) found the rule above applied
to the identity lookup only. Home's and Settings' account-status refresh (`refreshAccountState`)
still invalidated the resolution, every lease in flight and every save under way on a temporary
answer: iOS's "temporarily unavailable" or "could not determine", an error, or the status call's
own deadline. Now one rule applies at both entry points (`applyAccountStatus`): iCloud's answer that
the account is not there to use, no account or restricted, invalidates as the lookup's "no account"
does; any other answer that is not ready goes on record as a transient failure for the sweep's
follow-up and changes nothing else. And the lookup's transient result now carries its class and the
server's wait: the network class and a bare transport error are interference, as `failureSuggests
Interference` already rules for saves; Apple's throttles and outages (`requestRateLimited`,
`serviceUnavailable`, `zoneBusy`) are answers, so an evidence push they deny reports a refusal
verdict, which the engine surfaces on Home instead of sounding the jamming siren, and their
retry-after reaches the pending sweep instead of being dropped. Path inventory: the two entry
points; every lease taker through `leaseAttempt`, which hands the class to the evidence push's
verdict; the sweep's follow-up, which reads the recorded wait.

## Amendment (2026-10-23, 1.8.1): an account not ready yet, and the sweep's first lookup

Codex's second look (BACKLOG 155, codex-2 and codex-3 of the second look) found two gaps in the amendment
above. The identity lookup classified iCloud's `accountTemporarilyUnavailable`, an account that is there but not
ready, as no account, because the transient set it consulted is the save path's: the resolution, every lease in
flight and the verified state were revoked for an answer Apple documents as temporary, while the same answer from
the status check (`temporarilyUnavailable`) already revoked nothing. Now the lookup classifies it as a transient
answer, not interference and with no wait named: it denies its caller, goes on record for the sweep's follow-up
and changes nothing else; it stays out of the save path's retry set, because a save is not retried within
milliseconds for it. And the pending sweep made a preflight lookup before its first pass, whose throttle wait the
pass cleared before looking up again at once, so a second lookup that succeeded uploaded before the wait the
server had named. The preflight is gone: the first pass makes the sweep's first lookup itself; a throttle on it
hands nothing out and its wait reaches the follow-up, as a lookup that failed for want of a network has since
item 152's lead 1; no account still ends the sweep at once. One lookup per pass instead of two.
