# ADR 0023: Swift 6 language mode

- **Status:** accepted
- **Date:** 2026-09-29

## Context

Malinois was written in Swift 5 with the default, minimal concurrency checking. Its concurrency
is deliberate (a main-actor engine, a camera confined to its own queue, CloudKit callbacks on
CloudKit's queue) and has been reviewed many times, but the compiler checked little of it. Since
1.3 the switch of every target to Swift 6 had waited for a release of its own (the backlog's
structure slate; review 31's camera-confinement finding, F17, was deferred to it).

Item 97 sized it on the combined 1.4 code: 104 diagnostics under complete checking, 24 to fix in
the app and the alert extension and 3 plain warnings, 25 in item 14's debug-only spike, and 52
mechanical ones in the tests.
Three choices went to the owner, ruled 2026-09-29 ("all as recommended"): fix everything under
complete checking, so every step builds, then switch all three targets at once in one release
(1a); put item 14's spike behind its own compile flag (2a); not adopt Xcode 26's default
main-actor isolation (3a).

## Decision

1. **Every target builds in Swift 6 mode** (`SWIFT_VERSION = 6.0`: the app, the tests, the alert
   extension), with no warning.
2. **The fixes keep behavior.** Constants and pure helpers are `nonisolated`; the deadline helper
   runs on the main actor, where its callers are, with its timer off it as before; a notification's
   values are read where it arrives, and only they cross to the main actor. `nonisolated(unsafe)`
   appears only where a promise the compiler cannot see holds, stated beside it: written at
   launch, or only on the main actor where every reader is; set in `init` and read in `deinit`; an
   immutable value; a handler called once, on the main actor.
3. **A callback that iOS runs off the main thread is marked `@Sendable`**: CoreMotion's motion
   handlers and CloudKit's operation blocks. In Swift 6 an unmarked closure written in main-actor
   code is taken for main-actor code, and the compiler inserts a check at its entry that stops the
   app when it runs anywhere else. A probe build confirmed the check for CoreMotion: unmarked,
   every watch and every calibration would have stopped at the first motion sample.
4. **The original September 29 build's runtime checks were reviewed** (479 functions, mapped
   from its object files): each runs on the main thread (SwiftUI's and UIKit's calls, closures run in place,
   main-queue and main-run-loop callbacks, Combine sinks that receive on the main run loop). The
   alert extension has none. New code that hands a closure to an Apple API that calls back on
   its own queue marks it `@Sendable`.
5. **Item 14's spike compiles only with the `SPIKE14` compilation condition**, and is brought to
   Swift 6 when item 14 resumes.

## Consequences

- Swift 6 checks actor isolation and transfers of non-Sendable values more strictly. Explicit
  `@unchecked Sendable` and `nonisolated(unsafe)` promises still need review; a clean build is
  not proof that no data race exists.
- One failure is new: a runtime check that fails stops the app. The audit covers the code as it
  is; the device pass (checklist B21) walks every path where iOS calls the app back before a
  release carries the change.
- The tests' `setUp` and `tearDown`, which XCTest runs on the main thread without saying so to
  the compiler, assert it (`MainActor.assumeIsolated`).
- Not taken: default main-actor isolation (it changes every type's isolation at once); turning the
  runtime checks off (`-disable-dynamic-actor-isolation`, which would hide the one failure the
  audit cannot rule out for code written later); bringing the spike to Swift 6 now.
