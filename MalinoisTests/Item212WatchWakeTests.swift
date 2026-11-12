//
//  Item212WatchWakeTests.swift
//  MalinoisTests
//
//  BACKLOG 212 (the owner, 2026-11-06: "211 and 212 please"): watchOS ended the watch app of 1.8.2 (79) on
//  2026-10-29 when a background wake for the iPhone link outlasted its 15 seconds of wall time ("WatchConnectivity
//  watchdog transgression"), the app idle, the wake still held. 1.6's fix (`49915bb`) gives a wake back when watchOS's
//  expiration handler says its time is up, and that did not come first. The watch app now holds each wake through
//  `WatchLinkWakes`, which gives it back at a deadline of the app's own, well inside the 15 seconds, if nothing has
//  by then. The tests fire the deadline themselves. Written before the fix, red at that commit (the type there has no
//  deadline yet, and the watch app does not use it).
//

import XCTest

@MainActor
final class Item212WatchWakeTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// A wake nothing gives back, as on 1.8.2 (79), is given back at the app's own deadline.
    func testAWakeNothingGivesBackIsGivenBackAtTheDeadline() {
        let rig = Rig(), wake = Wake()
        rig.wakes.hold(wake)
        XCTAssertEqual(rig.ended, [], "held until something gives it back")
        rig.fireAll()
        XCTAssertEqual(rig.ended, [ObjectIdentifier(wake)], "given back at the deadline")
        XCTAssertEqual(rig.wakes.count, 0)
    }

    /// The deadline leaves at least five of watchOS's 15 seconds for the wake's start and its giving back.
    func testTheDeadlineIsWellInsideWatchOSsFifteenSeconds() throws {
        let rig = Rig()
        rig.wakes.hold(Wake())
        let delay = try XCTUnwrap(rig.scheduled.first?.delay, "a deadline of the app's own")
        XCTAssertGreaterThan(delay, 0)
        XCTAssertLessThanOrEqual(delay, 10)
    }

    /// Each wake has its own deadline: one handed over later is not given back at an earlier wake's.
    func testEachWakeHasItsOwnDeadline() throws {
        let rig = Rig(), first = Wake(), second = Wake()
        rig.wakes.hold(first)
        rig.wakes.hold(second)
        XCTAssertEqual(rig.scheduled.count, 2, "one deadline each")
        try XCTUnwrap(rig.scheduled.first).action()
        XCTAssertEqual(rig.ended, [ObjectIdentifier(first)], "the first wake's deadline gives back the first only")
        XCTAssertEqual(rig.wakes.count, 1)
    }

    /// A guard, green before the fix and after: given back by the rule (nothing left to deliver), a wake is not given
    /// back again at its deadline.
    func testAWakeGivenBackByTheRuleIsNotGivenBackAgainAtItsDeadline() {
        let rig = Rig(), wake = Wake()
        rig.wakes.hold(wake)
        rig.wakes.giveBackAll()
        rig.fireAll()
        XCTAssertEqual(rig.ended, [ObjectIdentifier(wake)], "once")
    }

    /// A guard, green before the fix and after: watchOS's expiration handler and the rule reaching the same wake give
    /// it back once, and the rule gives back every wake held.
    func testEveryWakeIsGivenBackOnce() {
        let rig = Rig(), first = Wake(), second = Wake()
        rig.wakes.hold(first)
        rig.wakes.hold(second)
        rig.wakes.giveBack(first)   // its expiration handler
        rig.wakes.giveBack(first)
        XCTAssertEqual(rig.ended, [ObjectIdentifier(first)])
        rig.wakes.giveBackAll()     // the rule: nothing left to deliver
        rig.wakes.giveBackAll()
        XCTAssertEqual(rig.ended, [ObjectIdentifier(first), ObjectIdentifier(second)])
    }

    /// The watch app (its own target: read from the source tree, as built) holds each link wake through it, and keeps
    /// watchOS's expiration handler beside the deadline.
    func testTheWatchAppHoldsEachWakeThroughIt() throws {
        let delegate = try String(contentsOf: Self.root.appendingPathComponent("MalinoisWatch/WatchAppDelegate.swift"),
                                  encoding: .utf8)
        XCTAssertTrue(delegate.contains("WatchLinkWakes<WKWatchConnectivityRefreshBackgroundTask>("))
        XCTAssertTrue(delegate.contains("linkWakes.hold(linkTask)"))
        XCTAssertTrue(delegate.contains("linkWakes.giveBackAll()"), "the rule gives them back")
        XCTAssertTrue(delegate.contains("linkWakes.giveBack(linkTask)"), "the expiration handler, kept")
        XCTAssertFalse(delegate.contains("linkTasks"), "no wake held outside it")
    }

    // MARK: - Helpers

    /// A stand-in for watchOS's wake.
    private final class Wake {}

    /// The wakes, with what they gave back and the deadlines they set, which the tests fire themselves.
    @MainActor
    private final class Rig {
        var ended: [ObjectIdentifier] = []
        var scheduled: [(delay: TimeInterval, action: @MainActor @Sendable () -> Void)] = []
        private(set) lazy var wakes = WatchLinkWakes<Wake>(
            end: { [unowned self] wake in self.ended.append(ObjectIdentifier(wake)) },
            after: { [unowned self] delay, action in self.scheduled.append((delay, action)) })

        /// Runs every deadline set so far, as if its time had come.
        func fireAll() {
            let due = scheduled
            scheduled.removeAll()
            due.forEach { $0.action() }
        }
    }
}
