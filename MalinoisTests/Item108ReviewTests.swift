//
//  Item108ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 108: two adversarial reviews of 1.6 (64) (2026-10-13), each finding checked against the
//  code; the owner's rulings the same day. The confirmed defects, the app-text corrections and the
//  owner's decisions 2A and 3, for build 65:
//  - SE-01: a microphone that failed to restart read as silence, which sank the Sound baseline, so
//    the unchanged room tripped a false Sound event when it came back (calibration likewise).
//  - CE-01: late camera evidence was stored on its event, but no upload was started.
//  - CE-02: a device holding an event's front-camera copy refused the copy that adds the rear camera.
//  - CE-03: the watch remembered a relayed alert before posting it, so a failed post was never retried.
//  - F8: the torch lit before the clip storage check; orphaned pending clips were never reaped.
//  - D-07, F6, F10, 8, 2A, 3: a made-up price, the Stealth caption, a PIN pad with no way back to ✓,
//    the Pro welcome's cloud wording, a warning for an arm without Guided Access, and PIN advice.
//  The pipeline's CE-01 and F14 tests sit in EvidenceCapturePipelineTests, beside their fake host.
//  Written before the changes, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item108ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem108")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The source between `start` and the next `end` marker, for checks on one function.
    private func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let begin = try XCTUnwrap(source.range(of: start), start)
        let rest = source[begin.upperBound...]
        let stop = rest.range(of: end)?.lowerBound ?? rest.endIndex
        return rest[..<stop]
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    // MARK: - SE-01: a microphone that is down is missing data, not silence

    /// The Sound monitor on a -50 dBFS room, ticked by hand: `level` and `recording` say what the
    /// microphone reports on each tick.
    @MainActor private final class SoundRig {
        let audio = AudioMonitor()
        var level = -50.0
        var recording = true
        var trips: [SensorType] = []
        init() {
            audio.currentLevelForTesting = { [unowned self] in level }
            audio.recordingForTesting = { [unowned self] in recording }
            audio.deactivateAudioSessionForTesting = {}
            audio.onTrip = { [unowned self] in trips.append($0) }
        }
    }

    /// A failed restart reads -160 dBFS for three seconds; the room is unchanged when the
    /// microphone returns, so nothing trips.
    func testAFailedMicrophoneRestartDoesNotTripOnTheUnchangedRoom() {
        let rig = SoundRig()
        rig.audio.start()
        let tick = rig.audio.queuedMeterTickForTesting(calibration: false)
        for _ in 0..<25 { tick() }                     // warm-up on the room, then watching
        rig.recording = false; rig.level = -160        // the rebuild failed: no recorder
        for _ in 0..<30 { tick() }
        rig.recording = true; rig.level = -50          // back, and the room is the same
        for _ in 0..<5 { tick() }
        XCTAssertEqual(rig.trips, [], "an unchanged room after a microphone outage is not a sound")
        rig.audio.stop()
    }

    /// After such an outage a real sound still trips (guards the fix: passes before and after).
    func testAfterAMicrophoneOutageARealSoundStillTrips() {
        let rig = SoundRig()
        rig.audio.start()
        let tick = rig.audio.queuedMeterTickForTesting(calibration: false)
        for _ in 0..<25 { tick() }
        rig.recording = false; rig.level = -160
        for _ in 0..<30 { tick() }
        rig.recording = true; rig.level = -20          // a door slams
        tick()
        XCTAssertEqual(rig.trips, [.audio])
        rig.audio.stop()
    }

    /// Calibration ignores samples taken while the microphone is down, so the room it learns is the
    /// room, and going live does not trip on it.
    func testCalibrationIgnoresAMicrophoneThatIsDown() {
        let rig = SoundRig()
        rig.audio.beginCalibration()
        let sample = rig.audio.queuedMeterTickForTesting(calibration: true)
        rig.recording = false; rig.level = -160
        for _ in 0..<10 { sample() }
        rig.recording = true; rig.level = -50
        for _ in 0..<5 { sample() }
        rig.audio.endCalibration()
        XCTAssertEqual(rig.audio.calibratedBaselineDB, -50, accuracy: 0.5, "the room, not the outage")
        rig.audio.start()
        let tick = rig.audio.queuedMeterTickForTesting(calibration: false)
        for _ in 0..<5 { tick() }
        XCTAssertEqual(rig.trips, [], "going live in the same room trips nothing")
        rig.audio.stop()
    }

    // MARK: - CE-01: late evidence starts an upload

    private func sweepRig() async -> (engine: MonitoringEngine, store: EventStore) {
        var timing = EngineCharacterizationTests.fastTiming
        timing.sweepWaitFloor = 0.05
        timing.sweepWaitCeiling = 0.2
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: timing))
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(nanoseconds: 200_000_000)   // the launch sweep finds no iCloud and ends
        return (engine, store)
    }

    private func reopened() -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .pending)
    }

    /// Evidence stored on an event after its capture deadline is uploaded without waiting for a
    /// relaunch, a foreground or a reconnect.
    func testLateEvidenceStartsAnUploadPass() async {
        let (engine, store) = await sweepRig()
        let late = reopened()
        store.add(late)
        var uploaded: [UUID] = []
        engine.sweepUploadForTesting = { event in uploaded.append(event.id); return (.synced, nil) }
        engine.captureEvidenceStoredLate()
        let sent = await waitUntil(timeout: 3) { uploaded.contains(late.id) }
        XCTAssertTrue(sent, "late evidence goes out at once")
    }

    /// A sweep already running chose its records before the late evidence was pending: once it
    /// ends, the late evidence gets a pass of its own.
    func testLateEvidenceDuringARunningSweepGetsAPassOfItsOwn() async {
        let (engine, store) = await sweepRig()
        let early = Event(startDate: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(-60),
                          triggeredSensors: [.touch], cloudSyncState: .localOnly)
        store.add(early)
        var release = false
        var uploaded: [UUID] = []
        engine.sweepUploadForTesting = { event in
            while !release { try? await Task.sleep(nanoseconds: 10_000_000) }
            uploaded.append(event.id)
            return (.synced, nil)
        }
        let sweep = Task { await engine.retryPendingSync() }
        await waitUntil(timeout: 2) { engine.pendingSweepActive }
        let late = reopened()
        store.add(late)
        engine.captureEvidenceStoredLate()
        release = true
        await sweep.value
        let sent = await waitUntil(timeout: 5) { uploaded.contains(late.id) }
        XCTAssertTrue(sent, "the late evidence is not left for the next launch")
    }

    // MARK: - CE-02: the second camera's evidence is a new revision

    private func capture(id: UUID = UUID(), front: Bool, rear: Bool, owner: Bool = false,
                         mirrorOf device: String? = nil) -> Event {
        // A decoded mirror holds no file of its own: its media names stay nil, its thumbnail and
        // revision come from the record.
        let local = device == nil
        var event = Event(id: id, startDate: Date(timeIntervalSince1970: 1_700_000_000),
                          endDate: Date(timeIntervalSince1970: 1_700_000_005), triggeredSensors: [.motion],
                          mediaFilename: front && local ? "front.jpg" : nil,
                          secondaryMediaFilename: rear && local ? "rear.jpg" : nil,
                          thumbnailData: front ? Data([0xFF]) : nil,
                          ownerAttributed: owner ? true : nil, sourceDevice: device)
        if !local {
            let sender = capture(front: front, rear: rear, owner: owner)
            event.cloudRevision = CloudExfiltrator.metaRevision(for: sender)
        }
        return event
    }

    /// The rear camera's evidence, which can arrive after the front's, raises the revision.
    func testTheSecondCamerasEvidenceRaisesTheRevision() {
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: capture(front: true, rear: false)), 2)
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: capture(front: true, rear: true)), 3)
        XCTAssertEqual(CloudExfiltrator.metaRevision(for: capture(front: true, rear: true, owner: true)), 4)
        XCTAssertFalse(CloudExfiltrator.mayWrite(revision: CloudExfiltrator.metaRevision(for: capture(front: true, rear: false)),
                                                 alreadySubmitted: CloudExfiltrator.metaRevision(for: capture(front: true, rear: true))),
                       "a stale front-only write cannot replace the record with both cameras")
    }

    /// A device holding the front-only copy takes the copy that adds the rear camera.
    func testAMirrorTakesTheCopyThatAddsTheRearCamera() {
        let id = UUID()
        let held = capture(id: id, front: true, rear: false, mirrorOf: "iPad mini")
        let richer = capture(id: id, front: true, rear: true, mirrorOf: "iPad mini")
        XCTAssertTrue(EventStore.supersedes(incoming: richer, existing: held))
        XCTAssertFalse(EventStore.supersedes(incoming: held, existing: richer), "and never goes back")
    }

    // MARK: - CE-03: the watch remembers only what it showed

    /// A relayed alert is remembered once posted; one that failed to post can be tried again; a
    /// copy arriving while the first is still being posted is not posted twice.
    func testTheWatchRemembersAnAlertOnlyOnceItIsShown() {
        var ledger = WatchAlertStatus.RelayLedger()
        XCTAssertTrue(ledger.begin("a"))
        XCTAssertFalse(ledger.begin("a"), "a copy arriving mid-post waits for the first")
        ledger.finish("a", posted: false)
        XCTAssertFalse(ledger.shown.contains("a"), "a failed post is not remembered")
        XCTAssertTrue(ledger.begin("a"), "so a later copy can try again")
        ledger.finish("a", posted: true)
        XCTAssertEqual(ledger.shown, ["a"])
        XCTAssertFalse(ledger.begin("a"), "once shown, never again")
        var full = WatchAlertStatus.RelayLedger(shown: (0..<WatchAlertStatus.rememberedRelayLimit).map { "id\($0)" })
        XCTAssertTrue(full.begin("new"))
        full.finish("new", posted: true)
        XCTAssertEqual(full.shown.count, WatchAlertStatus.rememberedRelayLimit, "still bounded")
        XCTAssertEqual(full.shown.last, "new")
    }

    /// The watch posts first and records the alert only when the post succeeded.
    func testTheWatchPostsBeforeRememberingOrRecording() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        let show = try section(delegate, from: "private func showRelayed(", to: "\n    }\n")
        let post = try XCTUnwrap(show.range(of: ".add(request)"))
        let remember = try XCTUnwrap(show.range(of: "relayLedger.finish("))
        let record = try XCTUnwrap(show.range(of: "recordAlert(source: .iPhoneLink)"))
        XCTAssertLessThan(post.lowerBound, remember.lowerBound)
        XCTAssertLessThan(post.lowerBound, record.lowerBound)
        XCTAssertTrue(show.contains("relayLedger.begin("))
    }

    // MARK: - F8: the torch waits for storage; orphaned clips are reaped

    /// Each clip start checks for storage before lighting the torch.
    func testTheTorchWaitsForTheStorageCheck() throws {
        let camera = try text("Malinois/Services/CameraController.swift")
        for (start, admission) in [("nonisolated func beginClip(", "pendingMovieDestinations(outputs: 1)"),
                                   ("nonisolated func beginBothClips(", "pendingMovieDestinations(outputs: 2)")] {
            let body = try section(camera, from: start, to: "\n    }\n")
            let check = try XCTUnwrap(body.range(of: admission), start)
            let torch = try XCTUnwrap(body.range(of: "setTorch(true"), start)
            XCTAssertLessThan(check.lowerBound, torch.lowerBound, "\(start) lights the torch only with somewhere to record")
        }
    }

    /// Pending clips no event took are removed after 30 days; recent ones, and files this app did
    /// not name, stay.
    func testOrphanedPendingClipsAreReapedAfterThirtyDays() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Item108Pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func file(_ name: String, age days: Double) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data([0]).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)],
                                                  ofItemAtPath: url.path)
            return url
        }
        let old = try file(UUID().uuidString + ".mov", age: 31)
        let recent = try file(UUID().uuidString + ".mov", age: 2)
        let foreign = try file("notes.mov", age: 90)
        CameraController.sweepOrphanedPendingClips(in: root, olderThan: 30 * 86_400, now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "a month-old orphan is reaped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path), "a recent clip may still be attached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path), "only this app's own clips")
    }

    /// The app reaps them at launch, beside the legacy temporary-clip sweep.
    func testTheAppReapsOrphanedPendingClipsAtLaunch() throws {
        let app = try text("Malinois/MalinoisApp.swift")
        XCTAssertTrue(app.contains("CameraController.sweepOrphanedPendingClips()"))
    }

    // MARK: - D-07: no made-up price

    /// Until StoreKit has the price, the button and caption name none.
    func testThePriceIsNeverMadeUp() {
        XCTAssertEqual(PaywallView.priced("Unlock Pro", displayPrice: nil), "Unlock Pro")
        XCTAssertEqual(PaywallView.priced("Unlock Pro", displayPrice: "£8.99"), "Unlock Pro - £8.99")
        XCTAssertFalse(PaywallView.oneTimeCaption(displayPrice: nil).contains("$"))
        XCTAssertEqual(PaywallView.oneTimeCaption(displayPrice: "€9,99"), "One-time €9,99.")
    }

    /// The paywall and Settings use them, and no "$9.99" fallback is left.
    func testNoScreenFallsBackToAFixedPrice() throws {
        for file in ["Malinois/Views/PaywallView.swift", "Malinois/Views/SettingsView.swift"] {
            XCTAssertFalse(try text(file).contains("?? \"$9.99\""), file)
        }
    }

    // MARK: - F6, F10, 8, 3: app text and the PIN pad

    /// Stealth's caption names the recording indicator instead of promising nothing is shown.
    func testTheStealthCaptionMentionsTheRecordingIndicator() throws {
        let settings = try text("Malinois/Views/SettingsView.swift")
        let stealth = try section(settings, from: "case .stealth: return \"", to: "\n")
        XCTAssertFalse(stealth.contains("nothing is shown"))
        XCTAssertTrue(stealth.contains("recording indicator"))
    }

    /// After a wrong entry submitted at the confirmed length, the pad shows ✓ for the rest of that
    /// entry, so a wrong stored length can never lock the owner out of submitting.
    func testAWrongAutoSubmittedPINBringsBackTheSubmitKey() throws {
        let pins = try text("Malinois/Views/PINViews.swift")
        let check = try section(pins, from: "private func check() {", to: "\n    }\n")
        let wrong = try XCTUnwrap(check.range(of: "} else {"))
        XCTAssertTrue(check[wrong.upperBound...].contains("autoSubmitLength = nil"))
        XCTAssertTrue(PINPad.showsSubmitKey(conceal: true, autoSubmitLength: nil))
    }

    /// The Pro welcome says the developer cannot read the data, and how far the encryption goes.
    func testTheProWelcomeSaysWhoCanReadTheData() throws {
        let onboarding = try text("Malinois/Views/OnboardingViews.swift")
        // The closing note's own case: the file's first "case .pro:" is the headline's.
        let pro = try section(onboarding, from: "private var closingNote: String {", to: "case .earlyAccess:")
        XCTAssertFalse(pro.contains("nobody else can read it"))
        XCTAssertTrue(pro.contains("the developer can't read"))
        XCTAssertTrue(pro.contains("Advanced Data Protection"))
    }

    /// Creating a PIN advises a code different from the iPhone's and Guided Access's.
    func testPINSetupAdvisesADifferentCode() throws {
        let pins = try text("Malinois/Views/PINViews.swift")
        let setup = try section(pins, from: "struct PINSetupView: View {", to: "private func advance()")
        XCTAssertTrue(setup.contains("different from your iPhone passcode and your Guided Access passcode"))
    }

    // MARK: - 2A: an arm without Guided Access says what that means

    /// The warning shows exactly when the requirement was lifted for this arm and Guided Access is
    /// off, whether the first arm lifted it automatically or the owner did.
    func testAnArmWithoutGuidedAccessIsWarnedAbout() throws {
        XCTAssertTrue(ArmingView.showsUnconfinedWarning(liftedThisArm: true, guidedAccessOn: false))
        XCTAssertFalse(ArmingView.showsUnconfinedWarning(liftedThisArm: true, guidedAccessOn: true))
        XCTAssertFalse(ArmingView.showsUnconfinedWarning(liftedThisArm: false, guidedAccessOn: false),
                       "unlifted, the arm is refused and the required notice shows instead")
        XCTAssertTrue(ArmingView.unconfinedWarning.contains("unlocked"))
        XCTAssertTrue(ArmingView.unconfinedWarning.contains("Stay nearby"))
        XCTAssertFalse(ArmingView.unconfinedWarning.contains("\u{2014}"), "no em-dash")
        let arming = try text("Malinois/Views/ArmingView.swift")
        let guided = try section(arming, from: "private var guidedAccessStep: some View {", to: "\n    }\n")
        let grace = try section(arming, from: "private var graceStep: some View {", to: "\n    }\n")
        XCTAssertTrue(guided.contains("ArmingView.unconfinedWarning") || guided.contains("Self.unconfinedWarning"))
        XCTAssertTrue(grace.contains("ArmingView.unconfinedWarning") || grace.contains("Self.unconfinedWarning"))
    }
}
