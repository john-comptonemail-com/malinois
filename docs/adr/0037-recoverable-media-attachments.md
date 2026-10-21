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
intents suspend the ordinary orphan sweep. Enumeration is limited to 1,200 entries and
manifests to 512 KB. Retained staging payloads plus an incoming capture are limited to
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
