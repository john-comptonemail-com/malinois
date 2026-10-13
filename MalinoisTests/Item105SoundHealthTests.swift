//
//  Item105SoundHealthTests.swift
//  MalinoisTests
//
//  BACKLOG 105, F-09 (1.6; the owner ruled option a on 2026-10-12). The Sound tripwire's monitor
//  rebuilds a stopped microphone recorder at most every 2 s, but a microphone that stays
//  unavailable left no record: a tripwire that reports nothing and cannot fire. Now, when the
//  recorder, having worked during a live watch, has then been down for 30 s, the log gets a quiet
//  status entry, and another when it works again, like the heat warnings: no siren, no
//  cross-device alert. A microphone that never worked this watch (no permission) is already
//  shown as "Mic unavailable" before go-live and is not an outage. Planned pauses (a clip
//  recording audio, the siren) do not count, and at most three outages are recorded per watch.
//  Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item105SoundHealthTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem105Sound")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
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
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    private func soundRecords(_ rig: Rig) -> [String] {
        rig.store.events.compactMap(\.stateChange).filter { $0.hasPrefix("sound") }.sorted()
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    // MARK: - The rule

    /// Down for 30 s in a row is an outage, reported once; the recorder working again is reported.
    func testAnOutageIsReportedAfterThirtySecondsAndOnceUntilItRecovers() {
        var tracker = SoundHealthTracker()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertNil(tracker.observe(recording: true, at: start))
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(1)))
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(30)), "29 s down is not yet an outage")
        XCTAssertEqual(tracker.observe(recording: false, at: start.addingTimeInterval(31)), .unavailable)
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(90)), "reported once per outage")
        XCTAssertEqual(tracker.observe(recording: true, at: start.addingTimeInterval(91)), .restored)
        XCTAssertNil(tracker.observe(recording: true, at: start.addingTimeInterval(92)))
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(93)), "a brief drop is not an outage")
        XCTAssertNil(tracker.observe(recording: true, at: start.addingTimeInterval(94)), "and its end is not news")
    }

    /// A microphone that never worked this watch is not an outage: before go-live the calibration
    /// review already says "Mic unavailable", and a record every watch would only repeat it.
    func testAMicrophoneThatNeverWorkedThisWatchIsNotAnOutage() {
        var tracker = SoundHealthTracker()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        for seconds in [0.0, 31, 120, 600] {
            XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(seconds)))
        }
    }

    /// A planned pause (a clip recording audio, the siren) restarts the 30 s clock.
    func testPlannedPausesRestartTheClock() {
        var tracker = SoundHealthTracker()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        XCTAssertNil(tracker.observe(recording: true, at: start))
        XCTAssertNil(tracker.observe(recording: false, at: start))
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(20)))
        tracker.pause()
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(25)))
        XCTAssertNil(tracker.observe(recording: false, at: start.addingTimeInterval(50)), "20 s + 25 s across a pause is not 30 s in a row")
        XCTAssertEqual(tracker.observe(recording: false, at: start.addingTimeInterval(55)), .unavailable)
    }

    /// Three outages a watch at most, so a flapping microphone cannot fill the status history.
    /// The third outage's recovery is not reported either: the log errs toward "unavailable".
    func testAtMostThreeOutagesAreReportedPerWatch() {
        var tracker = SoundHealthTracker()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        var reports: [SoundHealthTracker.Report] = []
        XCTAssertNil(tracker.observe(recording: true, at: now))
        for _ in 0..<5 {
            for _ in 0..<2 {
                if let report = tracker.observe(recording: false, at: now) { reports.append(report) }
                now = now.addingTimeInterval(31)
            }
            if let report = tracker.observe(recording: true, at: now) { reports.append(report) }
            now = now.addingTimeInterval(1)
        }
        XCTAssertEqual(reports, [.unavailable, .restored, .unavailable, .restored, .unavailable])
        tracker.reset()
        XCTAssertNil(tracker.observe(recording: true, at: now))
        XCTAssertNil(tracker.observe(recording: false, at: now))
        XCTAssertEqual(tracker.observe(recording: false, at: now.addingTimeInterval(31)), .unavailable, "a new watch reports again")
    }

    // MARK: - The monitor

    /// The monitor reports from its own ticks while watching, and a planned pause restarts the clock.
    func testTheMonitorReportsAnOutageFromItsTicks() {
        let audio = AudioMonitor()
        var clock = Date(timeIntervalSinceReferenceDate: 5_000)
        var recording = true
        var reports: [SoundHealthTracker.Report] = []
        audio.currentLevelForTesting = { -50 }
        audio.recordingForTesting = { recording }
        audio.nowForTesting = { clock }
        audio.deactivateAudioSessionForTesting = {}
        audio.onHealthReport = { reports.append($0) }
        audio.start()
        let tick = audio.queuedMeterTickForTesting(calibration: false)
        tick()
        recording = false
        tick()
        clock = clock.addingTimeInterval(31)
        tick()
        XCTAssertEqual(reports, [.unavailable])
        recording = true
        tick()
        XCTAssertEqual(reports, [.unavailable, .restored])

        recording = false
        tick()
        audio.pauseForCapture()
        audio.start()
        let resumed = audio.queuedMeterTickForTesting(calibration: false)
        clock = clock.addingTimeInterval(20)
        resumed()
        clock = clock.addingTimeInterval(20)
        resumed()
        XCTAssertEqual(reports, [.unavailable, .restored], "the pause restarted the 30 s clock")
        audio.stop()
    }

    // MARK: - The engine

    /// Armed, an outage and its recovery each write one quiet record, and nothing else changes.
    func testASoundOutageWhileArmedWritesQuietRecordsAndNoAlarm() {
        let rig = makeRig()
        arm(rig)
        rig.engine.handleSoundHealthReport(.unavailable)
        rig.engine.handleSoundHealthReport(.restored)
        XCTAssertEqual(soundRecords(rig), ["soundRestored", "soundUnavailable"])
        XCTAssertEqual(rig.engine.state, .armed, "not a trip: the watch carries on")
        XCTAssertFalse(rig.engine.alertActive, "no siren, no alert")
        rig.engine.disarm()
    }

    /// Nothing is recorded while disarmed.
    func testNothingIsRecordedWhileDisarmed() {
        let rig = makeRig()
        rig.engine.handleSoundHealthReport(.unavailable)
        XCTAssertTrue(soundRecords(rig).isEmpty)
    }

    /// The engine's Sound monitor is built with its reports wired to the log.
    func testTheEngineWiresTheSoundMonitorsReports() {
        let rig = makeRig()
        arm(rig)
        let audio = rig.engine.makeAudioMonitor()
        audio.onHealthReport?(.unavailable)
        XCTAssertEqual(soundRecords(rig), ["soundUnavailable"])
        rig.engine.disarm()
    }

    // MARK: - The record

    /// Both records read as plain sentences in the log.
    func testSoundRecordsReadAsPlainSentences() {
        XCTAssertEqual(stateEvent("soundUnavailable").sensorSummary,
                       "Sound tripwire unavailable while armed: the microphone could not be restarted")
        XCTAssertEqual(stateEvent("soundRestored").sensorSummary, "Sound tripwire working again")
    }

    /// A status entry this build does not know is not presented as "Signal loss", which asserts an attack.
    func testAnUnrecognizedStatusEntryIsNotCalledSignalLoss() {
        let summary = stateEvent("someFutureKind").sensorSummary
        XCTAssertNotEqual(summary, "Signal loss")
        XCTAssertEqual(summary, "Status entry this version of Malinois does not recognize")
    }

    /// The owner's other devices read both records back; an unknown kind is still dropped.
    func testSoundRecordsAreReadBackFromTheCloud() {
        for kind in ["soundUnavailable", "soundRestored"] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind, "another device's log shows \(kind)")
        }
        let unknown = CloudExfiltrator.makeStateRecord(stateEvent("someFutureKind"), kind: "someFutureKind", deviceName: "iPhone Air")
        XCTAssertNil(CloudExfiltrator.stateEvent(from: unknown), "an unknown kind is still dropped")
    }
}
