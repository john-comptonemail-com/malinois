//
//  Item153SettingsRecordsTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-09 and item 155's A15 (1.8.2's step 22; the owner's scope, all seven: "agree all"). Item 91's
//  records (ADR 0019) covered the tripwires, the Guided Access requirement, the other devices' alerts and the jamming
//  response; seven settings that can make the next session less sensitive or silent changed with no record: the
//  response mode, sensitivity, the grace period, the camera's battery mode, illumination, Face ID unlock and iCloud
//  storage's retention. Each change now leaves one record the same way (when Settings closes and at every arm): "set
//  to" a value, or switched on or off, in the order of the Settings screen. A baseline recorded before 1.8.2 lacks them:
//  launch adopts them without a record, so the first visit's change is still caught. The log's words are drafts for the
//  owner. Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
import CloudKit
import UIKit
@testable import Malinois

@MainActor
final class Item153SettingsRecordsTests: XCTestCase {

    nonisolated private static let baselineKey = "com.malinois.protection.recorded"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Settings")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A snapshot with all seven at a value: the defaults, unless a test says otherwise.
    private func snapshot(response: ResponseMode = .alert, motion: Sensitivity = .medium, grace: Int = 15,
                          readiness: CameraReadiness = .auto, illumination: IlluminationMode = .auto,
                          biometric: Bool = true, retention: CloudRetention = .months12) -> ProtectionSettings {
        var levels = Dictionary(uniqueKeysWithValues: SensorType.allCases.map { ($0, Sensitivity.medium) })
        levels[.motion] = motion
        return ProtectionSettings(tripwires: [.motion, .camera], requireGuidedAccess: true, otherDeviceAlerts: true,
                                  jammingResponse: true, sensitivities: levels, gracePeriodSeconds: grace,
                                  responseMode: response, cameraReadiness: readiness, illumination: illumination,
                                  biometricUnlock: biometric, cloudRetention: retention)
    }

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
    }

    /// A trial install with no grace period and Guided Access not required, launched on `settings`.
    private func makeRig(_ settings: AppSettings = AppSettings(), configure: (AppSettings) -> Void = { _ in }) -> Rig {
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, settings: settings, store: store)
    }

    private func settingsRecords(_ rig: Rig) -> [String] {
        rig.store.events.compactMap(\.stateChange).filter { $0.hasPrefix("setting") }
    }

    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced, stateChange: kind)
    }

    private func words(_ kind: String) -> String { stateEvent(kind).sensorSummary }

    /// One of each, in the order of the Settings screen.
    private let everyKind = [
        "settingSet.responseMode.stealth", "settingSet.sensitivity.motion.low", "settingSet.gracePeriod.60",
        "settingSet.cameraReadiness.battery", "settingSet.illumination.off", "settingOff.biometricUnlock",
        "settingSet.cloudRetention.months1",
    ]

    // MARK: - The rule

    /// Each of the seven is named once when it changes, in the order of the Settings screen; restoring is named too,
    /// and nothing changed names nothing.
    func testEachOfTheSevenIsNamedOnceInTheScreensOrder() {
        let before = snapshot()
        let after = snapshot(response: .stealth, motion: .low, grace: 60, readiness: .batterySaver, illumination: .off,
                             biometric: false, retention: .months1)
        XCTAssertEqual(ProtectionSettings.changeKinds(from: before, to: after), everyKind)
        XCTAssertEqual(ProtectionSettings.changeKinds(from: after, to: before), [
            "settingSet.responseMode.alert", "settingSet.sensitivity.motion.medium", "settingSet.gracePeriod.15",
            "settingSet.cameraReadiness.auto", "settingSet.illumination.auto", "settingOn.biometricUnlock",
            "settingSet.cloudRetention.months12",
        ])
        XCTAssertEqual(ProtectionSettings.changeKinds(from: before, to: before), [])
    }

    /// Sensitivity is named only for the tripwires Settings offers it for: Power and Proximity are binary.
    func testSensitivityIsNamedOnlyWhereSettingsOffersIt() {
        var levels = snapshot().sensitivities ?? [:]
        levels[.power] = .high
        levels[.proximity] = .low
        levels[.audio] = .high
        var after = snapshot()
        after.sensitivities = levels
        XCTAssertEqual(ProtectionSettings.changeKinds(from: snapshot(), to: after), ["settingSet.sensitivity.audio.high"])
    }

    /// A baseline recorded before 1.8.2 lacks the seven: none of them is compared with it, so nothing is invented.
    func testABaselineWithoutTheSevenNamesNoneOfThem() {
        let old = ProtectionSettings(tripwires: [.motion, .camera], requireGuidedAccess: true, otherDeviceAlerts: true,
                                     jammingResponse: true)
        XCTAssertEqual(ProtectionSettings.changeKinds(from: old, to: snapshot(response: .stealth)), [])
    }

    // MARK: - The words (drafts for the owner)

    func testTheLogSaysWhatChanged() {
        XCTAssertEqual(words("settingSet.responseMode.stealth"), "Response mode set to Stealth (covert) in Settings")
        XCTAssertEqual(words("settingSet.sensitivity.motion.low"), "Device motion sensitivity set to Low in Settings")
        XCTAssertEqual(words("settingSet.sensitivity.audio.high"), "Sound sensitivity set to High in Settings")
        XCTAssertEqual(words("settingSet.gracePeriod.60"), "Arming grace period set to 60 s in Settings")
        XCTAssertEqual(words("settingSet.cameraReadiness.battery"), "Camera battery mode set to Battery saver in Settings")
        XCTAssertEqual(words("settingSet.illumination.off"), "Illumination set to Off in Settings")
        XCTAssertEqual(words("settingOn.biometricUnlock"), "Face ID or Touch ID unlock switched on in Settings")
        XCTAssertEqual(words("settingOff.biometricUnlock"), "Face ID or Touch ID unlock switched off",
                       "not \"in Settings\": it also switches off by itself when the enrolled faces or fingers change")
        XCTAssertEqual(words("settingSet.cloudRetention.months1"),
                       "iCloud photo and video storage set to Auto-delete after 1 month in Settings")
        for kind in everyKind { XCTAssertFalse(words(kind).contains("—"), "no em-dash on screen: \(kind)") }
    }

    // MARK: - iCloud, alerts and the log

    /// The records come back from iCloud like item 91's; a malformed or unknown value is dropped, not shown.
    func testTheRecordsComeBackFromICloudAndAMalformedOneIsDropped() {
        for kind in everyKind + ["settingSet.gracePeriod.120", "settingSet.sensitivity.vision.high"] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, kind, "read back: \(kind)")
        }
        for kind in ["settingSet.responseMode.loud", "settingSet.gracePeriod.+5", "settingSet.gracePeriod.-5",
                     "settingSet.gracePeriod.ten", "settingSet.sensitivity.power.low", "settingSet.sensitivity.motion",
                     "settingSet.sensitivity.motion.low.extra", "settingSet.illumination", "settingSet.flux.on",
                     "settingOn.flux"] {
            let record = CloudExfiltrator.makeStateRecord(stateEvent(kind), kind: kind, deviceName: "iPhone Air")
            XCTAssertNil(CloudExfiltrator.stateEvent(from: record), "dropped: \(kind)")
        }
    }

    /// Like the other audit records: no alert on another device or the watch, and the settings icon in the log.
    func testTheRecordsNeverAlertAndShowTheSettingsIcon() {
        for kind in everyKind {
            XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: kind), "no alert: \(kind)")
            XCTAssertEqual(EventRow.placeholderIcon(for: kind), "slider.horizontal.3", "the settings icon: \(kind)")
        }
        XCTAssertTrue(WatchAlertRelay.alerts(for: everyKind.map(stateEvent), alertsOn: true, proActive: true).isEmpty,
                      "nothing relayed to the watch")
    }

    // MARK: - The engine

    /// The response mode set to Stealth is on the record when Settings closes, once.
    func testAResponseModeChangeIsRecordedWhenSettingsCloses() {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()   // the first look adopts the settings as they are
        rig.settings.responseMode = .stealth
        rig.engine.recordProtectionChanges()   // Settings closes
        XCTAssertEqual(settingsRecords(rig), ["settingSet.responseMode.stealth"])
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingSet.responseMode.stealth"], "nothing new")
    }

    /// All seven changed in one visit leave seven records.
    func testAllSevenChangedInOneVisitLeaveSevenRecords() {
        let rig = makeRig { $0.biometricUnlock = true }
        rig.engine.recordProtectionChanges()
        rig.settings.responseMode = .stealth
        rig.settings.sensitivities[.motion] = .low
        rig.settings.gracePeriodSeconds = 60
        rig.settings.cameraReadiness = .batterySaver
        rig.settings.illumination = .off
        rig.settings.biometricUnlock = false
        rig.settings.cloudRetention = .months1
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(Set(settingsRecords(rig)), Set(everyKind))
        XCTAssertEqual(settingsRecords(rig).count, 7)
    }

    /// A change Settings never reported (the app ended with Settings open) is on the record at the next arm.
    func testAnArmRecordsAGracePeriodChange() {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()
        rig.settings.gracePeriodSeconds = 60
        rig.engine.beginArming()
        XCTAssertEqual(settingsRecords(rig), ["settingSet.gracePeriod.60"])
        rig.engine.disarm()
    }

    /// The update's first launch: the baseline 1.8.1 recorded lacks the seven, and launch adopts them without a record,
    /// before Settings can edit them, so the first visit's change is caught (ADR 0019's first look).
    func testABaselineFrom181AdoptsTheSevenAtLaunch() throws {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let recorded181 = ProtectionSettings(tripwires: settings.enabledSensors,
                                             requireGuidedAccess: settings.requireGuidedAccess,
                                             otherDeviceAlerts: settings.notifyOtherDevices,
                                             jammingResponse: settings.jammingResponse)
        UserDefaults.standard.set(try JSONEncoder().encode(recorded181), forKey: Self.baselineKey)
        let rig = makeRig(settings)   // the update's first launch
        XCTAssertEqual(settingsRecords(rig), [], "launch adds no row")
        rig.settings.responseMode = .stealth
        rig.engine.recordProtectionChanges()   // the first Settings visit closes
        XCTAssertEqual(settingsRecords(rig), ["settingSet.responseMode.stealth"], "the first visit's change is caught")
    }
}
