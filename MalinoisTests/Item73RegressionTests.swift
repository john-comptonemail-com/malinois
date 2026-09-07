//
//  Item73RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for the 1.3.1 batch (BACKLOG 73 — the owner's 2026-09-06 external review
//  pass): each pins a finding as a behavior the engine must have. Written before the fixes —
//  red at that commit — and each fix turns its own test green. Driven through the
//  characterization harness (EngineHarness.swift), like Item65RegressionTests: the real engine,
//  the real store on a throwaway root, the fake camera, and fake tripwires where a sensor's
//  reaction is the question.
//

import XCTest
import UIKit
@testable import Malinois

/// A tripwire that counts what the engine asks of it on a foreground resume (review 3, R3.3).
@MainActor
final class ResumeCountingMonitor: SensorMonitor {
    let type: SensorType
    var isEnabled = true
    var sensitivity: Sensitivity = .high
    var onTrip: ((SensorType) -> Void)?
    private(set) var resumes = 0

    init(type: SensorType) { self.type = type }

    func start() {}
    func stop() {}
    func rearm() {}
    func resumeAfterSuspension() { resumes += 1 }
}

@MainActor
final class Item73RegressionTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
    }

    // The persisted keys, spelled out: a renamed key on disk is a behavior change these tests
    // must catch, not absorb.
    private static let armedMarkerKey = "com.malinois.armedSession.brightness"
    private static let armedBootTimeKey = "com.malinois.armedSession.bootTime"
    private static let armedBootStampAtKey = "com.malinois.armedSession.bootStampAt"
    private static let armingInProgressKey = "com.malinois.arming.inProgress"
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let recoveryInProgressKey = "com.malinois.recovery.inProgress"
    private static let backgroundLapseLoggedKey = "com.malinois.armed.backgroundLapseLogged"

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem73-" + UUID().uuidString, isDirectory: true)
        clearPersistedMarkers()
    }

    override func tearDown() {
        clearPersistedMarkers()
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    private func clearPersistedMarkers() {
        let defaults = UserDefaults.standard
        for key in [Self.armedMarkerKey, Self.armedBootTimeKey, Self.armedBootStampAtKey,
                    Self.armingInProgressKey, Self.pendingReArmKey, Self.recoveryInProgressKey,
                    Self.backgroundLapseLoggedKey] {
            defaults.removeObject(forKey: key)
        }
    }

    private func makeRig(timing: EngineTiming? = nil,
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let timing = timing ?? EngineCharacterizationTests.fastTiming   // resolved on the actor, not in a default argument
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: camera,
                                      entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: timing)
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

    /// Arms through grace (0 s), calibration, and the calibration review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5),
                      "grace 0 + calibration + review should reach .armed", file: file, line: line)
    }

    // MARK: - Review 3, R3.3: a suspension the sensors could not see through

    /// A power change while the app was suspended (a Guided Access lock, a call) posts no
    /// notification, and iOS replays nothing on resume. The monitor must compare the live state
    /// with its baseline when it comes back: a state that changed while it could not watch IS
    /// the event — and the baseline moves on, so the same state is not reported twice.
    func testAPowerChangeDiscoveredOnResumeTrips() {
        let monitor = PowerMonitor()
        var state: UIDevice.BatteryState = .unplugged
        monitor.batteryStateProvider = { state }
        var trips: [SensorType] = []
        monitor.onTrip = { trips.append($0) }
        monitor.start()                      // baseline: on battery
        state = .charging                    // plugged in while suspended — nobody was told
        monitor.resumeAfterSuspension()
        XCTAssertEqual(trips, [.power], "the change discovered on resume is the trip")
        monitor.rearm()
        monitor.resumeAfterSuspension()
        XCTAssertEqual(trips, [.power], "the baseline was re-seeded — the same state again is not a second trip")
        monitor.stop()
    }

    /// The engine asks every running tripwire to resample on a foreground resume — and only
    /// while a watch is live; a disarmed engine has nothing to resample.
    func testTheEngineResamplesItsMonitorsOnAForegroundResume() {
        let rig = makeRig { $0.enabledSensors = [.motion, .power] }
        let power = ResumeCountingMonitor(type: .power)
        rig.engine.replaceMonitorForTesting(power)
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(power.resumes, 0, "disarmed: nothing to resample")
        arm(rig)
        rig.engine.handleScenePhase(true)
        XCTAssertEqual(power.resumes, 1, "armed: the monitor is asked to compare against its baseline")
        rig.engine.disarm()
    }

    /// Under Guided Access the only way to send the app to the background is the lock button,
    /// so a lapse there is a lock — and the record says so, instead of the generic "sent to the
    /// background" that hides the tamper's actual shape.
    func testABackgroundLapseUnderGuidedAccessIsRecordedAsALock() {
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: true).rawValue, "locked")
        XCTAssertEqual(MonitoringEngine.backgroundInterruptionCause(guidedAccessOn: false), .backgrounded,
                       "without Guided Access a background can be a swipe-away — the generic cause stands")
        let locked = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .localOnly,
                           interrupted: true, interruptionCause: "locked")
        XCTAssertTrue(locked.sensorSummary.lowercased().contains("locked"),
                      "the log names the lock: \(locked.sensorSummary)")
    }

    // MARK: - Review 3, R3.1: the camera after a disarm that races a capture

    /// A disarm lands while a still is open. When the capture answers, the pipeline must shut
    /// the camera down again — nothing else will: the engine's every stand-down requires an
    /// armed state or a cold-readiness policy, so a session the capture restarted would stay
    /// up on a disarmed phone, green dot on, until the next arm.
    func testADisarmDuringACaptureLeavesTheCameraCold() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front; $0.cameraReadiness = .instant }
        arm(rig)
        rig.camera.holdStills = true
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3), "the still is open")
        rig.engine.disarm()
        let atDisarm = rig.camera.shutDowns
        XCTAssertGreaterThanOrEqual(atDisarm, 1, "the disarm itself shuts the camera down")
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > atDisarm }, timeout: 3),
                      "the capture that outlived the disarm ends with a shutdown of its own")
    }

    /// The narrower race: the disarm lands while the warm-up is still answering, so the
    /// warm-up's start comes AFTER the disarm's stop. The pipeline must not capture on a
    /// disarmed engine, and must shut the camera it just restarted down again.
    func testAWarmUpThatOutlivesTheDisarmIsShutDownAgain() {
        let rig = makeRig { $0.captureMode = .photo; $0.cameraPosition = .front; $0.cameraReadiness = .batterySaver }
        arm(rig)
        rig.camera.warmUpDelay = 0.3            // the trigger's warm-up, not the arm's (cold policy: none)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.state == .triggered }, timeout: 2), "the response owns the pipeline")
        rig.engine.disarm()                      // before the warm-up answers
        let atDisarm = rig.camera.shutDowns
        XCTAssertTrue(pump(until: { rig.camera.shutDowns > atDisarm }, timeout: 3),
                      "the late warm-up is followed by a shutdown")
        XCTAssertEqual(rig.camera.stills.count, 0, "and no still is taken on a disarmed engine")
    }

    // MARK: - Review 1, F1 (a): the armed marker exists the moment the watch goes live

    /// The sensors are live and "armed" is on the record from the start of the calibration
    /// card; the marker that makes a kill recoverable at the next launch must exist from the
    /// same moment — not six seconds later when the screen goes black.
    func testTheArmedMarkerIsPlantedWhenTheWatchGoesLiveNotWhenTheScreenGoesBlack() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.calibrationReview = 1.0           // a visible card, as production's 6 s is
        let rig = makeRig(timing: timing)
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey))
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.showingCalibrationReview }, timeout: 3),
                      "the card is up: sensors live, 'armed' logged")
        XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey),
                        "a kill during the card must be recoverable — the marker exists as soon as the watch is live")
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 3))
        rig.engine.disarm()
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey), "a clean disarm removes it")
    }

    // MARK: - Review 3, R3.2: the arming window leaves a trace

    /// Cancelling the countdown needs no PIN and used to leave nothing — the one path to
    /// escape an arm with no record. Now it plants a marker at Start countdown, and the cancel
    /// consumes the marker and writes a record.
    func testCancellingTheCountdownLeavesARecord() {
        let rig = makeRig { $0.gracePeriodSeconds = 30 }
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(rig.engine.state, .arming)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: Self.armingInProgressKey),
                      "the countdown plants a marker a kill would leave behind")
        rig.engine.cancelArming()
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "armingCancelled" },
                      "the cancel is on the record")
        XCTAssertFalse(rig.store.events.contains { $0.stateChange == "disarmed" },
                       "no 'disarmed' row for a watch that never went live")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.armingInProgressKey), "the cancel consumes the marker")
    }

    /// Going live hands over from the arming marker to the armed marker: exactly one of them
    /// exists at any moment of a session.
    func testGoingLiveConsumesTheArmingMarker() {
        let rig = makeRig()
        arm(rig)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.armingInProgressKey),
                       "the armed marker takes over at go-live")
        XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.armedMarkerKey))
        rig.engine.disarm()
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.armingInProgressKey))
    }

    /// A marker left behind by a kill during the countdown: the next launch records that the
    /// arm never completed — and does NOT re-arm. A force-quit during the countdown is the
    /// owner's own abort far more often than an attack (review 1's F1 scope (b), declined);
    /// the record is the honest part, the re-arm was the objectionable part.
    func testAKillDuringTheCountdownIsRecordedAtTheNextLaunchWithoutAReArm() {
        UserDefaults.standard.set(true, forKey: Self.armingInProgressKey)
        let store = EventStore()
        let engine = MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                      camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: EngineCharacterizationTests.fastTiming)
        XCTAssertEqual(engine.state, .disarmed, "no re-arm: the countdown never went live")
        XCTAssertTrue(store.events.contains { $0.stateChange == "armingInterrupted" },
                      "the launch says the arm did not complete")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.armingInProgressKey), "consumed")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: Self.pendingReArmKey), "nothing owed")
    }

    /// The cancel rides the disarm alert to the owner's other devices (Pro): a stop of future
    /// protection is what that alert exists for, whatever its wording — the mirrored record
    /// carries the exact reason. A kill's launch-time record is local news, not an alert.
    func testTheCancelRecordRidesTheDisarmAlert() {
        XCTAssertTrue(CloudExfiltrator.disarmSignalWanted(kind: "armingCancelled"))
        XCTAssertTrue(CloudExfiltrator.disarmSignalWanted(kind: "disarmed"))
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "armingInterrupted"))
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "armed"))
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "gaLifted"))
    }

    func testTheNewRecordsRenderInPlainWords() {
        func summary(_ kind: String) -> String {
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .localOnly,
                  stateChange: kind).sensorSummary
        }
        XCTAssertEqual(summary("armingCancelled"), "Arming cancelled before going live")
        XCTAssertEqual(summary("armingInterrupted"), "Arming did not complete: the app ended during the countdown")
    }

    // MARK: - Review 1, R2 (a): the Sound tripwire through a clip that takes no microphone

    /// Clip audio is off by default since item 69, so the default clip session attaches no
    /// microphone — and the pause that freed the mic for it (F-14) cost the Sound tripwire its
    /// hearing for every clip, for nothing. A mic-less clip keeps it watching.
    func testAMicLessClipDoesNotPauseTheSoundTripwire() {
        let rig = makeRig {
            $0.captureMode = .untilClear
            $0.cameraPosition = .front
            $0.responseMode = .alert
            $0.enabledSensors = [.motion, .audio, .camera]
        }
        let audio = FakeSensorMonitor(type: .audio)
        rig.engine.replaceMonitorForTesting(audio)
        arm(rig)
        XCTAssertFalse(rig.camera.clipAudio, "the default: clips take no microphone")
        XCTAssertTrue(audio.isWatching)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        XCTAssertTrue(audio.isWatching, "no microphone to free: the Sound tripwire keeps listening through the clip")
        XCTAssertTrue(pump(until: { rig.camera.clipEnds == 1 && rig.engine.state == .armed }, timeout: 5))
        XCTAssertTrue(audio.isWatching)
        XCTAssertEqual(audio.stops, 0, "never stopped for the clip")
        rig.engine.disarm()
    }

    // MARK: - Review 1, R3: no warm-up blindness right after calibration

    /// The Sound monitor's start seeds a ~1.5 s warm-up during which nothing trips — right for a
    /// resume after the siren, when the room may have changed, and pointless at go-live, where
    /// calibration has just set the baseline from three seconds of samples. The watch that
    /// follows a calibration hears at once; a later restart warms up as before.
    func testTheSoundMonitorHearsAtOnceAfterCalibration() {
        XCTAssertEqual(AudioMonitor.warmupSampleCount(afterCalibration: true), 0)
        XCTAssertEqual(AudioMonitor.warmupSampleCount(afterCalibration: false), 15)
        let monitor = AudioMonitor()
        monitor.beginCalibration()
        monitor.endCalibration()
        monitor.start()
        XCTAssertEqual(monitor.warmupSamplesRemainingForTesting, 0, "fresh baseline: no warm-up at go-live")
        monitor.stop()
        monitor.start()
        XCTAssertEqual(monitor.warmupSamplesRemainingForTesting, 15, "a restart with no calibration warms up, as before")
        monitor.stop()
    }

    // MARK: - Review 3, R3.4: the lift record is bounded across arm attempts

    /// Every ARM → lift → Cancel cycle used to mint a `gaLifted` record (the latch released at
    /// the next arm), so five hundred cycles of tapping filled the count cap and evicted real
    /// evidence first. The latch now releases only when an arm goes LIVE — unreachable for a
    /// snoop without the countdown completing — and the "someone poked at it" signal survives.
    func testTheLiftRecordIsMintedOncePerSpreeUntilAnArmGoesLive() {
        let hadArmedOnce = OnboardingState.hasArmedOnce
        OnboardingState.hasArmedOnce = true          // no first-arm auto-lift (item 68) in the way
        defer { OnboardingState.hasArmedOnce = hadArmedOnce }
        let rig = makeRig { $0.requireGuidedAccess = true }   // Guided Access is off in the test host: blocked
        func liftRecords() -> Int { rig.store.events.filter { $0.stateChange == "gaLifted" }.count }
        for _ in 0..<3 {
            rig.engine.beginArming()
            XCTAssertTrue(rig.engine.armingBlockedByGuidedAccess)
            rig.engine.liftGuidedAccessRequirementForThisArm()
            rig.engine.cancelArming()
        }
        XCTAssertEqual(liftRecords(), 1, "three lift-and-cancel cycles, one record")
        rig.engine.beginArming()
        rig.engine.liftGuidedAccessRequirementForThisArm()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "the lifted arm goes live")
        rig.engine.disarm()
        rig.engine.beginArming()
        rig.engine.liftGuidedAccessRequirementForThisArm()
        XCTAssertEqual(liftRecords(), 2, "after a watch went live, the next lift is a new event")
        rig.engine.cancelArming()
    }

    // MARK: - Review 1, F2: the crash-loop guard and a clock set back

    func testACrashLoopIsNeverInferredFromAClockSetBack() {
        XCTAssertFalse(MonitoringEngine.isCrashLoop(lastAttempt: 1_800_000_000, now: 1_700_000_000),
                       "a backward clock reads as no loop — not as a 100-million-second loop")
        XCTAssertTrue(MonitoringEngine.isCrashLoop(lastAttempt: 1_000, now: 1_030), "the real loop still trips")
    }

    // MARK: - Review 2, R2.2: a quarantined log is surfaced

    /// A log that fails to decode is preserved as a timestamped backup and a fresh log starts —
    /// silently, until now: the owner saw an empty log, and the backup is reaped after 30 days.
    /// The store says so, and the next clean load clears it.
    func testAQuarantinedLogIsSurfacedUntilTheNextCleanLoad() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: root.appendingPathComponent("events.json"))
        let quarantined = EventStore()
        XCTAssertTrue(quarantined.logWasQuarantined, "the owner is told the log was set aside")
        XCTAssertTrue(quarantined.events.isEmpty, "a fresh log")
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("events.corrupt-") }
        XCTAssertEqual(backups.count, 1, "the unreadable file is preserved, not clobbered")
        quarantined.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .localOnly))
        quarantined.flush()
        let reloaded = EventStore()
        XCTAssertFalse(reloaded.logWasQuarantined, "a clean load clears the notice")
        XCTAssertEqual(reloaded.events.count, 1)
    }

    // MARK: - Review 1, R6: a journal that cannot be written is surfaced

    /// The birth journal is the crash-durability promise; an append or full sync that failed was
    /// logged and swallowed, and the store proceeded as if the promise held. It raises a flag
    /// Home renders; the record itself still lands through the full write.
    func testAJournalThatCannotBeWrittenIsSurfaced() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        // A directory where the journal file goes: every append fails.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events.journal"), withIntermediateDirectories: true)
        let store = EventStore()
        XCTAssertFalse(store.journalDegraded, "nothing written yet")
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .localOnly))
        XCTAssertTrue(store.journalDegraded, "the failed append reaches the owner's screen, not only the console")
        XCTAssertEqual(store.events.count, 1, "the record still lands in memory and through the full write")
    }

    // MARK: - Review 1, R10: a refused Keychain write cannot lower the brute-force count

    /// The failure count and the lockout deadline live in the Keychain; a write that failed
    /// was discarded, so a run of failed guesses against a Keychain that refused writes never
    /// locked the pad. An in-process mirror now keeps the count and the deadline for the life
    /// of the process, whatever the Keychain accepted.
    func testARefusedKeychainWriteCannotLowerTheLockout() throws {
        try XCTSkipUnless(KeychainService.setPIN("4321"), "Keychain unavailable in this build")
        KeychainService.resetAttempts()
        KeychainService.failWritesForTesting = true
        defer { KeychainService.failWritesForTesting = false; KeychainService.resetAttempts() }
        for _ in 0..<5 { _ = KeychainService.recordFailure() }
        XCTAssertGreaterThan(KeychainService.lockoutRemaining(), 0,
                             "five failed guesses lock the pad although none of them could be written down")
    }

    // MARK: - Review 1, R7: a microphone that could not be attached is reported

    /// Clip audio asked for, permission granted, and the capture session still could not
    /// attach the microphone: the session was built silent with a console line and nothing
    /// for the owner. The arm-time warm-up now surfaces it in the microphone notice.
    func testAMicThatCouldNotBeAttachedIsSurfacedAtArm() {
        let rig = makeRig {
            $0.captureMode = .clip3; $0.clipAudio = true; $0.cameraReadiness = .instant
            $0.enabledSensors = [.motion, .camera]
        }
        rig.camera.micUnavailableForClips = true
        arm(rig)
        XCTAssertTrue(pump(until: { rig.engine.audioNotice?.lowercased().contains("microphone") == true }, timeout: 3),
                      "the arm-time warm-up reports the missing microphone: \(rig.engine.audioNotice ?? "nil")")
        rig.engine.disarm()
    }

    // MARK: - Item 69 leg 10: the notifications line counts only another device's records

    /// A device's own pre-reinstall records come back mirrored through the launch restore, so
    /// "any mirrored record" showed the notifications line on a single-device account after
    /// any reinstall. Only a record from a device with another name counts.
    func testTheNotificationsLineCountsOnlyAnotherDevicesRecords() {
        func record(from device: String?) -> Event {
            var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
            event.sourceDevice = device
            return event
        }
        XCTAssertFalse(MonitoringEngine.otherDeviceSeen(events: [record(from: nil)], thisDevice: "Air"),
                       "first-hand records are not another device")
        XCTAssertFalse(MonitoringEngine.otherDeviceSeen(events: [record(from: "Air")], thisDevice: "Air"),
                       "this device's own restored records are not another device")
        XCTAssertTrue(MonitoringEngine.otherDeviceSeen(events: [record(from: "Air"), record(from: "17 Pro")], thisDevice: "Air"))
        XCTAssertFalse(MonitoringEngine.otherDeviceSeen(events: [], thisDevice: "Air"))
    }

    // MARK: - Item 70: the "Guided Access was ON when you last disarmed" memory is gone

    /// The notice fired after every normal disarm — the state was sampled before the owner's
    /// own exit from Guided Access — and was ruled out. A launch retires the memory a 1.3 (44)
    /// install left behind, and a disarm no longer records it.
    func testTheGuidedAccessDisarmMemoryIsNeitherWrittenNorKept() {
        let key = "com.malinois.guidedAccess.atLastDisarm"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.set(true, forKey: key)                 // left by a 1.3 (44) install
        let rig = makeRig()
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "launch retires the old memory")
        arm(rig)
        rig.engine.disarm()
        XCTAssertNil(UserDefaults.standard.object(forKey: key), "a disarm no longer records it")
    }

    // MARK: - Review 2, R2.3: transition timers keep firing while the run loop is tracking

    private final class Flag: @unchecked Sendable { var value = false }

    /// `Timer.scheduledTimer` runs in the `.default` mode only, which pauses while the run loop
    /// tracks a touch; the grace countdown learned this first. Every timer that participates
    /// in a security or safety transition now goes through `Timer.commonMode`. The stage here
    /// is a mode of the test's own, registered as common exactly as UIKit registers its
    /// tracking mode — the same mechanism, without depending on what the test host's tracking
    /// mode contains while nothing is being dragged (the owner's first run of this test found
    /// that stage empty: the single-pass run returned before the timer's date).
    func testACommonModeTimerFiresWhileTheRunLoopIsTracking() {
        let mode = RunLoop.Mode("com.malinois.tests.tracking")
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(mode.rawValue as CFString))
        let common = Flag(), standard = Flag()
        Timer.commonMode(interval: 0.05, repeats: false) { _ in common.value = true }
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { _ in standard.value = true }
        let deadline = Date().addingTimeInterval(1)
        while !common.value && Date() < deadline {
            _ = RunLoop.main.run(mode: mode, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(common.value, "a .common timer fires in every common mode — a scroll drag's included")
        XCTAssertFalse(standard.value, "a default-mode timer pauses there — the reason the sweep exists")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))   // let the default one fire, so it cannot leak into another test
    }
}
