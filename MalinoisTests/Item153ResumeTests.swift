//
//  Item153ResumeTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-06 (1.8.2's step 19). A live watch sent to the background (under Guided Access, most often the
//  side button's lock) is recorded as interrupted, but its return was not: nothing in the log said how long nothing
//  was watched. Now a "resumed" status entry carries the lapse's length, measured on the clock no setting moves, as a
//  clock change carries its jump. The Motion tripwire's watchdog read the lapse as a stalled stream at its first tick
//  back, a "few seconds" record for a lock of any length; its stall clock now restarts on resume. A phone moved during
//  the lapse trips on the first sample back, as before: the pose is compared with the one learned at calibration,
//  which only a trip moves; one put back in the same pose cannot, which the resumed record covers. And under Guided
//  Access the lock button is the usual way out, not the only one, so the lapse's record no longer asserts a lock.
//  The Simulator has no motion sensor: the monitor is driven through Debug-only seams. Written before the change, red
//  at that commit.
//

import XCTest
import UIKit
@testable import Malinois

@MainActor
final class Item153ResumeTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    /// The lapse's clock, which the test moves.
    @MainActor
    private final class LapseClock {
        private(set) var now = ContinuousClock.now
        func advance(_ seconds: Double) { now = now.advanced(by: .seconds(seconds)) }
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Resume")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeRig(grace: Int = 0) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = grace
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        return Rig(engine: engine, store: store)
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    private func resumedKinds(_ rig: Rig) -> [String] {
        rig.store.events.compactMap(\.stateChange).filter { $0.hasPrefix("resumed.") }
    }

    private func statusEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    // MARK: - The record

    /// A live watch sent to the background and back writes "resumed" with how long nothing was watched, on the clock no
    /// setting moves: here 4 min 12 s.
    func testALiveWatchBackOnScreenRecordsHowLongNothingWasWatched() {
        let rig = makeRig()
        arm(rig)
        let clock = LapseClock()
        rig.engine.lapseClockForTesting = { clock.now }
        rig.engine.handleEnteredBackground()
        clock.advance(252)
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(resumedKinds(rig), ["resumed.252"])
        rig.engine.disarm()
    }

    /// A countdown sent to the background was no live watch: its return writes nothing of the kind.
    func testACountdownSentToTheBackgroundRecordsNoResume() {
        let rig = makeRig(grace: 30)
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming, "the countdown runs")
        rig.engine.handleEnteredBackground()
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(resumedKinds(rig), [])
        rig.engine.cancelArming()
    }

    /// The record reads as a plain sentence in the log, in seconds, minutes and seconds, or hours and minutes.
    func testTheRecordReadsAsAPlainSentence() {
        XCTAssertEqual(statusEvent(Event.resumedKind(seconds: 45)).sensorSummary,
                       "Monitoring resumed after 45 s not watched")
        XCTAssertEqual(statusEvent(Event.resumedKind(seconds: 252)).sensorSummary,
                       "Monitoring resumed after 4 min 12 s not watched")
        XCTAssertEqual(statusEvent(Event.resumedKind(seconds: 8_040)).sensorSummary,
                       "Monitoring resumed after 2 h 14 min not watched")
    }

    /// Only a well-formed kind is a resume; less than a second reads as one.
    func testOnlyAWellFormedKindIsAResume() {
        XCTAssertEqual(Event.resumedSeconds(kind: "resumed.252"), 252)
        XCTAssertNil(Event.resumedSeconds(kind: "resumed.0"))
        XCTAssertNil(Event.resumedSeconds(kind: "resumed.-5"))
        XCTAssertNil(Event.resumedSeconds(kind: "resumed.x"))
        XCTAssertNil(Event.resumedSeconds(kind: "resumed.\(Int.max)"), "beyond a century: a damaged record")
        XCTAssertNil(Event.resumedSeconds(kind: "armed"))
        XCTAssertEqual(Event.resumedKind(seconds: 0), "resumed.1")
    }

    /// The record has its own icon in the log, one iOS has.
    func testTheRecordHasItsOwnIconInTheLog() {
        let icon = EventRow.placeholderIcon(for: Event.resumedKind(seconds: 252))
        XCTAssertEqual(icon, "eye")
        XCTAssertNotNil(UIImage(systemName: icon), "an SF Symbol this iOS has")
    }

    /// The owner's other devices read the record back from iCloud; it raises no alert there or on the watch.
    func testTheOwnersOtherDevicesReadTheRecordBackWithNoAlert() {
        let kind = Event.resumedKind(seconds: 252)
        let record = CloudExfiltrator.makeStateRecord(statusEvent(kind), kind: kind, deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind)
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: kind), "no disarm alert through iCloud")
        XCTAssertTrue(WatchAlertRelay.alerts(for: [statusEvent(kind)], alertsOn: true, proActive: true).isEmpty,
                      "nothing relayed to the watch")
    }

    /// Under Guided Access the lock button is the usual way out, not the only one (a call or Siri can interrupt, as
    /// SECURITY.md says), so the lapse's record no longer asserts a lock.
    func testALapseUnderGuidedAccessDoesNotAssertALock() {
        let lapse = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          interrupted: true, interruptionCause: InterruptionCause.locked.rawValue)
        XCTAssertEqual(lapse.sensorSummary,
                       "Monitoring interrupted: the device was locked, or Malinois otherwise left the screen, while armed")
    }

    // MARK: - The Motion tripwire

    /// Back on screen, the watchdog's first tick does not take the lapse for a stalled stream.
    func testALapseIsNotReportedAsAStalledTripwire() {
        let motion = MotionMonitor()
        var stalls = 0
        motion.onStall = { _ in stalls += 1 }
        let start = Date().addingTimeInterval(-60)
        motion.startWatchingForTesting(at: start, restingGravity: (0, 0, -1))
        motion.sampleForTesting(gravity: (0, 0, -1), at: start.addingTimeInterval(1))   // then the phone locks
        motion.resumeAfterSuspension()
        motion.checkForStallForTesting(now: Date().addingTimeInterval(0.1))   // the watchdog's first tick back
        XCTAssertEqual(stalls, 0, "the lapse is not a stall")
        motion.stop()
    }

    /// A phone moved while nobody could watch trips on the first sample back (10 degrees, set down still, past
    /// Medium's 3); one put back in the same pose cannot, which the resumed record covers.
    func testAPhoneMovedDuringTheLapseTripsOnTheFirstSampleBack() {
        let motion = MotionMonitor()
        motion.sensitivity = .medium
        var trips = 0
        motion.onTrip = { _ in trips += 1 }
        motion.startWatchingForTesting(at: Date().addingTimeInterval(-60), restingGravity: (0, 0, -1))
        motion.resumeAfterSuspension()
        motion.sampleForTesting(gravity: (0, 0, -1), at: Date())
        XCTAssertEqual(trips, 0, "the same pose: nothing to see")
        let angle = 10 * Double.pi / 180
        motion.sampleForTesting(gravity: (sin(angle), 0, -cos(angle)), at: Date())
        XCTAssertEqual(trips, 1, "moved: it trips")
        motion.stop()
    }
}
