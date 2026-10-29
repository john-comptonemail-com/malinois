# ADR 0037: Recover interrupted first-hand media attachments

- **Status:** accepted; amends ADR 0005's media-update loss window
- **Date:** 2026-10-11

## Context

The event fact is journaled before capture, but previously a saved media file and its
later event update were independent. A process interruption between them left an
unreferenced file eligible for the 24-hour orphan sweep. The owner authorized fixing
this evidence-preservation gap. Existing files do not encode enough information to
safely infer their event, camera or primary/secondary slot.

## Decision

Initial, blackout, flood and interruption-retry captures use explicit recoverable
storage. Before saving, the store validates an existing first-hand incident identity,
its start time, an unoccupied destination and its physical camera. Downloads keep the
context-free storage path because their destination is decided after awaiting retrieval.

A protected JSON intent under `MediaAttachments` precedes saved bytes. It identifies
the event/start, camera, slot, filename, expected nonzero byte count, optional duration
and thumbnail. File sync precedes the final move from staging to Media; only a final
file matching the intent is recoverable. The manifest and media inherit evidence
Data Protection. A staging file is never presented as completed evidence.

Clip previews are decoded from the finalized source movie before moving it into
staging. AVFoundation does not recognize the staging file's `.pending` extension;
asking it to decode that name silently lost thumbnails in the first phone candidate.
The preview joins the synced manifest before publication. Tests generate real
three-second and sub-second movies, checking previews, byte-for-byte preservation,
playable duration and attachment recovery; opaque storage fixtures cannot prove these.

After log/journal recovery, including unlock recovery, valid unambiguous intents enrich
the current event without replacing its other metadata. Recovered media becomes pending
for cloud upload. No new event is created from an intent. Conflicting identities,
mirrored/status/discarded events, occupied slots, partial files, unsafe names, links,
invalid manifests and oversized input do not authorize attachment.

The existing serial I/O queue checkpoints the event snapshot, full-syncs it, then retires
its matching attachment intent. Launch cleanup uses the actual disk-decoded snapshot;
syncing an old file cannot prove that a newer in-memory attachment reached disk.
In-memory recovered references may veto aging (including a journal-only event absent
from the disk log), but never authorize retirement as successfully attached. Failed persistence/sync keeps the intent. Unresolved
intents suspend the ordinary orphan sweep. Enumeration is limited to 1,200 entries (since
1.8.2, a folder up to 8 past it is still read: the first amendment below) and manifests to 512 KB. Retained staging payloads plus an incoming capture are limited to
2 GB in aggregate, using logical file lengths on the same I/O queue. Unknown/unreadable
sizes refuse admission before consuming the source. This temporary staging allowance
is separate from the unchanged 2 GB committed-media retention budget; it is not a
promise that the app's total disk footprint can never exceed 2 GB. Old abandoned
entries can age out after 30 days only after a clean log load/checkpoint. A completed
file still eligible for attachment is not aged out. A damaged/unreadable/overfull intent
directory errs toward retention and can refuse new recoverable saves rather than delete
uncertain evidence.

## Consequences

- Process interruption after committed media no longer depends on the engine completing
  its filename update. Primary/secondary camera identity, duration and thumbnail survive.
- Additional protected writes/syncs run off the main actor. On-device storage latency
  still needs verification; simulator results do not establish power-loss durability.
- Abrupt power loss during directory renames remains outside the durability guarantee.
- Already orphaned legacy files cannot be safely attached retroactively.
- Manifests are not signatures. Local hostile write access remains a separate threat;
  producer authentication will be presented to the owner before any implementation.
- The existing retention limits remain. An event deliberately evicted by those limits
  is not resurrected from an attachment intent.

## Amendment (2026-10-28, 1.8.2): the class a sealed phone will not change, and Codex's look

