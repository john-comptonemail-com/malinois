# ADR 0040: Preserve a surviving PIN across reinstall

- **Status:** accepted (owner's Option B ruling); shipped in 1.5.1 (58), released 2026-10-12. Reinstall and PIN-recovery phone
  checks passed on build 56.
- **Date:** 2026-10-11

## Context

Deleting the app can remove its setup marker and local event log while leaving its
Keychain PIN. Launch previously erased that inherited PIN, presenting an open setup
flow even when cloud evidence survived. Missing `events.json` was also insufficient
proof of a new installation: a journal or preserved media could remain.

## Decision

Never automatically wipe a surviving credential. An intact PIN without a setup marker
requires the existing PIN to resume local access and repair the marker. Keep its
rate-limit state until successful verification, as with ordinary PIN entry. An explicit
forgotten-PIN action invokes the existing `.deviceOwnerAuthentication` policy (biometrics
or device passcode) before replacement. Ordinary disarm remains app-PIN-only.

Keep the old credential until replacement succeeds. Device authentication grants only
an ephemeral reset permission, revoked on background/dismissal. Cancellation, unavailable
authentication, Guided Access, and Keychain errors grant nothing. Only an explicit
Keychain item-not-found status means absence; unexpected errors and unreadable payloads
defer classification. Never treat a failed read as a wrong PIN guess or permission to
create a new salt.

Known prior setup or any surviving local evidence with a missing/damaged PIN requires
device-owner recovery. Include journals, corrupt-log backups, media, and attachment
intents. Empty directories alone do not constitute evidence; an inspection error or
symbolic link conservatively requires recovery. Recovery never deletes those files.

## Consequences

A returning owner can use the old PIN even without a device passcode. Reset requires
iOS owner verification and a successful credential write. A first installation with
no known history can still set up locally. Cloud enrollment is a separate boundary
(ADR 0039); a repaired marker or newly chosen PIN never grants cloud access by itself.

This cannot reconstruct a lost PIN or stop app deletion. A person who can satisfy the
device's owner authentication can reset the PIN. Keychain persistence after uninstall
is not guaranteed, so the independent cloud policy remains necessary. Old installed
versions retain their prior behavior. Real reinstall/authentication checks remain owed;
Simulator tests cannot establish the OS's uninstall or biometric behavior.
