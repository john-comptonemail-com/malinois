# ADR 0085: An event log set aside that the list does not show is said on Home, at that launch

- **Status:** accepted. BACKLOG item 224's point 1, in 1.13 (item 240's list; the owner, 2026-11-12: "as you recommend",
  option (a)). Supersedes in part ADR 0078 (decision 5's "and has no notice", for the event log itself), which has had
  its three amendments.
- **Date:** 2026-11-12

## Context

Since 1.12 a set-aside log is a plain file: the list of set-aside logs, the screen, Share and Delete take neither a
folder nor a link under such a name (ADR 0078's decision 5, item 218), and Home's notice follows the list. An event log
that is a folder or a link (only an edited backup restored to the phone can put one there) is still set aside at the
launch that cannot read it, and a fresh log starts; but the list does not show it, so nothing said so. 1.11 did, in the
line 1.12 replaced with the list's notice; the store's flag for it was set and read nowhere.

## Decision

1. **The store notes when the log it sets aside is not a plain file** (`EventStore.setAsideNotListed`, at the load at
   launch or after the unlock), so not one the list shows.
2. **Home says so at that launch, in 1.11's words:** "The event log couldn't be read and was set aside as a backup - new
   events go to a fresh log." In red, as that line was, with the list's own notice beside it while any plain set-aside
   log is kept.

## Consequences

- The owner is told, at that launch, that a log went out of sight. Nothing more: the thing set aside stays where it was
  moved, holding the media sweep and the limits' removals, as ADR 0078's decision 5 decided for the safe side, and it
  cannot be opened, shared or deleted in the app.
- Not taken (the owner's ruling): leaving such a log in place and stopping the store's writes (b); leaving it as it was
  (c).
- Tests: `Item224FailureNoticeTests`, with a folder in the log's place and Home laid out for real.
