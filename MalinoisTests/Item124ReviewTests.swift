//
//  Item124ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 124 (1.8, BACKLOG 128): the smaller findings of the top-down review of 1.7 (item 120),
//  each written before its fix and red at that commit.
//
//  F15: Share's sentence read "Malinois detected tampering on <date> - <summary> triggered." for every
//  row, status entries included ("Monitoring armed triggered"). A status entry or an interruption
//  record is now a log entry, in the owner's approved words (2026-10-17): "Malinois log entry on
//  <date>: <summary>." Tamper events keep their sentence.
//
//  F10: the watch relay sent tamper events and first-hand disarms only, while iCloud also alerts on a
//  cancelled countdown, so for an owner whose only other device is the watch, a countdown someone
//  else cancelled raised no alert anywhere. The relay now follows iCloud's own rule.
//
//  F18: the alert extension reads nothing since 1.5.1, yet kept the iCloud entitlement and compiled
//  four of the app's files. It now holds neither (it still parses CloudKit's push to choose Time
//  Sensitive, which needs no entitlement). The Time Sensitive device check follows on TestFlight.
//
//  The Touch gaps (F6's related findings): a tap on the REC badge's corner of the armed screen never
//  reached the Touch layer, and the 6-second "Calibrated" card, during which the engine already treats
//  a trip as live, had no Touch layer at all.
//
//  F12: settings that cannot be read reset to defaults, which turned iCloud backup and cross-device
//  alerts back on, even after the owner had turned backup off. The owner's ruling (2026-10-17, option
//  B): keep the owner's choices where the damaged settings still show them, otherwise backup off.
//
//  F14: arming waited for StoreKit's walk of the purchases, with no time limit, before Early-Access
//  settled, though Early-Access needs no StoreKit. It now settles first.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

