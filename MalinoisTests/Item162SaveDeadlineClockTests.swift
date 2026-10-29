//
//  Item162SaveDeadlineClockTests.swift
//  MalinoisTests
//
//  BACKLOG 162's A11 (Codex's codex-3 on 1.8.1, a 1.8.1 regression; 1.8.2's step 13). A save's stall deadline was
//  timed with `Date()`, and since 1.8.1 every save waits through it, so a clock change during a stalled save moved it:
//  set back an hour, about an hour was left and slept, holding the event's chain and a sweep worker; set forward, the
//  save was cut short at once. It is now timed on `ContinuousClock`, which no setting moves. The cases are Codex's
//  four (its probe B), on a continuous clock the test moves, through the real `StallClock` and the real
//  `awaitWithStallDeadline`. The test's clock jumps on while the calendar clock barely moves: a deadline on the
//  calendar clock reads that as a clock set back by the jump, one on the continuous clock reads it right, whichever
//  way the calendar clock went. Red at its commit: the deadline still read the calendar clock.
//

import XCTest
@testable import Malinois

@MainActor
final class Item162SaveDeadlineClockTests: XCTestCase {

    /// A continuous clock the test moves.
    private final class SteadyClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        func now() -> ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ seconds: Double) { lock.withLock { instant = instant.advanced(by: .seconds(seconds)) } }
    }

    private struct Stalled: Error {}

    /// The real `awaitWithStallDeadline` on `clock`, with `operation` standing for the save (it may move the clock,
    /// report progress and finish): whether the deadline cut it off, and after how many real seconds.
    private func race(stall: TimeInterval, cap: TimeInterval, on clock: SteadyClock,
                      operation: (_ finish: @escaping @Sendable (Result<Void, Error>) -> Void,
                                  _ progressed: @escaping @Sendable () -> Void) -> Void) async -> (cutOff: Bool, after: TimeInterval) {
        let began = ContinuousClock.now
        var cutOff = false
        do {
            try await CloudExfiltrator.awaitWithStallDeadline(stall: stall, cap: cap, now: { clock.now() },
                                                              onDeadline: {}, timeoutError: Stalled(), start: operation)
        } catch {
            cutOff = error is Stalled
        }
        return (cutOff, (ContinuousClock.now - began) / .seconds(1))
    }

    // MARK: - Codex's four cases

    /// Codex's first row (a clock set back an hour, 21 s into a save with no progress; stall 20 s, cap 600 s): the
    /// deadline is 1 s past, whatever the calendar clock did, and the stalled save is cut off at once.
    func testAStallIsTimedOnTheContinuousClock() async {
        let clock = SteadyClock()
        let deadline = CloudExfiltrator.StallClock(now: { clock.now() })
        clock.advance(21)
        XCTAssertEqual(deadline.remaining(stall: 20, cap: 600), -1, accuracy: 0.001, "1 s past the stall")
        let save = await race(stall: 20, cap: 600, on: clock) { _, _ in clock.advance(21) }
        XCTAssertTrue(save.cutOff, "the stalled save is cut off")
        XCTAssertLessThan(save.after, 1, "at once, not when the calendar clock catches up")
    }

    /// Codex's second row: the same for a save without an asset, whose cap is its stall (the fixed 20 s).
    func testTheFixedDeadlineIsTimedOnTheContinuousClock() async {
        let clock = SteadyClock()
        let deadline = CloudExfiltrator.StallClock(now: { clock.now() })
        clock.advance(21)
        XCTAssertEqual(deadline.remaining(stall: 20, cap: 20), -1, accuracy: 0.001, "1 s past the fixed deadline")
        let save = await race(stall: 20, cap: 20, on: clock) { _, _ in clock.advance(21) }
        XCTAssertTrue(save.cutOff, "the stalled save is cut off")
        XCTAssertLessThan(save.after, 1, "at once")
    }

    /// Codex's third row (a clock set forward an hour, 20 s into a save that reported progress at 19 s; stall 20 s,
    /// cap 600 s): 19 s are left, and the save is not cut short; it finishes.
    func testProgressRestartsTheStallOnTheContinuousClock() async {
        let clock = SteadyClock()
        let deadline = CloudExfiltrator.StallClock(now: { clock.now() })
        clock.advance(19)
        deadline.noteProgress()
        clock.advance(1)
        XCTAssertEqual(deadline.remaining(stall: 20, cap: 600), 19, accuracy: 0.001, "the stall restarted at 19 s")
        let save = await race(stall: 20, cap: 600, on: clock) { finish, progressed in
            clock.advance(19)
            progressed()
            clock.advance(1)
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                finish(.success(()))
            }
        }
        XCTAssertFalse(save.cutOff, "the save finished: nothing cut it short")
        XCTAssertLessThan(save.after, 1)
    }

    /// Codex's fourth row (any clock change; 601 s into a save that reported progress at 600 s; stall 20 s, cap
    /// 600 s): progress restarts the stall, never the cap, so the save is cut off at the cap, at once.
    func testTheCapIsTimedOnTheContinuousClock() async {
        let clock = SteadyClock()
        let deadline = CloudExfiltrator.StallClock(now: { clock.now() })
        clock.advance(600)
        deadline.noteProgress()
        clock.advance(1)
        XCTAssertEqual(deadline.remaining(stall: 20, cap: 600), -1, accuracy: 0.001, "1 s past the cap")
        let save = await race(stall: 20, cap: 600, on: clock) { _, progressed in
            clock.advance(600)
            progressed()
            clock.advance(1)
        }
        XCTAssertTrue(save.cutOff, "cut off at the cap")
        XCTAssertLessThan(save.after, 1, "at once")
    }
}
