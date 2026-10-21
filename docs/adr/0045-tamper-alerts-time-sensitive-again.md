# ADR 0045: Tamper alerts are Time Sensitive again, on the iPhone and the watch

- **Status:** accepted (owner's ruling, 2026-10-12, "B, go ahead", on the 1.6 independent review's
  finding 3); in 1.6 from build 63. Restores the Time Sensitive tamper alerts of the owner's
  2026-09-28 ruling (ADR 0017), lost when 1.5.1's alerts went generic. Amends ADR 0039 (the
  extension now sets the level from the push, still reading no record) and ADR 0043 (the relayed
  tamper alert asks for Time Sensitive).
- **Amended 2026-10-19 by ADR 0052** (1.8 (75)): the watch has an alert extension too, which shows iCloud's tamper
  alert Time Sensitive, as the iPhone's does, unless the relay's copy of the event already tapped.
- **Date:** 2026-10-12

## Context

In 1.4 and 1.5 the receiving iPhone's alert extension fetched each record and set the level: Time
Sensitive for every tamper alert but a Vision-only trip (the owner's ruling, 2026-09-28; on
TestFlight on 2026-09-30 a Touch alert came through Do Not Disturb, with only the app holding the
capability). 1.5.1 made the extension pass alerts through without reading records (ADR 0039). An
iCloud subscription cannot ask for an interruption level, so from then on every alert arrived at
the ordinary level and a Focus or Sleep could hold a tamper alert, while the App Review notes still
said "Time Sensitive". The 1.6 review found the same on the watch's relayed alerts; its premise,
that the iPhone's alerts were still Time Sensitive, was out of date.

## Decision

1. **iPhone.** The extension reads which subscription the push names, from the push itself, and
   shows the tamper subscription's alerts Time Sensitive. Words, sound and payload stay as sent, no
   record is read, and the disarm alert keeps its level.
2. **Watch.** The relayed tamper alert asks for Time Sensitive; the disarm alert does not. The watch
   app holds the Time Sensitive Notifications capability in both entitlement files, as the iPhone
   app has since 1.4 (the extension needs none of its own, as 1.4's device test showed).
3. **No Vision-only exception.** Telling a camera-only trip apart needs the record, so it is Time
   Sensitive too; 1.5's quiet banner for it returns only with a reviewed shared-authorization design.

## Consequences

- A tamper alert breaks through Focus and Sleep on the iPhone and in the watch's relayed copies,
  unless the owner turns Time Sensitive off for Malinois in the device's notification settings.
- A Vision-only trip (a shadow, a pet) breaks through too, with sound.
- The watch's iCloud copies (alerts from the owner's other devices) keep the ordinary level: raising
  them would need a notification service extension in the watch app, which is not built.
- The watch app's identifier gains a capability, which automatic signing registers at the first
  archive or upload.
