# ADR 0006: Store writes preserve monotonic fields; mirrors are copies, not custody

- **Status:** accepted
- **Date:** 2026-08-30

## Context

Three findings from the sixth and eighth external reviews were one disease in three limbs:
a **value copy of an event, held across an async gap, written back whole** over a stored
copy that had learned something in the meantime.

- `respond()` holds a pre-capture copy for the duration of the capture (up to 120 s).
  A disarm meanwhile marks the STORED copy owner-attributed (R-02) and re-pushes it.
  The capture's completion then wrote the stale copy back — attribution erased locally,
  and the rich push built from the same stale copy wrote `ownerAttributed = 0` to the
  cloud at an equal revision, where `.allKeys` overwrites (sixth review, F2).
- The same write-back bypassed the `setSyncState` monotonic guard: a `.synced` event
  walked back to `.pending` because `update()` replaced the whole value.
- On a second device, a mirror the owner had downloaded full evidence onto was
  wholesale-replaced by a later-revision cloud copy — whose `mediaFilename` is nil **by
  construction** (the decoder pins it; the file is not on that device). The reference
  vanished and the orphan sweep deleted the downloaded file (eighth review, M3).

A fourth finding completed the picture from the other direction: the encrypted-data-reset
recovery requeued **mirrors** for re-upload, stamping this device's name on another
device's evidence and racing the capturing device's richer re-upload under `.allKeys`
(eighth review, M4).

## Decision

1. **`EventStore.update` merges, it does not replace.** Every whole-value update passes
   through `preservingMonotonicFields`: owner attribution, once true, stays true; sync
   state moves only where `mayTransitionSyncState` allows — the same rule `setSyncState`
   enforces, now unbypassable. Callers keep their natural shape (mutate a copy, write it
   back); the store guarantees the invariants.
2. **A superseding mirror inherits local enrichment it cannot carry itself**
   (`inheritingLocalEnrichment`): `mediaFilename`, `secondaryMediaFilename`, and a
   thumbnail the incoming copy lacks. Everything the cloud copy actually carries wins,
   as before; only locally-born facts survive the replacement.
3. **Mirrors are copies, not custody.** The reset recovery requeues first-hand events
   only. A mirror is never re-published by this device: wrong provenance
   (`makeMetaRecord` stamps the local device name), and a stale sparse copy can regress
   the capturing device's richer record. Accepted residue, recorded: if the capturing
   device is gone, its mirrored copies stay local after an encrypted-data reset.
4. After an update, upload paths **re-read the stored copy** and push that — never the
   local value they happen to hold.

## Consequences

- The R-02 flagship timing (touch trip at the disarm hold, clip rolling, PIN typed
  mid-clip) keeps its attribution end to end; `.synced` cannot regress through any
  write path; Download full evidence survives refreshes on mirrors.
- Monotonicity lives in ONE choke point, so every current and future caller is covered —
  the flood coalescer's stale `sustainedEvent` anchor included.
- Not taken: making callers re-read-modify-write under a lock discipline. The store is
  MainActor-confined already; the hazard was never concurrency but **stale value copies**,
  which a merge at the write boundary cures without changing any call site's shape.
- Not taken: field-level cloud writes (`.changedKeys`) to protect the cloud copy from
  stale pushes. The per-event chain (ADR 0003) already serializes writes, and the
  re-read-before-push rule makes the pushed value current; `.changedKeys` would reopen
  the partial-record questions ADR 0004 settled.
- The theft edge case in (3) — capturing device gone, reset wipes the cloud, mirrors
  hold the only copies locally — is accepted and documented rather than solved with
  provenance-preserving mirror re-publish; revisit only if it ever bites.

## Amendment (2026-08-30, fourth pass R3-4): copies-not-custody extends to eviction

The count cap's eviction order treated mirrors and first-hand events as one population,
so bulk-inserted future-dated mirrors at a full log could evict first-hand events and
their local media — iCloud credentials reaching on-device evidence, which tier 2 rules
out. Two completions of this ADR's principle:

- **Mirrors evict first.** `countEvictionOrder` gains a mirror class ahead of every
  first-hand pass: a mirror is a copy — the capturing device and the cloud still hold
  it, and a re-fetch restores it — so shedding one loses nothing this device owns.
  *(Amended 2026-08-31, post-1.2 external review #1: the newest-event exemption
  (39.R1.6) now applies to first-hand passes only. Its rationale — the just-added
  record of an incident in progress must not self-evict — never described a mirror,
  and shielding a newest mirror let one merged record per sync slip past the mirror
  pass and evict first-hand evidence instead, bypassing this amendment at exactly the
  one-newest-mirror boundary. The mirror pass now includes the newest row; a newest
  mirror evicting itself means "the cloud row didn't fit", and a re-fetch re-attempts.)*
- **Cloud timestamps are bounded.** A record's `startDate` is believed at most a day
  past its own server-stamped `creationDate` ("now" for a record that never got one).
  The field that decided sort order — and therefore eviction age — was the one scalar
  the decoder's clamp suite missed.