The device test on the owner's iPhone Air with the amendment below (BACKLOG 176) found the photo still not saved. A
file the writer creates in one of the store's folders has `completeUnlessOpen` already, from the folder, and the
writer set that class again through its descriptor, which a sealed phone refuses (EPERM), even for the same class. A
diagnostic run on the Air found the rest allowed while sealed: create, write, full sync and rename, over an existing
manifest too; a class C file set to `completeUnlessOpen`; a class C clip raised to it. The writer now sets the class
only when the new file lacks it (`protects`, step 64). Tests: `Item152LockedSaveTests`' writer tests, and the device
test on the Air.

Codex's look at the amendment below (the owner: "as recommended"). The waiting-clip retry runs at launch and at the
deferred load only, no longer at an unlock (step 65): there a capture could be saving, and the retry's recovery could
attach that capture's own file first, after which the save found its slot filled, reported a failure, and the
capture's response wrote its copy back without the file (codex-1); or a capture's response could still hold the event
of the clip it could not save. At launch and at the deferred load every clip the retry finds is from an earlier run of
the app. A save whose own file the recovery attached while it ran now reports that file, and a retry that attaches
asks the engine for an upload pass (`mediaAttachedLate`, codex-5), since it can land after the launch's own pass.
Tests: `Item152LockedSaveTests`' retry tests.

A save is admitted with three entries free in the attachment folder, not two (step 66): the manifest's replacement
adds a temporary file beside the manifest and the staging file, and a kill before its rename left the folder past its
1,200 entries, where every save, recovery and clean-up refused for good (codex-3). The folder is also read up to 8
entries past its limit, so one left over it under the earlier rule is still recovered and cleaned. Tests:
`Item152LockedSaveTests`' two limit tests.

## Amendment (2026-10-28, 1.8.2): a save on a sealed phone

The security audit's lead 7, reproduced on the owner's iPhone Air (iOS 27.0.1; BACKLOG 163's step 28, the device test
on `wip/1.8.2-step28-device-test`): a photo or clip whose save started after the lock's grace period (iOS seals about
10 seconds after a lock, and posts its notice at the lock) was not saved. The save wrote its manifest and staging file
under `completeUnlessOpen` and then reopened them by path to flush them, which iOS refuses once sealed; the failed save
left a stray manifest, and the clip stayed in PendingCameraEvidence, which nothing read. The owner's ruling (option 1,
"as recommended"): the protection stays. Each of the store's files is now written and flushed through the descriptor
that wrote it (`writeSealed`), never reopened; the staging admission measures files without opening them; a recorded
clip is flushed and raised to `completeUnlessOpen` while it still waits in PendingCameraEvidence, so a refusal leaves
it there, whole, never deleted (the move used to come first, and `applyClipProtectionOrRemove` deleted it); its intent
names it (`source`), and the next unlock, launch or deferred load (the unlock dropped: the amendment above) runs the
save again from it (`attachWaitingClips`), the recovery attaching what that publishes. Stray manifests keep their
30-day clean-up. Such evidence uploads once its files can be read, after the next unlock, as any upload past the grace
period (an upload pass asked for once attached: the amendment above). Not changed:
the log and journal flush the same way, but there a refused flush only weakens the power-cut guarantee, the data being
written. In the Simulator the writer sets no protection class, as Foundation's options set none there: set on the
Mac's own volume, a class seals with the Mac's screen lock (the gate on `0af5bf2` failed 70 tests while the Mac was
locked). Tests: `Item152LockedSaveTests` (seams stand in for the sealed phone), and the device test on the Air.

## Amendment (2026-10-25, 1.8.2): no write at load before recovery

At launch and at the unlock, no write of the log comes before journal recovery, so every checkpoint sees the
incidents the journal brings back; a load that holds an old copy from iCloud to the limits (codex-13 on 1.8.2) writes
it back after attachment recovery (`writeBackBoundedCopies`). Written from inside the load, as first built, that write
came first: its checkpoint aged out a 30-day-old intent whose incident only the journal knew, the photo stayed off
the record, and the launch's sweep deleted it (Codex's codex-18). Tests: `EventTests`, the five tests named for a
journal-only incident's photo or a young intent's.
