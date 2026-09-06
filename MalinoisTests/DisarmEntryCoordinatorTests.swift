//
//  DisarmEntryCoordinatorTests.swift
//  MalinoisTests
//
//  The disarm-entry state machine on its own (1.3 step 7): a fake host records the side
//  effects (proximity pause/resume, repaint) and answers whether the session is still
//  active. The engine's end-to-end behaviour is pinned by the characterization tests; this
//  file pins the machine's own logic — the two windows, the timeout/ceiling, attribution.
//

import XCTest
@testable import Malinois

@MainActor
final class FakeDisarmEntryHost: DisarmEntryHost {
    var isSessionActive = true
    private(set) var proximityPauses = 0
    private(set) var proximityResumes = 0
    private(set) var repaints = 0
    func pauseProximityForEntry() { proximityPauses += 1 }
    func resumeProximityAfterEntry() { proximityResumes += 1 }
    func disarmPresentationChanged() { repaints += 1 }
}

@MainActor
final class DisarmEntryCoordinatorTests: XCTestCase {

    private static let fastTiming: EngineTiming = {
        var t = EngineTiming.production
        t.disarmEntryTimeout = 0.2
        t.disarmEntryCeiling = 0.6
        t.disarmCandidateWindow = 0.3
        t.disarmActivityGrace = 0.2
        return t
    }()

    private struct Rig {
        let coordinator: DisarmEntryCoordinator
        let host: FakeDisarmEntryHost
        var activeChanges: [Bool] { changes.value }
        let changes: Box
    }
    /// Captures the mirror callbacks the engine drives its @Published property from.
    private final class Box { var value: [Bool] = [] }

