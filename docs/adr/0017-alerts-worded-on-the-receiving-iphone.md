# ADR 0017: Cross-device alerts are worded on the receiving iPhone

- **Status:** detailed rewriting suspended by ADR 0039; generic delivery retained. Decision 5 ended in
  1.8 (item 124's F18): the extension holds no entitlement and reads no container; it reads only which
  subscription sent the push.
- **Date:** 2026-09-28

## Context

The owner's other devices learn of a trip from a CloudKit subscription push. The push's text is
fixed when the subscription is made ("Tamper detected on your device."; "Malinois was disarmed on
one of your devices."), because every custom field of the records is encrypted (`encryptedValues`,
item 19): no push can carry them and no subscription predicate can split on them. So a Vision trip
that may be a shadow or a cat sounded like a touch (the owner, 2026-09-08, item 76), and no alert
said which phone or which tripwire.

Three options were put to the owner on 2026-09-13 (item 77's thinking-through): (a) a plaintext
alert-class field and a second subscription, which leaks one bit per event to the platform; (b) a
Notification Service Extension on the receiving iPhone that fetches the encrypted record and words
the alert; (c) leave it. Ruled: (b). On 2026-09-28 the owner ruled its details "all as
recommended": a Vision-only trip is a banner without sound, every other tamper alert is Time
Sensitive, the disarm alert names the device, the drafts are the wording, and it ships once a
second iPhone on the account has run one real trip of each kind.

## Decision

1. **Both subscriptions send mutable pushes** (`shouldSendMutableContent`), keeping their IDs: an
   account's existing subscriptions are saved again under the same IDs, which replaces them. A new
   ID would make a device still on 1.3.x, which creates only missing IDs, add the old one back, and
   a mixed account would get two alerts per event.
2. **The extension fetches the record the push names** from the private database; CloudKit
   decrypts it for the signed-in owner, so no key is handled in our code. It reads the small meta or
   disarm record, never a photo, and composes the alert on the phone: nothing new leaves either
   device, and the words never pass through the push service.
3. **The words are the Event Log's own** (`Event.sensorSummary`, through `AlertRewrite`, compiled
   into the app and the extension), so an alert and the log never disagree. A Vision-only trip is
   "The camera saw movement." without sound at the ordinary level; every other tamper alert (a
   trip, an interruption, a wrong PIN) keeps its sound and is Time Sensitive; the disarm alert names
   the device; every title names the device (so the disarm body says it once, "Malinois was disarmed.":
   the owner's ruling of 2026-09-28).
4. **Fail loud.** No record in the push, a failed or slow fetch (20 seconds of the extension's
   30), a record type it does not know, or iOS ending the extension: the alert shows as sent. A
   failure never silences an alert, and a receiver without the extension (1.3.x) shows the push as
   sent.
5. **The extension reads the app's container.** Its bundle id is the app's plus
   `.NotificationService`, and it names `iCloud.` plus the app's bundle id (its entitlements say
   `iCloud.$(MALINOIS_APP_BUNDLE_ID)`), not its own.

## Consequences

- An alert says what happened, where; a cat on the camera no longer sounds like a touch; a real
  tamper alert gets through a Focus unless the owner turns Time Sensitive off for Malinois.
- The lock screen of the receiving iPhone now shows which tripwire fired on which device, to anyone
  who can see it, unless iOS's Show Previews setting hides previews until the phone is unlocked.
  SECURITY.md says so.
- The device's name is the only text an alert takes from the record, and the record is cloud input:
  someone holding the owner's iCloud password could write one. The name is shown as one line of at
  most 64 characters, without control or direction-changing characters (added the same night, after
  Claude's review of the build), so a written name cannot add a line to the alert or disguise its
  words. Every other word is the app's own.
- A new target in the hand-kept project, whose version and build number must equal the app's (a
  test pins it); the mirror's export gains its folder, and its team lines go from two to four.
- It cannot be checked end to end on one device. The Debug-only preview in Settings shows the
  alerts as another iPhone would; the real path waits for a second iPhone on the account.
- Not taken: (a), which leaks an alert class per event to the platform; wording on the sending
  side, which cannot vary the text of a CloudKit subscription push.
