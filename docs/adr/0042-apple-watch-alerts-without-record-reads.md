# ADR 0042: The Apple Watch app receives alerts and reads no records

- **Status:** accepted (owner's ruling, 2026-10-12, "go with A"); for 1.6; amended by ADR 0043 (the
  iPhone relays its own alerts over a direct link; one subscription-listing server call). Amends ADR 0013:
  decision 4 narrows from "receives and reads" to "receives", and decision 5's shared
  build-settings file becomes a test over per-target settings.
- **Date:** 2026-10-12

## Context

Item 57's milestone 1 (September 2026, shelved unmerged on `feature/watch-companion`) put the
alert on the wrist and added a status screen and recent-events list read from the owner's private
CloudKit records. It was proven on hardware: an alert reached the watch from its own armed iPhone
under Guided Access.

Since then 1.5.1 drew an enrollment boundary (ADR 0039): private records are read only by an
installation verified with device-owner authentication, and the iPhone's own notification
extension went generic rather than become an unverified background reader. A watch app that
reads records would be another such reader, needing its own verification and a shared
authorization design that has not been reviewed. The owner chose Apple Watch alerts over Room
Watch for 1.6 and accepted the narrower scope.

## Decision

1. **Alerts only.** The watch app registers its own push token, so the existing tamper and disarm
   subscriptions deliver their fixed alert texts to the wrist over the watch's own connection. It
   reads no CloudKit record and writes none; it checks only the iCloud account status for its
   screen. It never arms or disarms. A test pins that it compiles none of the iPhone app's cloud
   code and calls no CloudKit record API.
2. **No shared iPhone source.** The watch target compiles only its own files. The one pure file,
   the screen's wording, is also compiled into the iPhone test target so the suite checks it.
3. **The watch asks for notification permission itself** when it opens, because a one-iPhone
   owner's armed iPhone never receives an alert and may never have asked. Its screen says
   whether alerts will arrive: registration failed, iCloud unavailable, notifications off, ready.
4. **Version lockstep by test.** The watch carries the iPhone app's `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` per target, like the notification extension, and a test fails if any
   app target differs.
5. ADR 0013's other decisions stand: one project, embedded in the iPhone app, watchOS 10 floor.

## Consequences

- No status, history or thumbnails on the wrist until a shared authorization design is reviewed;
  the same design would restore device and sensor names in iPhone alerts.
- The watch shows every alert the account's other devices get, including the disarm alert when
  the owner disarms the watch's own iPhone. Filtering it would need a notification filtering
  entitlement Apple grants separately.
- The watch must be opened once to register and to ask permission; the iPhone's Cross-device
  alerts caption says so.
- Delivery needs a connection: the paired iPhone nearby, or Wi-Fi or cellular of the watch's own.
  Out-of-Bluetooth-range delivery (milestone 1's never-run leg 5) is a TestFlight check.
- The App Store listing needs Apple Watch screenshots; the public export already includes the
  watch folder and expects its two team-ID lines.
