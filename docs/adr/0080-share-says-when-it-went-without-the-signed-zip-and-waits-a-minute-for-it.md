# ADR 0080: Share says when it went without the signed ZIP, and waits a minute at most for it

- **Status:** accepted. States three decisions 1.12 made: BACKLOG item 200 (the owner, 2026-11-07: "as you recommend,
  wording approved", its option (a)), item 220's defect 1 (the owner, 2026-11-09: into 1.12) and item 234's A2 (the
  owner, 2026-11-11: "1"; decision 3, added that day, before this record's first release). Supersedes in part
  ADR 0070's section 4 ("Nothing new is on screen", and what it says of a bundle that cannot be made) and, in its
  consequences, the sentence that an edit made just before Share "is in the bundle once the log's write of it has
  reached the signer". Written 2026-11-10, after a sweep of the documents against the code found that section stale;
  ADR 0070 has had its amendments, so under AGENTS.md's rule this is a record of its own.
- **Date:** 2026-11-10

## Context

Share offers a signed record's evidence ZIP as one more item of the share sheet, made only once a destination is picked
(ADR 0070, section 4). When the ZIP could not be offered or made, the share went on without it and nothing said so (item
200). And the sheet's own thread waited for the ZIP's making with no limit, while the making signs through App Attest,
whose calls have no deadline of their own: a call that never answered held the share for good (item 220's defect 1).

And a bundle was made from the record's latest signed revision whatever the record had become since. The export
compared the record's photos, clips, thumbnail and traces with what that revision signed (ADR 0070's second
amendment), and not its facts. When a change to a record was not signed, because the signer had not come to it yet
or because its signature had failed, a share sent a ZIP that checked out and showed the earlier facts: without the
owner's mark from the disarm, say, or with a lower count of wrong PINs than the event's screen had. Nothing said so
(item 234's A2, Codex-2 of the third full review). ADR 0070 says such an edit "is in the bundle once the log's write
of it has reached the signer"; a signature that fails is tried again only at the log's next write.

## Decision

1. **After a share that went without the ZIP, the event's screen says so** (`ShareNote`), until the owner leaves the
   screen: only after a share that completed, to a destination that takes files, of this phone's own record. "Sent
   without the signed evidence ZIP: Apple has not certified this iPhone's signing key yet, which needs a network
   connection. Share again once it is online." while no key is certified; otherwise "Sent without the signed evidence
   ZIP: Malinois could not make it just now. Share again later." Nothing is said for a record this phone never signed,
   or has not signed yet.
2. **The sheet waits for the ZIP a minute at most** (`EvidenceBundleItem.makingLimit`). Past it the share goes on
   without the ZIP, as when the ZIP cannot be made, and the screen says the second line. The making is left to end by
   itself, and a ZIP that arrives late is removed at once.
3. **A ZIP is made only with the facts its record's latest revision signed** (`EvidenceExporter.assembled`; added
   2026-11-11). Beside the bytes of the record's photos, clips, thumbnail and traces, the export compares the record's
   facts, as the share has them, with those of its latest signed revision: the two things the signer itself compares
   to decide whether a record needs a new revision. Where they differ no bundle is made: the share goes on without
   the ZIP, and the event's screen says the second line. So a ZIP never shows, as the event's, facts that an earlier
   revision signed and a later change replaced.

## Consequences

- A making that outlasts the minute has usually spent its signature already: the export statement is signed and kept
  before the ZIP is made (`EvidenceExporter.folder`), and no ZIP leaves the phone for it.
- The limit frees the sheet, not the signer. An App Attest call that never answers still holds the signer's turn, so
  later signatures and exports wait behind it until the app is relaunched, and "Share again later" cannot succeed
  before then (BACKLOG item 223).
- The sheet's own ask on the main thread takes the lock the making holds. If iOS asks while a ZIP is being made, the
  main thread waits for it: a minute at most, where it had no limit. Whether iOS ever asks at that moment is not known,
  and the first step is a diagnostic on a phone (BACKLOG item 223).
- A record of this phone whose signing has failed so far is shared without the ZIP and without a line (BACKLOG item
  224).
- Not taken: a deadline on the App Attest calls themselves, which changes what a signature made and not kept means (ADR
  0073).
- A ZIP refused under decision 3 has spent its export signature, as one refused for a photo not signed yet has: the
  export statement is signed and kept before the bundle is put together.
- A record's signature that failed is tried again at the log's next write or the next launch (ADR 0066), not at a
  share. Until then
  "Share again later" gives the same line; any new entry in the log, an arm or a disarm, is such a write. A retry at
  Share itself is a larger piece, for later (BACKLOG item 234).
