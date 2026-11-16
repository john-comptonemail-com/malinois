# ADR 0087: A set-aside log's Share leaves out the photos and clips the current log names

- **Status:** accepted. BACKLOG item 241's A4 (DeepSeek-4) and gpt6-astra-r1, in 1.13 (the owner, 2026-11-13: "as you
  recommend, wording approved", on the full review and again on the change review of its fix). Supersedes in part ADR
  0078 (decision 2: which photos and clips the ZIP has, and its README's first sentence), which has had its three
  amendments. Decision 1's captures still being saved added the same day (the owner: "as you recommend", item 241's
  gpt6-astra-m1), and how Share reads them (gpt6-astra-n1, the same words), before this record's first release.
- **Date:** 2026-11-13

## Context

ADR 0078's decision 2: Share of a set-aside log sends one ZIP, the file as the phone kept it, byte for byte, with each
photo and clip on the phone that the file names (by the names decision 3 allows) and a README. Its Delete takes only the
photos and clips nothing else names: not the event log, another set-aside log or a capture still being saved.

1.13's full review (DeepSeek-4): only an edited backup restored to the phone can make a set-aside log name a photo or clip
of the current log, and Share then carried it to whoever the owner sends the log to. The first fix let such a photo go
when one of the set-aside log's readable records held the same event, so that a record the journal brought back at the
launch that set the log aside would go with its photo. The change review of that fix (gpt6-astra-r1): those records are
the edited file's own, so an edit copies a live event's ID as readily as its photo's name, and the check stopped only an
edit that changed the name alone. Nothing in a set-aside file can show which event a photo is of. The change review of
this decision's first form (gpt6-astra-m1): Share took the log's names once, before the ZIP was made, and a clip the
launch's retry saves (one a refused save left waiting) is published first and named in the log a moment later; its
intent gives its name, so an edited backup can make a set-aside file name it.

## Decision

1. **Share leaves out every photo and clip the current log names**, as Delete leaves them alone: for the same event as
   for another, whatever a record of the set-aside log claims, **and every photo and clip a capture still being saved
   names** (its attachment intent), as Delete leaves those alone too. The ZIP has the file byte for byte, the README, and
   the photos and clips the file names that are on the phone and that neither the current log nor a capture still being
   saved names. The store gives the screen those names (`EventStore.mediaSetAsideShareLeavesOut`): what is being saved
   first, off the main actor, then the log's names; an intent goes only once a log naming its photo or clip has been
   written, after the log took it, so nothing passes between the two reads. Share reads the intents folder its own way
   (gpt6-astra-n1): a file recovery never acts on names nothing (one it never reads, or one that reads but is no intent
   under its name, as the writer's temporary that a stop before its rename leaves); when the folder cannot be listed or
   a file there cannot be read, no ZIP is made, as when a ZIP cannot be made: nothing opens.
2. **The README says so.** Its first sentence: "This ZIP contains an event log Malinois set aside because it couldn't be
   read, with the photos and clips it names that were still on the iPhone when it was shared, except any the current
   event log also names." Its other two sentences as ADR 0078 has them. SECURITY.md: "Since 1.13 Share also leaves out a
   photo or clip the current log names, which Delete already left alone."

## Consequences

- An edited backup cannot make a set-aside log's Share carry a capture of the current log.
- A record the journal brought back (the set-aside screen marks it "Also in your event log") goes without its photo or
  clip; its event in the Event Log shares them, in its own evidence ZIP. Records pulled from iCloud name no file here, so
  a restore leaves nothing out.
- An edited set-aside log can still name a photo or clip that only another set-aside log names, and Share then carries
  it: a capture of a log set aside too, which no other Share sends.
- Not taken (the owner's ruling): keeping the exception for the same event and saying its limit; trusting a set-aside
  log's records only when something the phone signed binds its bytes (a change to what the phone signs). Nor Delete's
  whole rule: a photo two set-aside logs name, and the current log does not, would then go with neither log's Share, and
  nothing else could share it.
- Share makes no ZIP when the intents folder cannot be listed or a file in it cannot be read (damage, or an edited
  backup), and says nothing, as for a ZIP that cannot be made. A file the store's own writer leaves does not stop it
  (gpt6-astra-n1: Delete's reading, which Share first took, made the writer's leftover temporary stop every Share until
  the 30-day clean-up). Delete keeps its stricter reading: its "unknown" leaves the photos and clips and says so.
- Tests: `Item122SetAsideLogTests` (the rule; the folder; gpt6-astra's probe, an edited record carrying a live event's
  ID; the ZIP, read by the names its directory lists; the README's words; the screen's and the store's wiring) and
  `Item152LockedSaveTests` (a clip the launch's retry is still saving, the retry held while Share takes its names; no
  names when the intents folder or a file in it cannot be read; names past the writer's leftover temporary, a half
  written one and a name recovery never reads).