    private func makeRig(timing: EngineTiming = DisarmEntryCoordinatorTests.fastTiming) -> Rig {
        let host = FakeDisarmEntryHost()
        let coordinator = DisarmEntryCoordinator(timing: timing)
        coordinator.host = host
        let box = Box()
        coordinator.onActiveChange = { box.value.append($0) }
        return Rig(coordinator: coordinator, host: host, changes: box)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - The pure grace rule

    func testEntryIsActiveRule() {
        let now = Date()
        XCTAssertFalse(DisarmEntryCoordinator.entryIsActive(lastKeypress: nil, now: now, grace: 20))
        XCTAssertTrue(DisarmEntryCoordinator.entryIsActive(lastKeypress: now, now: now, grace: 20))
        XCTAssertTrue(DisarmEntryCoordinator.entryIsActive(lastKeypress: now.addingTimeInterval(-19), now: now, grace: 20))
        XCTAssertFalse(DisarmEntryCoordinator.entryIsActive(lastKeypress: now.addingTimeInterval(-21), now: now, grace: 20))
    }

    // MARK: - Opening the pad

    /// Opening the pad flips the mirror, pauses proximity, repaints, and — because the open
    /// itself seeds the activity clock — presentation is suppressed straight away (A-02's
    /// bounded re-widening: one grace window for reaching the first key).
    func testBeginOpensThePadSeedsTheGraceAndPausesProximity() {
        let rig = makeRig()
        XCTAssertFalse(rig.coordinator.isActive)
        XCTAssertFalse(rig.coordinator.presentationSuppressed, "closed pad never suppresses")
        rig.coordinator.begin()
        XCTAssertTrue(rig.coordinator.isActive)
        XCTAssertEqual(rig.activeChanges, [true], "the mirror was told once")
        XCTAssertEqual(rig.host.proximityPauses, 1)
        XCTAssertGreaterThanOrEqual(rig.host.repaints, 1)
        XCTAssertTrue(rig.coordinator.presentationSuppressed, "the open seeds the grace")
    }

    // MARK: - The two windows are separate (F1 / A-02)

    /// The candidate (attribution) window opens on the hold press-down, before the pad — so a
    /// capture during the hold is attributed — while presentation is NOT suppressed by a mere
    /// candidate: a bare touch must not buy silence.
    func testTheCandidateWindowAttributesButDoesNotSuppress() {
        let rig = makeRig()
        rig.coordinator.noteCandidate()
        XCTAssertTrue(rig.coordinator.inFlow, "attribution window open on the hold")
        XCTAssertFalse(rig.coordinator.presentationSuppressed, "a bare touch buys no silence (F1)")
        let id = UUID()
        rig.coordinator.noteCandidateEvent(id)
        // A correct PIN now attributes that event.
        XCTAssertEqual(rig.coordinator.takeOwnerEventsOnDisarm(), [id])
    }

    /// A capture with no hold and no pad is neither attributed nor suppressed.
    func testNoFlowMeansNoAttribution() {
        let rig = makeRig()
        rig.coordinator.noteCandidateEvent(UUID())
        XCTAssertTrue(rig.coordinator.takeOwnerEventsOnDisarm().isEmpty, "nothing to attribute outside the flow")
    }

    /// Presentation suppression needs a RECENT keypress on an OPEN pad, and lapses after the
    /// grace even while the pad stays open (the idle-pad-alerts-normally rule, A-02).
    func testSuppressionNeedsARecentKeypressAndLapses() {
        var t = Self.fastTiming
        t.disarmActivityGrace = 0.15
        t.disarmEntryTimeout = 5   // keep the pad open past the grace for this test
        t.disarmEntryCeiling = 10
        let rig = makeRig(timing: t)
        rig.coordinator.begin()
        rig.coordinator.noteActivity()
        XCTAssertTrue(rig.coordinator.presentationSuppressed)
        XCTAssertTrue(pump(until: { !rig.coordinator.presentationSuppressed }, timeout: 1),
                      "suppression lapses after the grace even on an open pad")
        XCTAssertTrue(rig.coordinator.isActive, "the pad is still open")
    }

    // MARK: - Timeout and ceiling

    /// With no activity the pad times out on its own, flips the mirror back, and resumes
    /// proximity — but only while the session is still active.
    func testThePadTimesOutOnInactivity() {
        let rig = makeRig()
        rig.coordinator.begin()
        XCTAssertTrue(pump(until: { !rig.coordinator.isActive }, timeout: 1), "the inactivity timeout closes it")
        XCTAssertEqual(rig.activeChanges, [true, false])
        XCTAssertEqual(rig.host.proximityResumes, 1, "proximity restored on close")
    }

    /// Activity keeps the pad open past a single timeout — but never past the absolute ceiling.
    func testActivityHoldsThePadOpenButNotPastTheCeiling() {
        let rig = makeRig()
        rig.coordinator.begin()
        let start = Date()
        // Tap every 0.1 s (inside the 0.2 s timeout) until the pad closes.
        while rig.coordinator.isActive && Date().timeIntervalSince(start) < 1.5 {
            rig.coordinator.noteActivity()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let held = Date().timeIntervalSince(start)
        XCTAssertFalse(rig.coordinator.isActive, "the ceiling closed it despite continued activity")
        XCTAssertGreaterThan(held, 0.6, "it held past a single timeout")
        XCTAssertLessThan(held, 1.2, "but the ceiling (0.6 s) capped it, plus one grace")
    }

    /// A timeout that fires after the session has ended (a disarm elsewhere) closes the state
    /// but does not resume proximity — nothing to resume into.
    func testATimeoutAfterTheSessionEndedDoesNotResumeProximity() {
        let rig = makeRig()
        rig.coordinator.begin()
        rig.host.isSessionActive = false
        XCTAssertTrue(pump(until: { !rig.coordinator.isActive }, timeout: 1))
        XCTAssertEqual(rig.host.proximityResumes, 0, "no resume once the session is over")
    }

    // MARK: - Teardown paths

    /// Cancelling the hold before the pad opens clears attribution; once the pad is open it is
    /// a no-op (only a dismiss or a disarm closes it).
    func testCancelCandidateOnlyBeforeThePadOpens() {
        let rig = makeRig()
        rig.coordinator.noteCandidate()
        let id = UUID()
        rig.coordinator.noteCandidateEvent(id)
        rig.coordinator.cancelCandidate()
        XCTAssertTrue(rig.coordinator.takeOwnerEventsOnDisarm().isEmpty, "the tap's events stand as evidence")

        rig.coordinator.begin()
        rig.coordinator.noteCandidateEvent(id)
        rig.coordinator.cancelCandidate()   // no-op: pad is open
        XCTAssertEqual(rig.coordinator.takeOwnerEventsOnDisarm(), [id], "cancel does not strip an open pad's events")
    }

    /// A dismiss (end) drops the attribution set — an abandoned pad's captures stand as
    /// evidence — while a disarm hands them back.
    func testEndDropsAttributionAndDisarmKeepsIt() {
        let ended = makeRig()
        ended.coordinator.begin()
        ended.coordinator.noteCandidateEvent(UUID())
        ended.coordinator.end()
        XCTAssertFalse(ended.coordinator.isActive)
        XCTAssertTrue(ended.coordinator.takeOwnerEventsOnDisarm().isEmpty, "an abandoned pad attributes nothing")

        let disarmed = makeRig()
        disarmed.coordinator.begin()
        let id = UUID()
        disarmed.coordinator.noteCandidateEvent(id)
        XCTAssertEqual(disarmed.coordinator.takeOwnerEventsOnDisarm(), [id])
        XCTAssertFalse(disarmed.coordinator.isActive, "disarm closes the pad")
        XCTAssertTrue(disarmed.coordinator.takeOwnerEventsOnDisarm().isEmpty, "the set is consumed once")
    }
}
