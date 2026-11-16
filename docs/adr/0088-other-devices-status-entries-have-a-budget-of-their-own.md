# ADR 0088: Other devices' status entries have a budget of their own

- **Status:** accepted (the owner, 2026-11-14: "as you recommend", on TestFlight 88's step 8, BACKLOG item 242).
  Amends ADR 0035's budgets, where mirrored copies went first within either budget.
- **Date:** 2026-11-14

## Context

ADR 0035 keeps 500 incidents and 100 status entries on a device, and mirrored copies go first within either budget, so
that cloud input cannot evict first-hand evidence. A phone's own status history (its arms, disarms and settings
changes) reaches 100 within weeks of use; from then on each status entry another device sends went as it arrived, the
oldest first. TestFlight 88's step 8 showed it: an iPad's "reinstalled" entry reached iCloud ("iCloud synced" on the
iPad) and never appeared on the iPhone, whose status history was full, though SECURITY.md and the README promise that
entry in the owner's other devices' logs. The same held for every status entry another device sends: a PIN change,
iCloud backup turned off, a set-aside log deleted, iCloud space freed.

## Decision

1. **Three count budgets:** 500 incidents, 100 of this phone's own status entries, and 100 of other devices' status
   entries, all of them together (`EventStore.maxMirroredAuditEvents`).
2. **Each status budget takes its oldest entries first.** Other devices' entries never count against this phone's own,
   so cloud input still cannot displace this phone's status history, and this phone's own entries no longer push
   other devices' out.
3. **The incident budget is as ADR 0035 has it:** mirrored copies of incidents go first.
4. As before (ADR 0035 and its amendments): the newest first-hand row in each of this phone's budgets stays, and a row
   whose upload is running is left alone until it ends.

## Consequences

- A phone keeps up to 100 status entries from its owner's other devices, so an iPad's "reinstalled" entry stays on the
  iPhone until a hundred newer ones from the other devices replace it.
- A log can hold up to 700 rows, not 600; a status entry is small and carries no media.
- A pull still asks iCloud for up to 600 records of each type (`EventStore.maxEvents`), more than both status budgets
  need.
- An entry a phone dropped before this change comes back at its next pull that reaches it: a pull asks for the newest
  records, and the entry is still in iCloud.
- Other devices' incidents still go first once a phone has 500 incidents of its own: no document promises otherwise,
  and a phone rarely gets there; noted in BACKLOG item 242.
- The Debug seed of status records fills this phone's own budget only; no copy gives way to it.
- Tests: `Item242RoundQTests`, through the rule (`EventStore.countEvictionOrder`) and through the real store with a pulled
  "reinstalled" entry.
