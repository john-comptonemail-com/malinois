# ADR 0023: Swift 6 language mode

- **Status:** accepted
- **Date:** 2026-09-29
- **Summary:** Every target builds in Swift 6 mode with no warning, and the changes keep the app's behavior.
- **Amended 2026-11-09** (BACKLOG 220's defect 2, the owner: "a for defect 2"; its wording corrected 2026-11-10 after a
  sweep of the documents against the code): the event store's state for its file queue is held in a `QueueConfined`
  value, which checks its queue in Debug builds, and new state of that kind goes there; the camera controller's is left
  as it is for now (BACKLOG 222) (the last section).

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

## Amendment (2026-11-09, 1.12): the store's state for its queue is held in a checked holder

Decision 2 lists the promises a `nonisolated(unsafe)` marking may rest on. It never named one the app also relies on:
"used only on one dispatch queue". The camera controller's session state has rested on that since this record's own
work (the comment at the head of its class says so), and the event store later gained five fields on it, for its file
queue (`persistFailedOnQueue`, `mediaOwedDeletion`, `limitRemovalsOnDisk`, `limitRemovalsKeyRead`, `reportsOwedOnDisk`),
stated in their comments and checked by nothing. Every use of the five was on the queue; a new use from another thread
would have compiled, and raced. An outside reading of 1.11's public source raised the store's five (BACKLOG item 220's
defect 2).

Three ways went to the owner, ruled 2026-11-09 ("a for defect 2"):

- **(a) A small checked holder (taken).** `QueueConfined` (`Malinois/Services/EventStore.swift`): the value has one way
  in (`get`, `set`, `update`), and in Debug builds, which the tests run, each use checks that it is on the queue of the
  name given. A use from anywhere else is reported, to a test's hook or by stopping the app. A Release build makes no
  check and behaves as the fields did. The order and the timing of the store's writes do not change.
- (b) A Swift actor tied to the file queue: the strongest checking by the compiler, with many more lines of the store's
  write path changed, and no practical protection over (a).
- (c) A check at each use, with the fields as they were: the smallest change, and the compiler still stops no new wrong
  use.

**The rule from here:** new state that only a dispatch queue may touch goes in a `QueueConfined` value, not in a field
marked `nonisolated(unsafe)`. In the store no field keeps that marking but its test seams (fields whose names end in
`ForTesting`, which only tests set), and `EventTests.testTheStoreKeepsNoUnsafeFieldForItsQueue` reads the store's source
for any other.

**What is left as it was: the camera controller** (the owner, 2026-11-10: "as you recommend", a later release; BACKLOG
item 222). `CameraController` has 45 fields marked `nonisolated(unsafe)`: 32 kept to its session queue and 4 to its
Vision queue by comment, 6 under `ownershipLock`, 1 under `clipAudioLock`, and 2 handlers the engine sets. They are of
the kind the store's five were, in code only a phone can run (the Simulator has no camera), so they move into holders
in a release of their own, after a short design and with a device run. Two of them are read by the main actor while
the session queue may still be writing them (`visionTapActive` and `micUnavailableForClips`, after a warm-up's
deadline), which that work also settles. The other fields so marked in the app rest on promises decision 2 lists, or
are kept to the main actor (`DeviceInfo.name`, `AppSettings.loadWasReset`).

**What it does not give:** the compiler still does not prove the confinement, since the holder itself is
`@unchecked Sendable`; the check is made as the app runs, in Debug builds only; and the queue is known by its name, so
two queues of one name are not told apart.
