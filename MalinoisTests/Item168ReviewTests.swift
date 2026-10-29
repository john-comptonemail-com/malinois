//
//  Item168ReviewTests.swift
//  MalinoisTests
//
//  DeepSeek's open review of the full 1.8.2 folder at 8150c0a (BACKLOG 168; the owner: "go into 1.8.2"). Written
//  before the changes, red at that commit. Each screen is read as it shows itself (`shownOnScreen`); the record is
//  driven through a real launch that owes the automatic re-arm.
//  - deepseek-3 (step 44): with Guided Access on, the arming screen said "a snoop can't switch apps or power it off",
//    with it off that it would stop the same, and Settings' Require Guided Access caption that it stops "powering the
//    device off". Guided Access hides the power-off slider, but a forced restart, which nothing can block, still ends
//    the watch (README and SECURITY.md say so). The lines now name the slider, and with Guided Access on, the restart.
//  - deepseek-2 (step 45): the backup-off notice on Home and the arming screens, Home's free-tier row, the Event Log's
//    free-tier banner and the backup-off record said the events "stay" on the iPhone, though its own backups (iCloud
//    Backup, a computer's) can copy them. They now say that Malinois uploads nothing.
//  - deepseek-5 (step 46): the PIN that stops the automatic re-arm's countdown left no record, so the log could not
//    tell a stopped re-arm from one that never ran. It now leaves the cancelled countdown's record, pushed with the
//    session's iCloud authorization, so on Pro the owner's other devices hear of it as of a cancelled countdown.
//    Three controls, each pinning one part of the record's condition: a re-armed watch already live (after its
//    calibration review, or during it) ends as a disarm, and the owner's own cancelled countdown is still one record.
//  - deepseek-flash-3 (step 47; DeepSeek's look at the steps above; the owner: "approved"): four other lines still
//    said events "stay" on the device: those an event held back from iCloud shows (no verified account; recorded
//    while backup was off), Home's paused-iCloud line and the backup switch's caption. They now say what Malinois
//    does: it won't upload them. From its inventory, the iCloud-copies check's notices for another account ("They
//    stay on this phone") and an account it cannot confirm ("They are safe on this phone") now say what it did.
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item168ReviewTests: XCTestCase {
    private static let pendingReArmKey = "com.malinois.recovery.pendingReArm"
    private static let lastAttemptKey = "com.malinois.recovery.lastAt"

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem168")
    }

    override func tearDown() {
        TestIsolation.tearDown()   // the recovery flags go with it
        super.tearDown()
    }

    // MARK: - deepseek-3: what Guided Access blocks (step 44)

    /// With Guided Access on, the arming screen says it stops app switching and the power-off slider, and that a forced
    /// restart still ends the watch.
    func testTheArmingScreenWithGuidedAccessOnSaysAForcedRestartStillEndsTheWatch() throws {
        let rig = makeRig()
        rig.engine.simulateGuidedAccessForTesting(on: true)
        rig.engine.beginArming()
        defer { rig.engine.cancelArming() }
        let shown = try shownOnScreen(arming(rig)).shown
        let line = try XCTUnwrap(shown.first { $0.hasPrefix("The device is locked to Malinois") }, "\(shown)")
        XCTAssertTrue(line.contains("can't switch apps or use the power-off slider"), line)
        XCTAssertTrue(line.contains("A forced restart still ends the watch."), line)
    }

    /// With Guided Access off, the recommendation names the same two things it would stop.
    func testTheArmingScreenWithGuidedAccessOffNamesThePowerOffSlider() throws {
        let rig = makeRig()
        rig.engine.beginArming()
        defer { rig.engine.cancelArming() }
        let shown = try shownOnScreen(arming(rig)).shown
        let line = try XCTUnwrap(shown.first { $0.hasPrefix("It locks the device to Malinois") }, "\(shown)")
        XCTAssertTrue(line.contains("can't switch apps or use the power-off slider"), line)
    }

    /// Settings' Require Guided Access caption: it stops the app being swiped away and the power-off slider.
    func testRequireGuidedAccessNamesThePowerOffSlider() throws {
        let shown = try settingsShownOnScreen()
        let caption = try XCTUnwrap(shown.first { $0.hasPrefix("Refuse to arm unless Guided Access is on") }, "\(shown)")
        XCTAssertTrue(caption.contains("stops a snoop swiping the app away or using the power-off slider"), caption)
    }

    // MARK: - deepseek-2: what Malinois uploads (step 45)

    /// With iCloud backup off, Home and the arming screen say Malinois won't upload new events.
    func testTheBackupOffNoticeSaysMalinoisWontUploadNewEvents() throws {
        let rig = makeRig()
        XCTAssertTrue(rig.engine.setCloudBackup(false), "turned off the Settings way, while disarmed")
        let notice = "iCloud backup is off: Malinois won't upload new events."
        XCTAssertTrue(try shownOnScreen(home(rig)).shown.contains(notice), "Home")
        rig.engine.beginArming()
        defer { rig.engine.cancelArming() }
        XCTAssertTrue(try shownOnScreen(arming(rig)).shown.contains(notice), "the arming screen")
    }

    /// On the free tier, Home's iCloud row says Malinois uploads no evidence.
    func testHomesFreeTierRowSaysMalinoisUploadsNoEvidence() throws {
        let shown = try shownOnScreen(home(makeRig(tier: .free))).shown
        XCTAssertTrue(shown.contains("iCloud backup is Pro - Malinois uploads no evidence"), "\(shown)")
    }

    /// On the free tier, the Event Log's banner says how many events were not uploaded.
    func testTheEventLogsFreeTierBannerSaysTheEventsWereNotUploaded() throws {
        let rig = makeRig(tier: .free)
        rig.store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                            stateChange: "armed"))
        let shown = try shownOnScreen(NavigationStack { eventLog(rig) }).shown
        XCTAssertTrue(shown.contains("iCloud backup is Pro - 1 event(s) not uploaded"), "\(shown)")
    }

    /// The backup-off record, here and as another device reads it back, says that what is recorded while backup is off
    /// is never uploaded.
    func testTheBackupOffRecordSaysTheEventsAreNeverUploaded() throws {
        let expected = "iCloud backup turned off: events recorded while it is off are never uploaded"
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: Event.backupOffKind)
        XCTAssertEqual(event.sensorSummary, expected)
        let record = CloudExfiltrator.makeStateRecord(event, kind: Event.backupOffKind, deviceName: "iPhone Air")
        XCTAssertEqual(try XCTUnwrap(CloudExfiltrator.stateEvent(from: record)).sensorSummary, expected)
    }

    // MARK: - deepseek-5: the PIN that stops the automatic re-arm (step 46)

    /// The recovery countdown's pad calls `disarm()` once the PIN is right (`RecoveryCancelPINView`): the stop leaves one
    /// cancelled-arming record, and no "disarmed" one, since no watch went live.
    func testThePINThatStopsTheAutomaticReArmIsOnTheRecord() async {
        let rig = await launchOwingAReArm()
        let counting = await waitFor({ rig.engine.state == .arming }, timeout: 3)
        XCTAssertTrue(counting, "the owed re-arm counts down")
        XCTAssertTrue(rig.engine.armWasAutoRecovered)
        rig.engine.disarm()   // what the recovery countdown's pad does once the PIN is right
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertEqual(records(rig, "armingCancelled").count, 1, "\(rig.store.events.compactMap(\.stateChange))")
        XCTAssertTrue(records(rig, "disarmed").isEmpty, "no watch went live")
    }

    /// On Pro the stop goes to iCloud with the session's authorization, and so raises a cancelled countdown's alert on
    /// the owner's other devices.
    func testTheStopIsPushedAsACancelledCountdownIs() async {
        let rig = await launchOwingAReArm()
        let counting = await waitFor({ rig.engine.state == .arming }, timeout: 3)
        XCTAssertTrue(counting, "the owed re-arm counts down")
        rig.engine.disarm()
        let synced = await waitFor({ self.records(rig, "armingCancelled").first?.cloudSyncState == .synced }, timeout: 5)
        XCTAssertTrue(synced, "pushed: \(String(describing: records(rig, "armingCancelled").first?.cloudSyncState))")
        XCTAssertTrue(CloudExfiltrator.disarmSignalWanted(kind: "armingCancelled"), "the cancelled countdown's alert")
    }

    /// Control: once the re-armed watch is live, the PIN ends it as a disarm, recorded once, with no cancel beside it.
    func testADisarmAfterTheReArmedWatchWentLiveIsADisarmNotACancel() async {
        let rig = await launchOwingAReArm(grace: 0)
        let live = await waitFor({ rig.engine.state == .armed }, timeout: 5)
        XCTAssertTrue(live, "grace 0 + calibration + review reach .armed")
        rig.engine.disarm()
        XCTAssertEqual(records(rig, "disarmed").count, 1)
        XCTAssertTrue(records(rig, "armingCancelled").isEmpty, "\(rig.store.events.compactMap(\.stateChange))")
    }

    /// Control: a re-armed watch disarmed during its calibration review, its sensors already live and "armed" on the
    /// record, is a disarm too, though the screen still calibrates: one "disarmed" record and no cancel.
    func testADisarmDuringTheReArmedWatchsCalibrationReviewIsADisarmNotACancel() async {
        let rig = await launchOwingAReArm(grace: 0, review: 30)   // long enough to act in (deepseek-flash-2)
        let reviewing = await waitFor({ rig.engine.showingCalibrationReview }, timeout: 5)
        XCTAssertTrue(reviewing, "the review is showing")
        XCTAssertEqual(rig.engine.state, .calibrating)
        XCTAssertNotNil(rig.engine.armedSince, "the sensors are live")
        rig.engine.disarm()
        XCTAssertEqual(records(rig, "disarmed").count, 1)
        XCTAssertTrue(records(rig, "armingCancelled").isEmpty, "\(rig.store.events.compactMap(\.stateChange))")
    }

    /// Control: the owner's own countdown, cancelled, is one cancelled-arming record: `cancelArming` writes it, and the
    /// `disarm()` it calls adds none, since only an automatic re-arm is recorded there.
    func testTheOwnersCancelledCountdownIsOneRecord() async {
        let rig = makeRig()
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        let counting = await waitFor({ rig.engine.state == .arming }, timeout: 5)
        XCTAssertTrue(counting, "counting down")
        XCTAssertFalse(rig.engine.armWasAutoRecovered, "the owner's own arm")
        rig.engine.cancelArming()
        XCTAssertEqual(rig.engine.state, .disarmed)
        XCTAssertEqual(records(rig, "armingCancelled").count, 1, "\(rig.store.events.compactMap(\.stateChange))")
    }

    // MARK: - deepseek-flash-3: the other "stay" lines (step 47)

    /// What an event held back from iCloud shows (the Event Log's banner, the event's detail): with no verified
    /// account, and when recorded while backup was off, Malinois won't upload it.
    func testTheHeldEventsLinesSayMalinoisWontUploadThem() {
        XCTAssertEqual(CloudEnrollment.UploadHoldReason.unknownAccount.explanation,
                       "These events have no verified iCloud account. Malinois won't upload them, and Retry can't. "
                       + "Use Share on an event to save a copy elsewhere.")
        XCTAssertEqual(CloudEnrollment.UploadHoldReason.backupOff.explanation,
                       "These events were recorded while iCloud backup was off. Malinois will never upload them, even "
                       + "after backup is turned back on. Use Share on an event to save a copy elsewhere.")
    }

    /// Home's line while new events are tied to no account: Malinois won't upload what was recorded before then.
    func testHomesPausedLineSaysMalinoisWontUploadEventsRecordedBeforeThen() {
        XCTAssertEqual(HomeView.iCloudPausedNotice, "iCloud is paused. Verify iCloud access in Settings to back up new "
                       + "events; Malinois won't upload events recorded before then.")
    }

    /// Settings' backup caption: what is recorded while backup is off is never uploaded, even once it is back on.
    func testTheBackupCaptionSaysEventsRecordedWhileOffAreNeverUploaded() throws {
        let shown = try settingsShownOnScreen()
        let caption = try XCTUnwrap(shown.first { $0.hasPrefix("Uploads this iPhone's events") }, "\(shown)")
        XCTAssertTrue(caption.contains("Off: nothing new uploads (a file already being sent finishes), and events "
                                       + "recorded while it is off are never uploaded, even after you turn it back on."),
                      caption)
        XCTAssertFalse(caption.contains("stay on this iPhone"), caption)
    }

    /// Step 47's inventory (the owner: "lines approved"): when iCloud's copies are gone and the phone is signed into
    /// another account, Home says Malinois uploaded none of them there and they are still on this phone.
    func testTheCopiesCheckSaysMalinoisUploadedNoneToAnotherAccount() async throws {
        let engine = try await engineMissingItsCopies(signedInto: "someone else")
        await engine.checkCloudCopies()
        XCTAssertEqual(engine.cloudResetNotice, "This phone's records are not in the iCloud account it is signed into, "
                       + "which is not the one it used before. Malinois uploaded none of them to this account; they are "
                       + "still on this phone.")
    }

    /// And when the account cannot be confirmed: they are still on this phone, rather than "safe" there.
    func testTheCopiesCheckSaysTheRecordsAreStillOnThisPhone() async throws {
        let engine = try await engineMissingItsCopies(signedInto: nil)
        await engine.checkCloudCopies()
        XCTAssertEqual(engine.cloudResetNotice, "iCloud no longer holds this phone's records. They are still on this phone.")
    }

    // MARK: - Rig

    /// A disarmed install with its settings resolved; Guided Access not required.
    private func makeRig(tier: ProEntitlements.Status = .trial) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: tier)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, settings: settings, store: store, cloud: cloud, entitlements: entitlements)
    }

    /// A launch that owes the automatic re-arm (its last attempt ten minutes ago), on a trial install verified on
    /// "account-A" whose saves land at once. The recovery runs once the Pro check resolves, as on the phone, and counts
    /// down `grace` seconds, the owner's setting. `review`: the calibration review's length, for a test that acts during
    /// it (the fast timing holds it 0.1 s, which a late poll can miss: item 168's deepseek-flash-2).
    private func launchOwingAReArm(grace: Int = 60, review: TimeInterval? = nil) async -> Rig {
        UserDefaults.standard.set(true, forKey: Self.pendingReArmKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970 - 600, forKey: Self.lastAttemptKey)
        let root = EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("enrollment-168/state.json"),
                                         authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = { "account-A" }
        cloud.saveAttemptForTesting = { _ in }
        let settings = AppSettings()
        settings.gracePeriodSeconds = grace
        settings.responseMode = .alert
        let store = EventStore()
        let entitlements = ProEntitlements.unresolvedForTesting()
        var timing = EngineCharacterizationTests.fastTiming
        if let review { timing.calibrationReview = review }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: timing, thermalState: { .nominal }))
        let enrolled = await cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled, "the verification succeeded")
        await engine.cloudAccessVerified()
        entitlements.resolveForTesting(as: .trial)
        return Rig(engine: engine, settings: settings, store: store, cloud: cloud, entitlements: entitlements)
    }

    /// A Pro install verified for "owner" whose five synced records iCloud no longer holds, signed into `account` now
    /// (nil: iOS names none), driven through the engine's stand-ins as item 87's tests do.
    private func engineMissingItsCopies(signedInto account: String?) async throws -> MonitoringEngine {
        let root = EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("enrollment-168-\(UUID().uuidString)/state.json"),
                                         authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "owner", resolve: { "owner" })
        try XCTSkipUnless(verified, "the enrollment could not be written")
        let store = EventStore()
        for minutes in 1...5 {
            let at = Date().addingTimeInterval(-Double(minutes) * 60)
            let event = Event(startDate: at, endDate: at, triggeredSensors: [.touch], cloudSyncState: .synced)
            enrollment.registerLocalEvent(event)
            store.add(event)
        }
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(enrollment: enrollment), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.cloudAccountForTesting = account
        engine.cloudPresenceForTesting = { _ in [] }   // iCloud holds none of them
        return engine
    }

    private func records(_ rig: Rig, _ kind: String) -> [Event] {
        rig.store.events.filter { $0.stateChange == kind }
    }

    /// Waits for `condition`, yielding the main actor meanwhile (the work under test runs only while this awaits).
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func home(_ rig: Rig) -> some View {
        HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)
    }

    private func arming(_ rig: Rig) -> some View {
        ArmingView()
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
            .environmentObject(rig.settings)
    }

    private func eventLog(_ rig: Rig) -> some View {
        EventLogView()
            .environmentObject(rig.store)
            .environmentObject(rig.engine)
            .environmentObject(rig.cloud)
            .environmentObject(rig.entitlements)
    }
}
