# ADR 0036: Retention uses a conservative cloud time observation

- **Status:** accepted; supersedes ADR 0022's phone-clock cutoff only
- **Date:** 2026-10-11

## Context

Both full-media cleanup and heartbeat trimming protected the most recent 30 days,
while computing that boundary from the phone's wall clock. Moving the clock forward
could make recent server-stamped evidence eligible. The app PIN alone does not grant
iOS clock-setting access, but the advertised floor should not depend on that setting.
The owner authorized the evidence-preservation recommendations following three reviews.
These maintenance changes are based on submitted 1.5; release numbering remains a
separate preparation step. Device-authenticated records are explicitly outside scope.

## Decision

Deletion entry points accept a month policy, not a caller-calculated absolute cutoff.
They read the newest available system `creationDate` from existing V2 audit and fact
types (one result each, no custom fields). If neither yields a usable observation,
the legacy fact type is tried. A usable date is a **lower bound** on server time, not
proof of the current time. Taking the largest available observation improves cleanup
without making it unsafe. Custom event dates and the phone clock cannot advance it.

The month cutoff uses a Gregorian calendar in UTC, then clamps to 30 elapsed days
before that observation. Invalid policies or missing/nonfinite time prohibit deletion.
Both media and beat entry points establish this condition independently. A stalled
observation query is cancelled after the existing 20-second operation deadline.

No clock record is written, no record type/index is introduced, and cleanup does not
need spare cloud quota for a clock write. Existing query permissions/indexes suffice.
The phone clock still schedules attempts and shortlists old watch sessions; that can
delay cleanup but cannot authorize deletion of recent evidence. Keep forever and
Manual semantics, latest-heartbeat preservation, and incident/status limits are unchanged.

## Consequences

- A clock moved forward cannot bypass the selected period or the 30-day floor.
- An idle account can retain more than requested: its final retention window remains
  until a newer audit/fact is uploaded. A successful new arm/disarm or incident upload
  supplies such an observation; a quota problem may prevent that update, so cleanup can
  retain the final window even when it is old by real time. No observation means cleanup reports failure
  and keeps the records. This is intentional under-deletion, disclosed in Settings.
- Media age remains the parent event's server creation date; a late upload for an old
  event does not restart the retention period. Facts/thumbnails/audit/latest beats stay.
- Server timestamps are trusted; this does not prevent external iCloud deletion or
  authenticate the contents/producer of a record.
- The pre-existing media candidate walk is not wholly deadline-bounded. This change
  bounds the added observation queries, not the duration of every cleanup operation.
- Tests replace only transport at the real deletion entry points. Live CloudKit
  permissions/index/timing behavior still needs a narrow device check before release.
