# ADR 0022: Old heartbeat trails follow the retention setting; each watch keeps its latest beat

- **Status:** accepted
- **Date:** 2026-09-29
- **Retention amendment, 2026-10-10:** ADR 0035 replaces the local total-count limit
  with 500 incidents / 100 statuses. The independent watch registry is unchanged.
  A readable legacy log seeds the shared registry before any count trimming,
  including journal recovery and unlock reconciliation. Arm rows already lost
  before upgrading remain the conservative leftover described below.

## Context

The heartbeat (ADR 0020, 1.4) writes, while a watch is live on Pro, one record per beat every
five minutes (the trail) and one record per watch saved over at each beat (the latest). Nothing
deleted them: a ten-hour armed night adds about 120 records, roughly 100 KB by estimate, and
nightly use adds tens of MB a year to the owner's iCloud. No reader walks an old trail; "Last
heard from" reads only the latest record. The daily retention pass (32.R2) already deletes
full-resolution media past the owner's setting, with a 30-day floor enforced inside the purge
itself so a PIN-holder cannot use it to destroy fresh evidence.

Three options were put to the owner (item 52, follow-up 2):
1. leave old beats;
2. the retention pass also deletes a watch's trail once the watch is older than the setting,
   keeping its latest record, for this phone's own watches only and never under Manual or
   Keep forever;
3. delete the trail and the latest alike, so an old watch's row would read "No heartbeat on
   record", which is untrue.

Ruling: option 2, for 1.5 (the owner, 2026-09-29, as recommended).

A Fable review of the first build, before it merged, found three ways it fell short:
- it judged a watch by its start, and a watch begun before the cutoff can have beaten inside it,
  so beats newer than the floor could go;
- it found the watches in the event log, then capped at 500 total records, so in nightly use a
  watch's arm record can leave the log before the default 12 months are up, and then its trail
  would never have been trimmed;
- the two records of a beat save separately, so a watch's last beats can have trail records past
  the number its latest record carries, and those were never deleted.

A second Fable review, of the reworked build, found no way for a beat newer than the floor to
go. It asked for the decisions to be tested where they are made (they sat in code that talks to
iCloud), for the log's arm records to be added at the first Pro watch too, and for the trim's
fetches to be bounded like its deletes. The decision below is the build after both reviews.

## Decision

1. **The daily retention pass trims old beat trails** in the auto modes (1 to 12 months) only,
   after the media purge, with the same cutoff: never under Manual or Keep forever, never the
   live watch.
2. **Each watch keeps its latest record**, so "Last heard from" answers for every watch in the
   log, however old.
3. **This phone's own watches, from a list it keeps:** each Pro watch joins the list as it goes
   live (the arm record's id and its start). Once, before count trimming of a readable
   legacy log (ADR 0035), its own arm records join too, for 1.4's watches. The engine
   also checks before the first Pro watch or pass; only from a log read from disk,
   since a log still locked after a
   restart reads as empty. Copies from other devices never join. The list is kept apart from
   the log, so the log's cap does not hide an old watch.
4. **Judged by the last beat, by the server's clock:** a watch that began before the cutoff is
   looked at, and its trail goes only when its latest record's server time is before the cutoff
   and every beat found in the 12 numbers past that record's is older than the cutoff too.
   Otherwise the whole trail waits. The cutoff is floored at 30 days inside each of these
   decisions (`beatTrimStep`, `beatTailVerdict`, pure and unit-tested), as in the media purge,
   whatever a caller asks, so no beat newer than 30 days is deleted in any mode.
5. **What goes:** trail numbers 1 through the latest record's number plus 12; a number with no
   record is answered "not found" and counts as gone. The latest record's number is believed up
   to a year of beats (105,120); a latest record without its number or its time is left alone
   and logged.
6. **Bounded:** at most 50 watches a pass, oldest first, with one iCloud account check for the
   pass, and each fetch and delete under the save deadline (20 seconds), cancelled if it stalls.
   A watch leaves the list when its trail is deleted, or when it has no latest record (it never
   beat). A watch whose last beat is too recent, or whose trim failed, stays for the next pass.
   Trimming never changes when the pass runs: the media purge alone decides that.

## Consequences

- An old watch loses the gaps in its trail (when each beat arrived) and keeps when it was last
  heard from. A watch that beat inside the window keeps its whole trail.
- A second deletion path in the app, under the same owner setting, the same floor and the same
  conservative server-date anchor as the media purge (ADR 0036 supersedes the original
  phone-clock cutoff). An unavailable anchor defers trimming; an older anchor only delays it. SECURITY.md and the README say what the retention pass
  deletes.
- Every leftover errs toward keeping, a few KB each: this phone's watches from before a reinstall
  come back as copies and never join the list (a restore from a device backup brings the list
  and the log back, and those are trimmed as before); 1.4's watches whose arm records had left
  the log before the upgrade's first successful read never join it either; a beat more than 12 numbers
  past its latest record's stays; a watch whose latest record never saved is taken as never
  having beaten; and so is a watch looked at while the phone reads another iCloud account, or
  another CloudKit environment than the one it beat into (a Debug build from Xcode reads
  Development), which leaves the list with its trail in place.
- Under Manual or Keep forever the list grows by one small entry per Pro watch (about 25 KB a
  year of nightly watches) and drains, 50 a day, once an auto mode is chosen.
- A watch whose trim fails every time stays at the front of the line; it would take 50 of them
  to hold up the rest.
- Each watch trimmed costs two small fetches and one delete per 200 beats. The first passes
  after updating work through the backlog over a few days.
- Not taken: walking the owner's iCloud for every device's watches (the arm records' kind is an
  encrypted field, so no query can select them; a walk would read every audit record); deleting
  the latest record too (option 3); judging a watch by its start (the first build); keeping in
  the list whether a watch ever beat, so that "not found" for one that did would count as a
  failure (after the owner deletes the app's iCloud data, every such watch would then fail at
  every pass, and 50 of them would stop the trimming for good).