final class Item124ReviewTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item124ReviewTests")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - F15: Share's sentence

    private static let when = "Oct 17, 2026 at 9:15 PM"

    func testShareCallsAStatusEntryALogEntry() {
        let armed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced,
                          stateChange: "armed")
        XCTAssertEqual(armed.shareSentence(timestamp: Self.when), "Malinois log entry on Oct 17, 2026 at 9:15 PM: Monitoring armed.")
        let backupOff = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                              stateChange: "backupOff")
        XCTAssertEqual(backupOff.shareSentence(timestamp: Self.when),
                       "Malinois log entry on Oct 17, 2026 at 9:15 PM: iCloud backup turned off: events recorded while it is off are never uploaded.")
    }

    func testShareCallsAnInterruptionRecordALogEntry() {
        let restarted = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .pending,
                              interrupted: true, interruptionCause: InterruptionCause.rebooted.rawValue)
        XCTAssertEqual(restarted.shareSentence(timestamp: Self.when),
                       "Malinois log entry on Oct 17, 2026 at 9:15 PM: Monitoring interrupted: the device restarted while armed.")
    }

    /// Guard: a tamper event keeps its sentence, with the recording's length when it has one.
    func testShareStillCallsATamperEventDetectedTampering() {
        let trip = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        XCTAssertEqual(trip.shareSentence(timestamp: Self.when),
                       "Malinois detected tampering on Oct 17, 2026 at 9:15 PM - \(trip.sensorSummary) triggered.")
        let clip = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], primaryCamera: "front",
                         primaryDuration: 5, cloudSyncState: .synced)
        XCTAssertEqual(clip.shareSentence(timestamp: Self.when),
                       "Malinois detected tampering on Oct 17, 2026 at 9:15 PM - \(clip.sensorSummary) triggered. Recording: F 5.0s.")
    }

    // MARK: - F10: a cancelled countdown reaches the watch

    /// The relay's rule is iCloud's: a cancelled countdown is a disarm alert, as `disarmSignalWanted`
    /// says; a plain arm, a status line and another device's records still send nothing.
    func testTheWatchRelaySendsACancelledCountdownAsICloudDoes() {
        XCTAssertTrue(CloudExfiltrator.disarmSignalWanted(kind: "armingCancelled"), "iCloud alerts on it")
        let cancelled = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], stateChange: "armingCancelled")
        let armed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], stateChange: "armed")
        let mirrored = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], stateChange: "armingCancelled",
                             sourceDevice: "iPad mini")
        let alerts = WatchAlertRelay.alerts(for: [cancelled, armed, mirrored], alertsOn: true, proActive: true)
        XCTAssertEqual(alerts.map(\.kind), [.disarm])
        XCTAssertEqual(alerts.map(\.eventID), [cancelled.id])
    }

    /// The real path: a countdown cancelled on the phone writes its status entry, and the relay
    /// watching the log sends the disarm alert to the watch.
    @MainActor
    func testACountdownCancelledOnThePhoneReachesTheWatch() {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        settings.notifyOtherDevices = true
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        var sent: [WatchAlertMessage] = []
        let relay = WatchAlertRelay(store: store, settings: settings, entitlements: entitlements, send: { sent.append($0) })
        relay.start()
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .arming }, timeout: 5), "counting down")
        engine.cancelArming()
        XCTAssertTrue(store.events.contains { $0.stateChange == "armingCancelled" }, "the cancel is on the record")
        XCTAssertEqual(sent.map(\.kind), [.disarm], "the watch hears nothing of a cancelled countdown")
    }

    // MARK: - F18: the alert extension

    /// No iCloud entitlement: the extension reads no records (since 1.5.1) and parsing a push needs none.
    func testTheAlertExtensionHoldsNoICloudEntitlement() throws {
        let entitlements = try text("MalinoisNotificationService/MalinoisNotificationService.entitlements")
        XCTAssertFalse(entitlements.contains("com.apple.developer.icloud"), entitlements)
    }

    /// It compiles its own files only (since 1.8.2 its own and the burst rule's), not the app's model files it no
    /// longer uses. Read from the project file, the one place that says what a target compiles.
    func testTheAlertExtensionCompilesOnlyItsOwnFile() throws {
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        let start = try XCTUnwrap(project.range(of: "71B2C3D4E5F6000000000041 /* Sources */ = {"),
                                  "the alert extension's Sources phase")
        let phase = project[start.upperBound...].prefix { $0 != "}" }
        let files = phase.split(separator: "\n").filter { $0.contains(" in Sources */") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        // Since 1.8.2 also the burst rule (`AlertBurst`, ADR 0061): pure, no app, model or cloud code (item 169's codex-4).
        let names = files.compactMap { line in ["NotificationService.swift", "AlertBurst.swift"].first { line.contains($0) } }
        XCTAssertEqual(files.count, 2, "the extension compiles: \(files)")
        XCTAssertEqual(Set(names), ["NotificationService.swift", "AlertBurst.swift"], "\(files)")
    }

    // MARK: - The Touch gaps

    /// The armed screen's REC badge lies over the black Touch layer; it now lets touches through to it,
    /// as the warning and the capture flash above the same layer do. SwiftUI shows a unit test no
    /// touches or hit-testing, so this reads the badge's overlay in the source; the build's device check
    /// taps the badge's corner.
    func testTheArmedScreensRECBadgeLetsTouchesThroughToTheTouchLayer() throws {
        let armed = try text("Malinois/Views/ArmedView.swift")
        let badge = try XCTUnwrap(armed.range(of: "if camera.isRecordingActive && !engine.disarmEntryActive {"),
                                  "the armed screen's REC badge")
        let overlay = armed[badge.upperBound...].prefix(400)
        XCTAssertTrue(overlay.contains(".allowsHitTesting(false)"), "the REC badge catches taps meant for Touch")
    }

    /// The "Calibrated" card now has the Touch layer the armed screen has, laid out over it only while
    /// the card shows (the engine already treats a trip then as live); the countdown has none.
    @MainActor
    func testTheCalibratedCardHasTheArmedScreensTouchLayer() throws {
        var timing = EngineCharacterizationTests.fastTiming
        timing.calibrationReview = 60
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements, timing: timing))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.showingCalibrationReview }, timeout: 5), "the Calibrated card")
        let card = ArmingView().environmentObject(engine).environmentObject(entitlements).environmentObject(settings)
        XCTAssertTrue(try shownTexts(on: card).contains(Self.touchLayer), "the Calibrated card has no Touch layer")
        engine.cancelArming()
    }

    /// Guard: the armed screen has had its Touch layer all along, and the countdown has none.
    @MainActor
    func testTheArmedScreenHasTheTouchLayerAndTheCountdownNone() throws {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let countdown = ArmingView().environmentObject(engine).environmentObject(entitlements).environmentObject(settings)
        XCTAssertFalse(try shownTexts(on: countdown).contains(Self.touchLayer), "the countdown records touches")
        engine.cancelArming()
        settings.gracePeriodSeconds = 0
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .armed }, timeout: 5), "armed")
        let armed = ArmedView().environmentObject(engine).environmentObject(settings).environmentObject(CameraController())
        XCTAssertTrue(try shownTexts(on: armed).contains(Self.touchLayer), "the armed screen has no Touch layer")
        engine.disarm()
    }

    private static let touchLayer = "Touch tripwire"

    /// The texts the reporting views of `view` show when it is laid out on a 17 Pro (item 82's
    /// pattern), read before the window closes.
    @MainActor
    private func shownTexts<V: View>(on view: V) throws -> [String] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let recorder = OnScreenRecorder()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
        return recorder.shown
    }

    @MainActor
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    // MARK: - F12: iCloud backup after a settings reset (the owner's option B)

    private static let settingsKey = "com.malinois.settings"

    /// Runs `body` with `blob` as the stored settings, then puts back what was there and removes the
    /// stash the reset leaves.
    private func withStoredSettings(_ blob: String, _ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.data(forKey: Self.settingsKey)
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: Self.settingsKey) }
            else { UserDefaults.standard.removeObject(forKey: Self.settingsKey) }
            UserDefaults.standard.dictionaryRepresentation().keys
                .filter { $0.hasPrefix(Self.settingsKey + ".corrupt-") }
                .forEach { UserDefaults.standard.removeObject(forKey: $0) }
        }
        UserDefaults.standard.set(Data(blob.utf8), forKey: Self.settingsKey)
        try body()
    }

    /// The usual reset: one field this build cannot read (an older build, after a newer one stored a
    /// value it does not know). The owner's iCloud choices are still readable, so they stand.
    @MainActor   // `AppSettings.load()` runs on the main actor since 1.8.1 (ADR 0055)
    func testASettingsResetKeepsTheOwnersICloudChoicesWhereTheyCanBeRead() {
        withStoredSettings(#"{"gracePeriodSeconds":"not a number","cloudBackup":false,"notifyOtherDevices":false}"#) {
            let loaded = AppSettings.load()
            XCTAssertTrue(AppSettings.loadWasReset, "still a reset, still announced")
            XCTAssertFalse(loaded.cloudBackup, "backup was off and stays off")
            XCTAssertFalse(loaded.notifyOtherDevices, "alerts were off and stay off")
        }
        withStoredSettings(#"{"gracePeriodSeconds":"not a number","cloudBackup":true,"notifyOtherDevices":true}"#) {
            let loaded = AppSettings.load()
            XCTAssertTrue(loaded.cloudBackup, "backup was on and stays on")
            XCTAssertTrue(loaded.notifyOtherDevices)
        }
    }

    /// Real damage: the switch cannot be read (not JSON, missing, or not a yes or no). Backup is off,
    /// failing closed: nothing uploads that the owner may have chosen to keep. Home's backup-off notice
    /// says so. Cross-device alerts keep their default.
    @MainActor   // `AppSettings.load()` runs on the main actor since 1.8.1 (ADR 0055)
    func testASettingsResetTurnsBackupOffWhereItsChoiceCannotBeRead() {
        for blob in ["not json at all", #"{"gracePeriodSeconds":"x"}"#, #"{"gracePeriodSeconds":"x","cloudBackup":1}"#,
                     #"{"gracePeriodSeconds":"x","cloudBackup":"yes"}"#] {
            withStoredSettings(blob) {
                let loaded = AppSettings.load()
                XCTAssertTrue(AppSettings.loadWasReset, blob)
                XCTAssertFalse(loaded.cloudBackup, "backup on after an unreadable reset: \(blob)")
                XCTAssertTrue(loaded.notifyOtherDevices, blob)
            }
        }
    }

    /// Guard: settings that decode load as they are, with no reset (and older settings without the
    /// switch keep uploading, as since item 115).
    @MainActor   // `AppSettings.load()` runs on the main actor since 1.8.1 (ADR 0055)
    func testSettingsThatDecodeLoadAsTheyAre() throws {
        let settings = AppSettings()
        settings.cloudBackup = false
        let saved = try XCTUnwrap(String(bytes: try JSONEncoder().encode(settings), encoding: .utf8))
        withStoredSettings(saved) { XCTAssertFalse(AppSettings.load().cloudBackup) }
        var older = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        older.removeValue(forKey: "cloudBackup")
        let olderBlob = try XCTUnwrap(String(bytes: try JSONSerialization.data(withJSONObject: older), encoding: .utf8))
        withStoredSettings(olderBlob) { XCTAssertTrue(AppSettings.load().cloudBackup) }
    }

    /// The real path: after a reset that turned backup off, a new event is kept on this iPhone and
    /// may not upload.
    @MainActor
    func testAfterAnUnreadableResetANewEventStaysOnThisIPhone() {
        withStoredSettings("not json at all") {
            let settings = AppSettings.load()
            let store = EventStore()
            let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                              camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                              timing: EngineCharacterizationTests.fastTiming))
            let trip = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
            store.add(trip)
            let kept = store.events.first { $0.id == trip.id }
            XCTAssertEqual(kept?.keptLocal, true, "the event would upload")
            XCTAssertFalse(engine.backupAllows(trip))
        }
    }

    // MARK: - F14: Early-Access before StoreKit

    /// While the program is open, Pro settles from Early-Access alone, before StoreKit answers, so arming
    /// is not held behind StoreKit's walk; a purchase it finds afterwards still counts.
    @MainActor
    func testEarlyAccessSettlesBeforeStoreKitAnswers() async {
        XCTAssertTrue(ProEntitlements.earlyAccessProgramOpen, "this build's program is open")
        for purchase in [false, true] {
            let entitlements = ProEntitlements.unresolvedForTesting()
            let gate = TestFlag()   // opened when StoreKit's stand-in may answer
            entitlements.purchaseCheckForTesting = {
                while !gate.value { try? await Task.sleep(for: .milliseconds(5)) }
                return purchase
            }
            let refresh = Task { await entitlements.refresh() }
            let deadline = Date().addingTimeInterval(3)
            while !entitlements.hasResolved && Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(entitlements.hasResolved, "Pro waits for StoreKit's walk (purchase \(purchase))")
            XCTAssertEqual(entitlements.status, .earlyAccess, "purchase \(purchase)")
            gate.value = true
            await refresh.value
            XCTAssertEqual(entitlements.status, purchase ? .pro : .earlyAccess, "after StoreKit answered")
        }
    }

    // MARK: - Item 155's A8 (step 23): the Early-Access marker precedes the purchase return

    /// Codex's P8. An install with a verified purchase and no Early-Access marker, while the program is open, becomes a
    /// member too: the marker is written before the purchase makes the status Pro. Red at the step's red commit: the
    /// refresh returned on the purchase first, and the marker was never written.
    @MainActor func testAPurchasedInstallBecomesAnEarlyAccessMember() async throws {
        KeychainService.clearEarlyAccessMemberForTesting()
        try XCTSkipUnless(KeychainService.markEarlyAccessMember(), "the Keychain is unavailable on this build")
        KeychainService.clearEarlyAccessMemberForTesting()
        defer { KeychainService.clearEarlyAccessMemberForTesting() }
        let entitlements = ProEntitlements.unresolvedForTesting()
        entitlements.purchaseCheckForTesting = { true }
        await entitlements.refresh()
        XCTAssertEqual(entitlements.status, .pro)
        XCTAssertTrue(KeychainService.earlyAccessMember, "a purchaser is a member too")
    }
}
