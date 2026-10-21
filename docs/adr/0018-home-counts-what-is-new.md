# ADR 0018: Home's Event Log count is what is new since the owner last looked

- **Status:** accepted
- **Date:** 2026-09-28

## Context

Home's "Event Log (N)" counted every record except the arm/disarm and other audit rows (item 10),
so beside a full log the number read like a miscount ("It says 500 of 500 but the count shows
173", the owner, 2026-09-25, item 81). Three options were put to the owner: count every row (it
climbs by two at every arm and disarm and sticks at the cap); keep the count and name it ("173
alerts"); or count what is new since the owner last opened the log. Ruled: the third, for 1.4,
and then, on two ways of remembering "seen", "remember what I've seen" (2026-09-26).

## Decision

1. **N is the records the owner has not seen**, audit rows excluded: "Event Log (3 new)", hidden at
   0.
2. **"Seen" is a set of record ids**, kept in `seen.json` beside the log with the log's file
   protection, not a date: a record that reaches this phone late (a mirror dated before one
   already seen) still counts.
3. **The Event Log marks everything seen** when it opens and when it closes. It is behind the PIN
   (or the owner's opted-in Face ID or Touch ID), so only someone who can open the log can clear
   the count. Implementation amendment, 2026-10-10: Home's authenticated navigation binding
   marks the current records before publishing a real open/close transition. Back and background
   dismissal close the same visit; detail navigation stays inside it. View appearance callbacks
   do not acknowledge records, since they can run after navigation has returned to Home.
   Redundant closes and cancelled PIN prompts leave unread events untouched. A cloud pull
   completing after closure does not acknowledge its arrivals; they remain new.
4. **What the log already held is seen, and so is what a restore brings from before the
   install.** The first time the log can be read with the feature (an update from 1.3.x; a locked
   launch waits for the unlock), its history is adopted as seen. When that first read finds the
   log empty (a reinstall, or a new device on the account), the moment is noted beside the log
   (`restore-owed.json`) and a restore is owed: until a launch pull reaches iCloud and runs to the
   end, whatever a pull brings that is dated before the install is seen, and the launch pull asks
   for everything the log can hold. Anything dated after the install, and every pull once the
   restore is settled, brings news. (Amended 2026-09-28 for the review's finding C1, item 89: the
   first version called a launch pull into an empty log a restore, and any other pull news.)

## Consequences

- The number answers the question it exists for (did anything happen while I was away?) and never
  sticks at the cap.
- The count is still visible without the PIN (volume, never content), as before.
- A restore is judged by the moment of the install, not by an empty log (the 2026-09-28 review,
  item 89, C1). The empty-log rule counted a restore that waited past the first arm (the first
  launch offline, or Pro unresolved) as new, and took a receive-only phone's first mirror, when a
  launch pull brought it, for history. The rule "no record but audit rows" was not taken either:
  it would also hide the first mirrors on a phone that has only ever received them.
- Dates decide only while a restore is owed; afterwards "seen" is the set of ids alone, so a late
  mirror still counts (decision 2). A mirror dated within clock skew of the install can fall on
  either side.
- A pull made before the first unlock after a restart, if iCloud answers one, cannot read the note
  (it has the log's file protection): what it brings counts as new until the log is opened, as
  before the amendment.
- Someone holding the owner's iCloud password could backdate a mirror while a restore is owed, to
  keep it out of the count. Deleting it from iCloud was always easier, and the record still shows
  in the log.
- Not taken: counting every row, and naming the old count.
