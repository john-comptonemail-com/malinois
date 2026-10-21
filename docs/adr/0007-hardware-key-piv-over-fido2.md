# ADR 0007: Hardware-key disarm rides CryptoTokenKit PIV, not FIDO2

- **Status:** accepted (owner ratified, 2026-08-31)
- **Date:** 2026-08-31

## Context

Item 14 (key-gated disarm) was fully scoped 2026-08-27 on the ASAuthorization/FIDO2
security-key APIs. The owner challenged the route's one structural dependency: FIDO2
assertions bind to a relying-party domain served over an apple-app-site-association
file — and the enrollment roster is device-local by design, so a **reinstall after
theft** (the app's core recovery story) must re-enroll, which requires that domain to
answer a live AASA fetch. The owner's requirement — "there's no server" (the original
spec's motto) — is violated not in the happy path but exactly in the scenario the app
exists for. Meanwhile the iOS 26 SDK shipped a native smart-card NFC path
(`TKSmartCardSlotManager.createNFCSlot`, `TKSmartCardSlotNFCSession`, `TKSmartCard`),
removing the hand-rolled-CoreNFC cost that had originally pushed the design toward
FIDO2's built-in UI.

## Decision

Route A: **PIV over CryptoTokenKit**, both transports, no vendor SDK.
`createNFCSlot` (iOS 26) or an enumerated wired CCID slot → `TKSmartCard` APDUs →
PIV applet, slot **9E** (card-auth: tap-is-possession, no PIV-PIN), ECC P-256
generate-on-key at enrollment, challenge/sign/verify (CryptoKit) at disarm. The
enrollment roster lives in the device Keychain; re-enrollment after reinstall needs
only the physical keys. The living spec is `design/hardware-key-spec-a.md`.

## Evidence (on device, 2026-08-31, offline throughout)

NFC and wired slots both proven; PIV SELECT answered `SW 9000` in 9–10 ms on both;
under Guided Access the system sheet is suppressed but the RF field stays live —
key-disarm runs headless on the app's own UI, which the FIDO2 route could not have
done (its sheet is mandatory). Accessory-security matrix: enrolled keys replug-admit
under GA on the "Ask for New Accessories" tier. Run logs and fixture bytes: BACKLOG 14.

## Consequences

- **Serverless is structural** — nothing to keep alive, nothing to fetch at
  re-enrollment; every validation run happened with no network.
- One transport code path serves NFC and USB-C; the 5C-Nano-vs-NFC hardware fork
  dissolved (both purchased keys do both). NFC is the dependable transport: iOS
  accessory allowances lapse (~30 days unused) and the re-allow prompt is suppressed
  under Guided Access, so wired is opportunistic — and no accessory-security setting
  is recommended to users either way.
- We own the PIV layer: management-key mutual auth + GENERATE + GENERAL AUTHENTICATE
  (~hundreds of lines + fixtures) instead of a framework's CBOR/attestation parsing.
- The NFC path sets an **iOS 26 floor** for the feature.
- Security-Key-series keys (no PIV applet) are incompatible — a user-facing note.
- Headless-under-GA is a behavior, not a documented contract — if a future iOS presents
  the sheet under GA instead, the flow still works (the sheet is chrome, not transport).

## Supersedes

The FIDO2-era implementation plan inside BACKLOG item 14 (2026-08-27), retained there
as history; `design/hardware-key-spec-original.md`'s hand-rolled-CoreNFC transport,
whose PIV direction this ADR revives on the OS-native stack.
