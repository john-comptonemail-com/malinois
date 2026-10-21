# ADR 0041: The PIN pad submits at the PIN's confirmed length

- **Status:** accepted (owner's ruling, 2026-10-12); for 1.6. Supersedes the disarm pad's length
  concealment (finding F-25, built into the first version) and the setup screen's "6 recommended"
  nudge (reviews R1-L1 and R2). Amended for 1.6 (65) after the 1.6 reviews (BACKLOG 108, F10 and the
  owner's decision 3): ✓ returns after a wrong entry; setup advises a code of its own.
- **Date:** 2026-10-12

## Context

Since the first build the disarm and gate pad hid the PIN's length: one dot per typed digit and an
explicit ✓, never an automatic submit. Setup accepted 4 to 6 digits and recommended 6. A user asked
for the PIN to submit itself once entered correctly.

Submitting "as soon as it is correct" cannot be made safe: checking after every digit either counts
the owner's own partial entries as wrong guesses or gives an intruder free, unrecorded guesses past
the lockout. The safe form is the iPhone passcode's: submit when the PIN's length is typed and treat
that entry exactly like an explicit submit. Its cost is that the length is no longer secret.

That cost is small. The lockout (5 free wrong tries, then waits doubling from 30 seconds to an hour
per guess, reset by a correct entry) holds a random 4-digit PIN for about 7 months of nonstop
guessing and a random 6-digit PIN for about 57 years, and every attempt on the armed pad is
recorded and photographed. A guesser who does not know the length starts with 4-digit PINs anyway.
The realistic risk is a predictable PIN at any length: a 2020 study of smartphone unlock PINs
(Markert et al., IEEE S&P) found the 6-digit PINs people choose barely harder to guess than 4-digit
ones for an attacker limited to 10 to 100 guesses. Malinois had no check for predictable PINs.

Older builds also stored the PIN's length without checking that the write succeeded, so a phone can
hold a length that no longer matches its PIN. A pad that trusted it would submit at the wrong digit
and lock the owner out.

## Decision

1. The entry pad submits once the PIN's **confirmed** length is typed and shows no ✓. The entry
   goes through `KeychainService.verify` exactly as an explicit submit does: a wrong one counts
   toward the lockout and, on the armed pad, is a wrong-PIN record with its photo.
2. The confirmed length is a separate Keychain item, written only after a successful PIN change or
   a successful entry. A PIN change deletes it before writing the new PIN, so it is either correct
   or absent, never stale. Without it, including the first entry after upgrading, the pad shows ✓.
   The older stored length is never used to submit.
3. New and changed PINs are 4 digits by default, with 6 one tap away. An existing 5-digit PIN keeps
   working and auto-submits at 5 once confirmed.
4. Setup and Change PIN warn when a new PIN is among the easiest to guess (`PINStrength`: repeated
   digits, runs in steps of 1 or 2, repeated pairs or halves, doubled digits, mirror images, years
   1900 to 2039, keypad lines and other well-known choices) and offer "Use Anyway". Nothing is
   blocked. Dates are not checked: they are too large a share of PINs for a warning to stay useful.
5. The pad still shows one dot per typed digit, not placeholders for the full length.
6. After a wrong entry the pad shows ✓ for the rest of that entry (65). Decision 2 makes a stale
   length unlikely, not impossible: a confirmed length that were ever wrong would submit at it on
   every try, and the owner could never enter the real PIN. The next presentation reads the
   length again.
7. Setup advises a code different from the iPhone passcode and the Guided Access passcode (65;
   the owner kept the 4-digit default): a code shared with either falls with it, to one glance
   over the owner's shoulder.

## Consequences

- Anyone who tries the pad once learns the PIN's length. The lockout, the records and the warning,
  not the length, carry the defense.
- A typo on the last digit submits at once and counts as a wrong try; on the armed pad it is a
  wrong-PIN record with a photo. The 5 free tries absorb occasional slips.
- After the 1.6 update the first PIN entry uses ✓ once; later entries submit by themselves.
- SECURITY.md no longer claims the pad hides the PIN's length.
