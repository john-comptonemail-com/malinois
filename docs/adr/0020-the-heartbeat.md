# ADR 0020: The heartbeat: a beat every five minutes, a trail and a latest record

- **Status:** accepted; how long the trail is kept amended by ADR 0022
- **Date:** 2026-09-28

## Context

An attacker's best moves against an armed phone are to silence it: a forced restart, a Faraday bag,
destruction. Each leaves nothing on the phone's own record, and on Pro the cloud copy holds only
what went up before. Item 52 (filed 2026-09-01) made the silence itself evidence. The owner ruled
the design pass "all as recommended" (2026-09-28): a beat every five minutes while armed and
online, the reader on the arm record's detail, a beat that cannot be sent dropped and never sent
late, the battery and charging state in each beat; and, for how a reader finds the latest beat
when every field is encrypted, a per-session record saved over (choice (a) of three).

## Decision

1. **A beat every five minutes while a watch is live on a Pro session and online,** the first at
   go-live, so the session's latest record exists from the start. Numbered from 1; a beat that
   cannot go out still takes its number, so a gap shows.
2. **Two records per beat, one type (`TamperEventBeatV2`), every field encrypted:** the trail's,
   created once (`beat-v2-<session>-<n>`), and the session's latest (`beat-latest-v2-<session>`),
   saved over. The session is the id of the watch's "armed" record, which the owner's other devices
   already mirror. The trail is the durable history; the latest record is the one exception to
   write-once in the app's iCloud, and holds nothing the trail does not.
3. **Dropped, never sent late:** one attempt under a 30 s deadline, on its own path, so a failed
   beat is never counted as an evidence upload's failure (item 79's sweep reads those).
4. **The reader** is one row on an arm record from another phone, on Pro: "Last heard from", the
   latest record's server modification time, fetched by name. No record reads "No heartbeat on
   record"; a failed fetch reads "Could not check iCloud".
5. **Silent:** no subscription names the type, so a beat never alerts; a gap is never a siren on
   the phone (ADR 0001: no escalation on ambiguous evidence).

## Consequences

- A silenced phone leaves the time it went quiet, readable from any device on the account.
- Twelve small records an hour while armed. Nothing deleted old beats at first; since ADR 0022
  (1.5) the retention setting's auto modes delete a watch's trail once its last beat is older
  than the setting, and keep its latest record.
- Apple sees that the records exist and when they arrive, as with the disarm signal; SECURITY.md
  says so.
- The new record type must be deployed to Production in the CloudKit Console before a release
  carries it (the owner's step; Part 4 of `store/CLOUDKIT_SCHEMA_1_1.md` has the steps).
- The thermal state rides the beat (follow-up 1, after 1.4): each beat carries iOS's state in item
  38's words, encrypted, left out when it has no name. The field needs its own deploy to
  Production before the release that carries it (Part 5 of `store/CLOUDKIT_SCHEMA_1_1.md`).
- Not taken: one record updated in place with no trail (no history); the reader walking the trail
  by number (a fetch per beat); a plaintext, indexed session field (the platform learns which
  records belong together).
