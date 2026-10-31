# ADR 0004: A record is synced only on its own reported confirmation

- **Status:** accepted
- **Date:** 2026-08-29

## Context

On 2026-08-28, on a physical device in Airplane Mode, an armed session tripped a vision
event and the Event Log showed it **iCloud synced** — while the arm/disarm records
honestly showed pending, the CloudKit Console showed nothing arriving, and the device
provably had no network (the state records' server `Created` timestamps trail their
`startDate` by 14 minutes, matching the Wi-Fi restore).

The device's unified log pinned the mechanism: the two saves that carry `CKAsset`s
(the meta record's thumbnail, the photo record's media) first fetch asset-upload
tokens. Offline, that token fetch failed — and the `CKModifyRecordsOperation`s then
**finished with no error** (operationIDs `FA78E7096343CC14`, `7DD8B157BFD5BAA8`;
every asset-less operation that night failed honestly with `-1009`). The app trusted
the operation-level `modifyRecordsResultBlock` result as proof the records landed,
marked the event `.synced`, and — because `.synced` is terminal and exempt from every
retry sweep by design — the evidence was stranded on the device permanently while the
UI claimed it was safe. A false "your evidence is backed up" is the single worst claim
this app can make, and the monotonic sync-state guard turns one false success into a
permanent one.

The framework behavior looks like an OS bug (reported to Apple as **FB24561094**,
2026-08-29, with the sysdiagnose), but the constraint stands regardless: the
operation-level result is a statement about the *operation*, not about any *record*.

## Decision

A save reports success **only when every record it carried has its own per-record
confirmation** (`perRecordSaveBlock`). In order: an operation-level error stands as-is
(retry/interference classification already expect that shape, `.partialFailure`
included); a reported per-record failure stands as-is (a real error classifies better
than a synthesized one); a record with **no reported result under a "successful"
operation is a failure** — silence is not success. The synthesized silence-failure is
deliberately not network-class, so it can never feed the jamming escalation (ADR 0001),
and it is terminal for the in-save retry loop — the event falls to `.localOnly`, where
the pending sweeps own the retry.

The rule lives in one pure function (`CloudExfiltrator.saveError`) behind the single
`save` chokepoint, so every push path — meta, photo, and arm/disarm state — inherits it.

## Consequences

- The incident shape now yields `.localOnly` + retry-on-reconnect instead of a
  permanent false `.synced`. Cheap observed behavior: offline evidence reads
  "Local only", turns "iCloud synced" only after a real round trip.
- In the pathological silence case the Home surface may say iCloud *refused* the push
  (the synthesized error is non-network by design). Slightly imprecise wording is
  accepted over the alternative — fabricating a network-class error that could sound
  the blackout siren on nothing.
- Not taken: post-save read-back verification. It would double round trips on the
  trigger-time hot path to defend against the same lie a per-record result already
  exposes, and the fetch path exercises read-back organically.
- Events already falsely marked `.synced` by earlier builds are not repaired by this
  change; the monotonic guard keeps them terminal. A reconciliation pass (cloud
  cross-check) is a separate decision.
- **Extended to deletes (2026-08-30, sixth review F5):** the retention purge's batch
  delete now follows the same rule via `deleteFailed` — success only when every expected
  record is individually confirmed absent (deleted, or already gone as `unknownItem`);
  a per-record failure, an unanswered record, or a non-partial operation error fails the
  batch. The old judgment mapped `.partialFailure` to success and dropped per-record
  errors, so Settings reported "Deleted" while media remained.
- **Extended to reads (2026-08-31, ninth review R3-3):** the same principle on the query
  and by-ID fetch paths — a per-record failure is never absence. Restore fetches report
  incomplete when any matched record individually failed (`queryPageSawFailure`), the
  purge's meta walk fails the purge rather than skip-and-claim-"Deleted", and full-media
  retrieval distinguishes "iCloud holds nothing" (every slot answered, `unknownItem`
  included) from "some slots went unchecked" (`mediaFetchIncomplete` →
  `FullMediaFetch.complete`), which the download UI surfaces with a retry. Partial
  results are kept in every path — half a restore is worth more than none — only the
  *claim of completeness* is withheld.


## Amendment (2026-10-29, 1.9): subscription deletes use the same confirmation rule

Alert subscription deletion now collects each requested ID's result, including the obsolete 1.0 ID. A confirmed
delete or `unknownItem` is absence. Any other per-ID error, an unanswered ID, or a non-partial operation error leaves
the removal unconfirmed. An operation's `partialFailure` is judged by those individual results, not swallowed.
This also covers the legacy subscription disappearing between setup's listing and its deletion.

Authentication, account leases, deadline cancellation and the final current-lease check are unchanged. Four
public-path tests in `Item175SubscriptionDeleteTests` drive the actual operation callbacks; a fifth pure reducer
test supplies operation-level partial failures and conflicting answers directly. Missing and contradictory
callbacks are defensive controls, not claimed normal server responses. Live OFF/ON delivery still needs a phone
check. This extends the existing delete rule without a new account-wide action or permission.

The diagnosis follows the installed SDK, not the first scratch prediction. A local callback-only probe on macOS
27.2 (26B123), Apple Swift 6.4 (swiftlang-6.4.0.34.1), MacOSX27.0 SDK observed the modern subscription result bridge
normalize every tested partial failure to operation success, including valid per-ID dictionaries containing
unknown-item, permission or mixed errors, with and without a per-ID handler and through both callback entry points.
Top-level unknown-item and network errors remained failures. The old implementation therefore already passed the
positive absent-legacy cases; the failing regression was false success for failed or unconfirmed individual IDs.
The simulator valid-map red run confirmed that diagnosis. This was not a live CloudKit operation or a survey of
historical SDKs. The explicit reducer test covers the branch if an operation-level partial failure reaches it.