## Amendment (2026-10-26, 1.8.2): a photo's loss before upload is monotonic too

When the media byte limit discards an unsent photo, the capturing phone marks its event
(`mediaDiscarded`), so neither phone offers a download of a photo that never reached iCloud.
Another device that already held a copy of the event never learned it (BACKLOG 166's A2,
Codex's codex-2): the copy that says so carries the same revision when the thumbnail stays,
which `supersedes` accepts only for a grown count or a new failure reason, and without a
thumbnail the discard lowered the record's revision, so the capturing phone refused to send
it (`mayWrite`) and a receiver would have refused it as older. Now:

- **The mark joins the monotonic facts.** A mirror takes it from a copy of any revision
  without that copy replacing anything else (`learningTheLoss`), and a superseding copy that
  lacks it keeps it (`inheritingLocalEnrichment`). First-hand evidence is untouched, as before.
- **The revision does not go back.** The first evidence slot counts a capture the byte limit
  discarded (`metaRevision`), so the copy carrying the mark is sent and taken like any other.

Tests: `Item166ReviewTests` (through the store's real byte limit and the record's encoding).

Codex's look at that change (codex-23): the mark covered the whole event, and the byte limit set it for any pending
capture, though part of one can be in iCloud (a two-camera capture whose front photo landed and rear did not; a photo
that landed while its record's save failed); learned on another device, it hid the download of a photo iCloud holds.
The owner chose to record what landed (2026-10-26, option (a)): each file that reaches iCloud is noted on this phone's
event by its camera (`uploadedMedia`, kept on this phone and only ever growing, through the store's updates as the
other monotonic facts; since 2026-10-27 its names also ride the record's list of its media, ADR 0002's amendment of
that day), and the byte limit sets the mark only when none did. A partial upload keeps its download on
every device; the camera whose file was lost is not named, as before. The capturing phone offers the download of
a file it knows landed, the rest of the upload not finished (codex-25). Tests: `Item166ReviewTests`.

Codex's full review of `8573b6c` (item 174's codex-1, the owner: "as recommended", 2026-10-28): after iCloud's copies are
found deleted or reset (`EventStore.requeuedForReupload`), `uploadedMedia` described an iCloud that no longer held those
files, so the byte limit skipped its check, the capture's next upload read synced with nothing in iCloud, and its
download stayed offered. The requeue now voids the receipts of every capture it picks, synced or partly up, and raises
their generation (`Event.receiptEpoch`): receipts only grow within one generation, so an older copy brings none back, and
a landing that an upload begun before the loss reports is not noted. Tests: `Item174ReviewTests`. Nor is an answer of
iCloud's presence check asked for before the loss: the check stays owed for one asked for after (BACKLOG 176's codex-2,
the owner: "as recommended"). Test: `Item166ReviewTests`.

Codex's look at that (codex-24): an event saved before this version has no record of what landed, and an older version
writing the log drops it, so no record could not be read as none; a file can also land unrecorded (a kill at that
instant, a reply lost). The owner chose to ask iCloud (2026-10-26, option (b)): the byte limit leaves a capture with no
record of a landed file unmarked and owing a check (`mediaDiscardUnchecked`), its download offered meanwhile; the
engine's pending sweep asks iCloud which of its files it holds (the presence check of the iCloud copies, for this
phone's captures bound to the verified account: one fetch a pass, under the pass's own lease, for up to 20 of them,
the oldest first), and the capture is marked lost only if iCloud holds none, its record reopened so the mark reaches
the other devices; what iCloud holds becomes the record; no answer waits for the next pass or sweep. A capture that
can never have gone up (recorded while iCloud backup was off, or tied to no account) is marked at once, as before. The
store's updates keep the mark and an owed check, and a capture awaiting its check takes no late camera file, as a
marked one does. A capture an older version already marked stays marked. A receipt of a file that landed while iCloud
was asked outweighs an empty answer sampled before it landed (codex-27). A capture whose upload history this phone
cannot know, restored from a device backup or not yet bound, is never marked at once (codex-29, codex-31, codex-32;
ADR 0039).


## Amendment (2026-10-29, 1.9): thumbnail enrichment and already-pruned cloud loss

An equal-revision mirror can newly acquire a thumbnail after the source's staging retry. The existing no-regression
rules for counts and capture failure still apply, first-hand evidence is untouched, and downloaded local files or
a valid thumbnail already held survive replacement. A new thumbnail does not authorize replacing an older revision.

When cloud loss voids a first-hand capture's receipts, a capture whose files are already absent locally also owes
the existing bounded cloud check in its new receipt generation. Camera names, retained by every shipped capture
path, identify captures after pruning; status/sparse records, captures with local files, mirrors, unpicked records
and an already-conclusive loss acquire no new check. The check is persisted alongside the receipt invalidation.
Only a conclusive current-generation answer settles it; a current landed file still prevents a whole-capture loss.
The UI's loss sentence covers both a failed first upload and a later disappearance of the last cloud copy.

Regression cases: `Item175ThumbnailRetryTests` and `Item176PrunedRequeueTests`; live CloudKit checks remain outstanding.
