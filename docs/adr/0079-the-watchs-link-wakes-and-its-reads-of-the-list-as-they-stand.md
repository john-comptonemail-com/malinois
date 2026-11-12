# ADR 0079: The watch gives a link wake back at its deadline, and one run of alerts shares the list's two seconds

- **Status:** accepted. States two decisions 1.12 made in BACKLOG items 212 and 218 (the latter ruled 2026-11-09: "as you
  recommend, wording approved"), which earlier records still said otherwise. Supersedes in part ADR 0043 (decision 3's
  wake rule), ADR 0051 (its sentence on the queued copy's wake) and ADR 0052 (decision 4's deadline, for the reads before
  posts). Written 2026-11-10, after a sweep of the documents against the code found the three stale; ADR 0052 has had
  its amendments, so under AGENTS.md's rule this is a record of its own.
- **Date:** 2026-11-10

## Context

The watch app is woken in the background by WatchConnectivity to take the alerts its iPhone relays. ADR 0043's decision 3
held each wake until every alert handed over had been posted. watchOS ends an app whose wake outlives about 15 seconds:
the crash of 1.6 (61), and once more on 1.8.2 (79) (BACKLOG item 212). Before each relayed alert is posted, the app reads
the watch's list of delivered notifications, to pair the alert with iCloud's copy of it (ADR 0052), and ADR 0052's
decision 4 gave every such read 2 seconds. A backlog of alerts with a list slow to answer could so outlast any wake.

## Decision

1. **A link wake is given back after 10 seconds at the latest,** whatever is still in flight (`WatchLinkWakes`; item 212).
   An alert whose handling that cuts off is shown when the app next runs, or lost if watchOS ends the suspended app
   first.
2. **The alerts handed over in one run share 2 seconds for their reads of the list** (`WatchRelayInbox`; item 218). A run
   is the alerts handed in while any is still to be handled. The time a read took counts whether or not the list
   answered. Once the 2 seconds are used, the rest of the run is posted without the list, as an alert already was when
   the list did not answer: with sound, nothing removed, iCloud's copy of the event leaving the list at the next
   tidy-up. The next run has the 2 seconds whole.
3. **Each clean-up read keeps 2 seconds of its own** (at an iCloud wake, when the app opens, at a repeat), as ADR 0052
   decided.

## Consequences

- Six alerts and a list that does not answer cost one wait of 2 seconds, where they cost six.
- An alert posted without the list can leave its event with two entries in the watch's list until the next tidy-up: one
  more case beside those ADR 0052's decision 5 lists.
- Not done, and for the next release (BACKLOG item 219): an alert written down when it is handed over and kept until it
  is shown. Until then a post that is itself slow can still be cut off, and an alert cut off is only in memory.
- Superseded by this record: ADR 0043's "holds each background wake until the link has handed over everything queued and
  every alert it handed over has been posted"; ADR 0051's "in a background wake that is held until the alert is handled";
  and, for the reads before posts, ADR 0052's "Every pairing or clean-up read of the list in the app ... has a deadline
  of 2 seconds".
