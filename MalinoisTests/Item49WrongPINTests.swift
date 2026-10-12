//
//  Item49WrongPINTests.swift
//  MalinoisTests
//
//  BACKLOG 49, first in the 1.4 order (owner, 2026-09-26): a wrong PIN on the armed screen's
//  disarm pad is itself evidence. Each attempt becomes a tamper record photographed from the
//  front as a still, or joins the capture already running; a correct PIN adds nothing (the
//  owner's ruling: the disarm is already on the record, and every new tamper record alerts the
//  other devices). Written before the feature — red at that commit — and each commit after it
//  turns its own tests green. The engine half drives the real engine against the fake camera,
//  like the characterization tests; the model half pins how the record reads and what reaches
//  another device.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item49WrongPINTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
    }

    /// The characterization timing, with the pad kept open and "typing" for longer than a
    /// capture takes, so the test decides when a pad session ends, not the compressed timeout.
    private static let padTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.disarmEntryTimeout = 5
        t.disarmEntryCeiling = 10
        t.disarmActivityGrace = 5
        return t
    }()

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem49")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// `timing` nil = the characterization timing (resolved here, on the main actor, rather than
    /// in a default argument, which Swift evaluates outside it).
    private func makeRig(timing: EngineTiming? = nil,
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        settings.captureMode = .photo
        settings.cameraPosition = .front
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera,
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing ?? EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, camera: camera, store: store)
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

    /// Arms through grace (0 s), calibration, and the calibration review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    /// The records carrying an attempt.
    private func attemptRecords(_ rig: Rig) -> [Event] {
        rig.store.events.filter { ($0.wrongPINCount ?? 0) > 0 }
    }

    // MARK: - The engine

    /// The attempt mints its own record while the camera is free: a Touch row carrying one
    /// attempt, photographed from the FRONT as a single STILL whatever the capture settings say
    /// (the typist faces the screen; a still lands while they are still there). The control
    /// trip after it shows those settings really would have filmed both lenses.
    func testAWrongPINWhileArmedMintsItsOwnRecordWithAFrontStill() {
        let rig = makeRig { $0.captureMode = .clip3; $0.cameraPosition = .both }
        rig.camera.supportsMultiCam = true
        arm(rig)

        rig.engine.noteWrongDisarmPIN()

        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && self.attemptRecords(rig).contains { $0.mediaFilename != nil }
        }, timeout: 5), "the attempt is recorded, photographed, and the watch re-arms")
        guard let record = attemptRecords(rig).first else { return XCTFail("no record for the attempt") }
        XCTAssertEqual(record.wrongPINCount, 1)
        XCTAssertEqual(record.triggeredSensors, [.touch], "the typing is the record's Touch")
        XCTAssertEqual(record.primaryCamera, "front")
        XCTAssertNil(record.secondaryMediaFilename, "one lens")
        XCTAssertEqual(rig.camera.stills.count, 1, "a still, not the configured clip")
        XCTAssertTrue(rig.camera.clips.isEmpty)
        XCTAssertEqual(rig.camera.bothStills, 0)
        XCTAssertEqual(rig.camera.bothClips, 0)
        XCTAssertEqual(rig.camera.warmUps.last?.camera, .front)

        rig.engine.handleTrip(.motion)   // the control: these settings film both lenses
        XCTAssertTrue(pump(until: { rig.camera.bothClips == 1 }, timeout: 3),
                      "an ordinary trip still follows the configured capture")
        rig.engine.disarm()
    }

    /// Attempts that land while a capture is running join THAT record, like any trip during a
    /// capture (34-review M1): no second record, no second capture, the count on the one record.
    func testWrongPINsDuringACaptureFoldIntoThatRecord() {
        let rig = makeRig()
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3))

        rig.engine.noteWrongDisarmPIN()
        rig.engine.noteWrongDisarmPIN()
        rig.camera.releaseStills()

        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        let records = rig.store.events.filter { !$0.isStateChange }
        XCTAssertEqual(records.count, 1, "the in-flight record takes the attempts")
        XCTAssertEqual(records.first?.wrongPINCount, 2)
        XCTAssertEqual(records.first?.triggeredSensors, [.motion, .touch])
        XCTAssertEqual(rig.camera.stills.count, 1, "and no second capture")
        rig.engine.disarm()
    }

    /// Attempts typed during a running capture stay on its record when the right PIN lands
    /// before the capture ends: a PIN-holder who fumbles and then gets in leaves the fumble on
    /// the record the capture was taking, not just the disarm. (The response still finishes
    /// after a disarm; here the stopped camera fails the shot, as it does on a device.)
    func testAttemptsDuringACaptureSurviveADisarmBeforeItEnds() {
        let rig = makeRig()
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3))

        rig.engine.noteWrongDisarmPIN()
        rig.engine.disarm()   // the right PIN, with the still still open
        rig.camera.stillError = CameraController.CameraError.captureFailed
        rig.camera.releaseStills()

        XCTAssertTrue(pump(until: {
            rig.store.events.contains { !$0.isStateChange && $0.captureFailure != nil }
        }, timeout: 3), "the in-flight record closes after the disarm")
        XCTAssertEqual(rig.store.events.first { !$0.isStateChange }?.wrongPINCount, 1,
                       "the attempt stays on the record it landed in")
        XCTAssertEqual(rig.engine.state, .disarmed)
    }

    /// An attempt during a flood is its own record. A motor against the table leg has pushed the
    /// motion tripwire past the flood bar, so its trips only add to one sustained record; the
    /// wrong PIN does not join that count. It mints a Touch record carrying the attempt, and the
    /// flood's record does not take it (the 1.4 review's test gap, item 89).
    func testAWrongPINDuringAFloodIsItsOwnRecord() {
        let rig = makeRig()
        arm(rig)
        for _ in 0..<(MonitoringEngine.floodTripThreshold + 4) {   // the characterization flood test's margin
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        }
        guard let flood = rig.store.events.first(where: { ($0.sustainedCount ?? 0) >= 2 }) else {
            return XCTFail("the motion trips should have coalesced into a sustained record")
        }

        rig.engine.noteWrongDisarmPIN()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && !self.attemptRecords(rig).isEmpty }, timeout: 5),
                      "the attempt is recorded and the watch re-arms")

        let attempts = attemptRecords(rig)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts.first?.wrongPINCount, 1)
        XCTAssertNotEqual(attempts.first?.id, flood.id, "not folded into the flood's record")
        XCTAssertNil(rig.store.events.first { $0.id == flood.id }?.wrongPINCount,
                     "the flood's record does not take the attempt")
        rig.engine.disarm()
    }

    /// Armed sessions only: with nothing armed an attempt records nothing and takes no photo
    /// (the Home gate and the other PIN pads stay lockout-only, and the engine refuses too).
    func testAWrongPINOutsideAnArmedSessionRecordsNothing() {
        let rig = makeRig()
        let before = rig.store.events.count

        rig.engine.noteWrongDisarmPIN()
        pump(until: { false }, timeout: 0.3)

        XCTAssertEqual(rig.store.events.count, before)
        XCTAssertTrue(rig.camera.stills.isEmpty)
        XCTAssertEqual(rig.engine.state, .disarmed)
    }

    /// The owner's own typo: an attempt followed by the right PIN in the same pad session is
    /// attributed to the owner like everything else captured while the pad was open (R-02) —
    /// flagged, never removed.
    func testTheOwnersTypoIsAttributedByTheRightPINInTheSamePadSession() {
        let rig = makeRig(timing: Self.padTiming)
        arm(rig)
        rig.engine.noteDisarmCandidate()
        rig.engine.beginDisarmEntry()
        rig.engine.noteDisarmActivity()

        rig.engine.noteWrongDisarmPIN()
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && self.attemptRecords(rig).contains { $0.mediaFilename != nil }
        }, timeout: 3), "the typo is recorded like any attempt")

        rig.engine.disarm()
        XCTAssertEqual(attemptRecords(rig).first?.ownerAttributed, true,
                       "the right PIN in the same pad session attributes it to the owner")
    }

    /// An attempt on a pad that is then abandoned stands as evidence, and a later disarm in
    /// another pad session does not reach back to it.
    func testAnAttemptOnAnAbandonedPadStandsAsEvidence() {
        let rig = makeRig(timing: Self.padTiming)
        arm(rig)
        rig.engine.noteDisarmCandidate()
        rig.engine.beginDisarmEntry()
        rig.engine.noteDisarmActivity()

        rig.engine.noteWrongDisarmPIN()
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && self.attemptRecords(rig).contains { $0.mediaFilename != nil }
        }, timeout: 3))
        rig.engine.endDisarmEntry()   // Cancel, or walked away
        XCTAssertEqual(rig.engine.state, .armed, "abandoning the pad never disarms")

        rig.engine.disarm()
        XCTAssertEqual(attemptRecords(rig).count, 1)
        XCTAssertNotEqual(attemptRecords(rig).first?.ownerAttributed, true, "no PIN in that session, no attribution")
    }

    /// With the camera tripwire off the attempt is still on the record, just without media —
    /// and without a failure reason, since nothing was asked of the camera.
    func testWithTheCameraOffAnAttemptIsRecordedWithoutMedia() {
        let rig = makeRig { $0.enabledSensors.remove(.camera) }
        arm(rig)

        rig.engine.noteWrongDisarmPIN()

        XCTAssertTrue(pump(until: { rig.engine.state == .armed && !self.attemptRecords(rig).isEmpty }, timeout: 3))
        let record = attemptRecords(rig).first
        XCTAssertEqual(record?.wrongPINCount, 1)
        XCTAssertNil(record?.mediaFilename)
        XCTAssertNil(record?.captureFailure)
        XCTAssertTrue(rig.camera.stills.isEmpty)
        rig.engine.disarm()
    }

    /// The on-screen alarm keeps today's rule (A-02): it does not start over the owner's typing.
    /// The attempt is recorded and pushed all the same — only the presentation waits.
    func testAnAttemptStartsNoAlarmWhileTheOwnerIsTyping() {
        let rig = makeRig(timing: Self.padTiming)
        arm(rig)
        rig.engine.beginDisarmEntry()
        rig.engine.noteDisarmActivity()

        rig.engine.noteWrongDisarmPIN()

        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed && self.attemptRecords(rig).contains { $0.mediaFilename != nil }
        }, timeout: 3), "the attempt is recorded")
        XCTAssertFalse(rig.engine.alertActive, "no fresh alarm over the owner's typing")
        rig.engine.disarm()
    }

    // MARK: - How the record reads

    /// The typing rides the record as Touch, but the record reads as the attempt it is; a
    /// record without the marker is unchanged.
    func testAWrongPINRecordReadsAsAWrongPINNotATouch() {
        let now = Date()
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.touch], wrongPINCount: 1).sensorSummary,
                       "Wrong PIN entered")
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.touch]).sensorSummary,
                       "Touch", "a plain touch is unchanged")
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.touch], wrongPINCount: 1).shareClause,
                       "Wrong PIN entered", "an attempt is not something that 'triggered'")
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.motion]).shareClause,
                       "Device motion triggered", "a tripwire still did")
    }

    /// Several attempts say how many; other tripwires on the same record come first, as they
    /// fired first; a coalesced flood keeps its count.
    func testSeveralAttemptsAndOtherTripsOnOneRecordAreAllNamed() {
        let now = Date()
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.touch], wrongPINCount: 3).sensorSummary,
                       "Wrong PIN entered 3 times")
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.motion, .touch],
                             wrongPINCount: 1).sensorSummary,
                       "Device motion, wrong PIN entered")
        XCTAssertEqual(Event(startDate: now, endDate: now, triggeredSensors: [.motion, .touch],
                             sustainedCount: 4, wrongPINCount: 2).sensorSummary,
                       "Device motion, wrong PIN entered 2 times, sustained ×4")
    }

    // MARK: - What reaches another device

    /// The count rides the cloud payload and comes back on a mirror, so another device reads
    /// the same record; a record without attempts carries no key (the fact stays as small as
    /// ever).
    func testTheAttemptCountRidesTheCloudPayloadAndComesBackOnAMirror() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let event = Event(startDate: start, endDate: start.addingTimeInterval(1),
                          triggeredSensors: [.touch], wrongPINCount: 2)
        let json = try XCTUnwrap(event.metadataJSON)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertEqual(payload["wrongPINCount"] as? Int, 2)

        let plain = Event(startDate: start, endDate: start, triggeredSensors: [.motion])
        let plainPayload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(plain.metadataJSON)) as? [String: Any])
        XCTAssertNil(plainPayload["wrongPINCount"], "no attempts, no key")

        let record = CloudExfiltrator.makeMetaRecord(event, deviceName: "iPhone Air", thumbnailURL: nil)
        let mirror = try XCTUnwrap(CloudExfiltrator.event(from: record))
        XCTAssertEqual(mirror.wrongPINCount, 2)
        XCTAssertEqual(mirror.sensorSummary, "Wrong PIN entered 2 times")
    }

    /// Cloud input is bounded on the way in, like every count: a sane value is kept, zero,
    /// negative or absurd values are dropped rather than obeyed.
    func testTheCloudAttemptCountIsBoundedOnTheWayIn() throws {
        func mirrored(_ raw: String) throws -> Event? {
            let start = Date(timeIntervalSince1970: 1_000_000)
            let record = CloudExfiltrator.makeMetaRecord(
                Event(startDate: start, endDate: start, triggeredSensors: [.touch]),
                deviceName: "iPhone Air", thumbnailURL: nil)
            record.encryptedValues["metadataJSON"] = "{\"v\":2,\"wrongPINCount\":\(raw)}" as CKRecordValue
            return CloudExfiltrator.event(from: record)
        }
        XCTAssertEqual(try mirrored("5")?.wrongPINCount, 5)
        XCTAssertNil(try mirrored("0")?.wrongPINCount)
        XCTAssertNil(try mirrored("-3")?.wrongPINCount)
        XCTAssertNil(try mirrored("1000000")?.wrongPINCount)
    }

    /// A mirror is replaced by a copy of the same revision that counts more attempts — the
    /// flood count's rule (the build-25 freeze). A capture that failed leaves the full push at
    /// the fact's revision, and without this the other device kept the count-less fact.
    func testAMirrorTakesALaterCopyThatCountsMoreAttempts() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let id = UUID()
        let held = Event(id: id, startDate: start, endDate: start, triggeredSensors: [.motion],
                         sourceDevice: "iPhone Air", cloudRevision: 1)
        let later = Event(id: id, startDate: start, endDate: start, triggeredSensors: [.motion, .touch],
                          sourceDevice: "iPhone Air", cloudRevision: 1, wrongPINCount: 1)
        XCTAssertTrue(EventStore.supersedes(incoming: later, existing: held))
        XCTAssertFalse(EventStore.supersedes(incoming: held, existing: later), "and never the other way")
    }

    // MARK: - The 2026-09-28 review (item 89, A2)

    /// Each capture keeps its own session's wrong PINs. A capture still running when the owner
    /// disarms and re-arms used to fold the NEW session's attempt into its record (the fold ran
    /// before the session check, over one shared counter), and the new session's first trigger
    /// reset that counter, dropping the old capture's own attempts. Two sessions, each with a
    /// minting attempt and one typed during its held capture: each record ends with its two.
    func testEachCaptureKeepsItsOwnSessionsWrongPINs() {
        let rig = makeRig()
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.noteWrongDisarmPIN()          // session 1 mints a record; its still is held
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3))
        rig.engine.noteWrongDisarmPIN()          // typed during session 1's capture
        rig.engine.disarm()                      // the right PIN; session 1's capture is still in flight
        arm(rig)
        rig.engine.noteWrongDisarmPIN()          // session 2 mints its own record, held too
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 3))
        rig.engine.noteWrongDisarmPIN()          // typed during session 2's capture
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "session 2's response re-arms")
        XCTAssertTrue(pump(until: { self.attemptRecords(rig).allSatisfy { $0.wrongPINCount == 2 } }, timeout: 5),
                      "the old response may finish after the replacement watch has re-armed")
        let records = attemptRecords(rig).sorted { $0.startDate < $1.startDate }
        XCTAssertEqual(records.count, 2, "one record per session")
        XCTAssertEqual(records.first?.wrongPINCount, 2, "session 1: its own attempt and the one typed during its capture")
        XCTAssertEqual(records.last?.wrongPINCount, 2, "session 2: likewise, none taken by session 1")
        rig.engine.disarm()
    }
}
