//
//  Item129ReviewTests.swift
//  MalinoisTests
//
//  Item 129: Codex's full review of 1.7 (70) as shipped. 1.7.1 takes its F1 and F2 (the owner, 2026-10-17: "Do F1
//  and F2 as a separate 1.7.1 first"); F3 to F5 and the test fixes go to 1.8. Rewritten from Codex's probes in the
//  review folder's `_REVIEW_NOTES_codex/probes/`.
//

import XCTest
@testable import Malinois

@MainActor
final class Item129ReviewTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
    }

    private static let armedMarkerKey = "com.malinois.armedSession.brightness"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem129")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - F1: an append after a torn journal line

    /// A journal whose last line an earlier append left torn (a power cut or a forced restart inside the write, or a
    /// partial write on a full disk), and a log that never saw the event that line was for. The next event's line
    /// used to be written straight after the fragment, so neither decoded: if the log write that followed was lost
    /// too, to a second interruption a fraction of a second later, the event was gone, and the journal's own
    /// success left no warning. Every append now starts on a line of its own. Read as a relaunch would: the log as it
    /// was before the add, with the journal as the add left it.
    func testAnEventAddedAfterATornJournalLineSurvivesALostLogWrite() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: root.appendingPathComponent("events.json"))
        let torn = Data("{\"id\":\"an append cut short".utf8)
        try torn.write(to: root.appendingPathComponent("events.journal"))
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        let journal = try journalAfterAdding(event)
        XCTAssertEqual(journal.prefix(torn.count), torn, "the fragment is left as it was")
        let recovered = try relaunch(log: Data("[]".utf8), journal: journal)
        XCTAssertEqual(recovered.map(\.id), [event.id], "the event the journal saved comes back")
    }

    /// The same with a last line that is whole but for its newline (a write cut at its last byte), for an event the
    /// log already holds, so the launch finds nothing to recover and leaves the file as it is. The two lines used to
    /// run together, and neither decoded.
    func testAnEventAddedAfterALineMissingOnlyItsNewlineSurvivesALostLogWrite() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let earlier = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.power])
        let log = try JSONEncoder().encode([earlier])
        try log.write(to: root.appendingPathComponent("events.json"))
        try XCTUnwrap(EventStore.journalLine(for: earlier)).dropLast().write(to: root.appendingPathComponent("events.journal"))
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        let journal = try journalAfterAdding(event)
        let recovered = try relaunch(log: log, journal: journal)
        XCTAssertEqual(Set(recovered.map(\.id)), [earlier.id, event.id], "the log's event and the journal's both come back")
    }

    /// The guard: appends to a healthy journal stay one line each, with no empty line before or between them.
    func testAppendsToAHealthyJournalStayOneLineEach() throws {
        let store = EventStore()
        defer { store.drainIOForTesting() }
        let first = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        let second = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        store.add(first)
        store.add(second)
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let journal = try Data(contentsOf: root.appendingPathComponent("events.journal"))
        XCTAssertEqual(journal.split(separator: 0x0A, omittingEmptySubsequences: false).count, 3,
                       "two lines, each ending in its newline, and nothing else")
        XCTAssertEqual(EventStore.journaledEvents(in: journal).map(\.id), [first.id, second.id])
    }

    /// Adds the event to a store launched from the test's folder and returns the journal as the add left it, before
    /// any log write or checkpoint that follows could touch it.
    private func journalAfterAdding(_ event: Event) throws -> Data {
        let store = EventStore()
        defer { store.drainIOForTesting() }
        store.add(event)
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        return try Data(contentsOf: root.appendingPathComponent("events.journal"))
    }

    /// A relaunch from a folder of its own holding this log and this journal; the events it comes up with.
    private func relaunch(log: Data, journal: Data) throws -> [Event] {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let image = root.appendingPathComponent("after-a-crash", isDirectory: true)
        try FileManager.default.createDirectory(at: image, withIntermediateDirectories: true)
        try log.write(to: image.appendingPathComponent("events.json"))
        try journal.write(to: image.appendingPathComponent("events.journal"))
        EventStore.rootOverrideForTesting = image
        defer { EventStore.rootOverrideForTesting = root }
        let relaunched = EventStore()
        defer { relaunched.drainIOForTesting() }
        return relaunched.events
    }

    // MARK: - F2: a calibration tick queued before a disarm

    /// The calibration timer's tick hands its work to the main actor, and a disarm can come in between: the PIN that
    /// stops a crash-recovery re-arm, entered as calibration ends. The tick used to finish calibration after the
    /// disarm: the sensors and the heartbeat started, an "armed" record went into the log, the camera warmed, and the
    /// armed marker the disarm had removed was planted again, so the next launch would have recorded an interruption
    /// and re-armed by itself. Now a tick queued before a disarm does nothing. Driven through the engine's real timer,
    /// read by reflection; the disarm runs before the tick's queued work gets a turn.
    func testATickQueuedBeforeADisarmStartsNoWatch() throws {
        let rig = calibratingRig()
        let timer = try calibrationTimer(of: rig.engine)
        let recordsBefore = Set(rig.store.events.map(\.id))
        Thread.sleep(forTimeInterval: 0.35)   // calibration's time runs out while the main actor is held
        timer.fire()          // the real tick: its work is queued for the main actor
        rig.engine.disarm()   // before that work gets a turn
        XCTAssertFalse(timer.isValid, "disarm invalidates the actual calibration timer synchronously")
        let warmUpsAtDisarm = rig.camera.warmUps.count
        pump(until: { false }, timeout: 0.5)
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertNil(rig.engine.armedSince, "no watch started after the disarm")
        XCTAssertFalse(rig.engine.showingCalibrationReview)
        XCTAssertFalse(rig.store.events.contains { !recordsBefore.contains($0.id) && $0.stateChange == "armed" },
                       "no armed record after the disarm")
        XCTAssertEqual(rig.camera.warmUps.count, warmUpsAtDisarm, "no camera warm-up after the disarm")
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey),
                     "no armed marker, which would make the next launch re-arm by itself")
    }

    /// The guard, and the second half of the fix: a calibration finishes its watch once. Two ticks queued past the
    /// end, with the main actor held across both, used to finish it twice, the second warming the camera again.
    func testACalibrationFinishesItsWatchOnce() throws {
        let rig = calibratingRig()
        let timer = try calibrationTimer(of: rig.engine)
        Thread.sleep(forTimeInterval: 0.35)
        let warmUpsBefore = rig.camera.warmUps.count
        timer.fire()
        timer.fire()
        XCTAssertTrue(pump(until: { rig.engine.showingCalibrationReview }, timeout: 2), "calibration finished")
        pump(until: { false }, timeout: 0.5)
        XCTAssertEqual(rig.engine.state, .calibrating, "in the calibration review")
        XCTAssertNotNil(rig.engine.armedSince, "the watch started")
        XCTAssertEqual(rig.store.events.filter { $0.stateChange == "armed" }.count, 1)
        XCTAssertEqual(rig.camera.warmUps.count - warmUpsBefore, 1, "the camera warmed for the watch once")
        rig.engine.disarm()
    }

    /// An engine in calibration, with a camera kept ready (so going live warms it) and a review long enough not to
    /// end during the test. The pre-arm warm-up has landed.
    private func calibratingRig() -> Rig {
        var timing = EngineCharacterizationTests.fastTiming
        timing.calibrationDuration = 0.3
        timing.calibrationReview = 60
        let rig = makeRig(timing: timing) {
            $0.enabledSensors = [.touch, .camera]
            $0.cameraReadiness = .instant
            $0.responseMode = .stealth
            $0.jammingResponse = false
        }
        rig.engine.beginArming()
        XCTAssertTrue(pump(until: { !rig.camera.warmUps.isEmpty }, timeout: 2), "the pre-arm warm-up landed")
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .calibrating }, timeout: 3), "calibrating")
        return rig
    }

    /// The arming owner's actual calibration timer, read by reflection without a proxy or shadow timer.
    private func calibrationTimer(of engine: MonitoringEngine) throws -> Timer {
        let value = try XCTUnwrap(Mirror(reflecting: engine.armingFlow).children.first { $0.label == "calibrationTimer" }?.value,
                                  "the arming flow owns the calibration timer")
        if let timer = value as? Timer { return timer }
        return try XCTUnwrap(Mirror(reflecting: value).children.first?.value as? Timer, "the calibration is running")
    }

    private func makeRig(timing: EngineTiming, _ configure: (AppSettings) -> Void) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        return Rig(engine: engine, camera: camera, store: store, settings: settings)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
