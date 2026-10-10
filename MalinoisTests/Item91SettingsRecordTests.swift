//
//  Item91SettingsRecordTests.swift
//  MalinoisTests
//
//  BACKLOG 91 (review 1's F3 (a), queued for 1.4 on the owner's go 2026-09-06; ruled again
//  2026-09-28 as the 1.4 review's A1): a PIN-holder could weaken the owner's next session in
//  Settings (switch the Camera tripwire off, drop the Guided Access requirement, silence the
//  other devices' alerts, turn the jamming response off) and nothing recorded it. Each change
//  now writes an audit record, when Settings closes and at every arm. Written before the change,
//  red at that commit.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item91SettingsRecordTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem91")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func protection(_ tripwires: Set<SensorType> = [.motion, .camera], ga: Bool = true,
                            alerts: Bool = true, jamming: Bool = true) -> ProtectionSettings {
        ProtectionSettings(tripwires: tripwires, requireGuidedAccess: ga, otherDeviceAlerts: alerts, jammingResponse: jamming)
    }

    private struct Rig {
        let engine: MonitoringEngine
        let settings: AppSettings
        let store: EventStore
    }

    private func makeRig(configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
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

    // MARK: - The rule

    /// Each change is named once, weakening or restoring, in a fixed order: the tripwires in the
    /// app's own order, then Guided Access, the other devices' alerts, the jamming response.
    func testEachChangeIsNamedOnce() {
        let before = protection([.motion, .audio, .camera])
        let after = protection([.motion, .vision], ga: false, alerts: false, jamming: false)
        XCTAssertEqual(ProtectionSettings.changeKinds(from: before, to: after), [
            "settingOff.audio", "settingOn.vision", "settingOff.camera",
            "settingOff.requireGuidedAccess", "settingOff.otherDeviceAlerts", "settingOff.jammingResponse",
        ])
        XCTAssertEqual(ProtectionSettings.changeKinds(from: after, to: before), [
            "settingOn.audio", "settingOff.vision", "settingOn.camera",
            "settingOn.requireGuidedAccess", "settingOn.otherDeviceAlerts", "settingOn.jammingResponse",
        ])
    }

    /// Nothing changed names nothing, and Touch never appears: it cannot be switched off.
    func testNoChangeNamesNothingAndTouchNeverAppears() {
        XCTAssertEqual(ProtectionSettings.changeKinds(from: protection(), to: protection()), [])
        XCTAssertEqual(ProtectionSettings.changeKinds(from: protection([.motion]), to: protection([.motion, .touch])), [])
    }

    /// The log says what changed, in words, without an em-dash.
    func testTheLogSaysWhatChanged() {
        func words(_ kind: String) -> String {
            Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .localOnly, stateChange: kind)
                .sensorSummary
        }
        XCTAssertEqual(words("settingOff.camera"), "Camera switched off in Settings")
        XCTAssertEqual(words("settingOn.camera"), "Camera switched on in Settings")
        XCTAssertEqual(words("settingOff.audio"), "Sound tripwire switched off in Settings")
        XCTAssertEqual(words("settingOn.motion"), "Device motion tripwire switched on in Settings")
        XCTAssertEqual(words("settingOff.requireGuidedAccess"), "Guided Access no longer required, in Settings")
        XCTAssertEqual(words("settingOn.requireGuidedAccess"), "Guided Access required again, in Settings")
        XCTAssertEqual(words("settingOff.otherDeviceAlerts"), "Alerts to your other devices switched off in Settings")
        XCTAssertEqual(words("settingOff.jammingResponse"), "Jamming response switched off in Settings")
        for kind in ["settingOff.camera", "settingOn.requireGuidedAccess", "settingOff.otherDeviceAlerts"] {
            XCTAssertFalse(words(kind).contains("—"), "no em-dash on screen")
        }
    }

    /// A settings record comes back from iCloud like any audit record; a kind this build does not
    /// know is dropped, not shown.
    func testTheRecordsComeBackFromICloud() {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .synced,
                          stateChange: "settingOff.camera")
        let record = CloudExfiltrator.makeStateRecord(event, kind: "settingOff.camera", deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, "settingOff.camera")
        let unknown = CloudExfiltrator.makeStateRecord(event, kind: "settingOff.flux", deviceName: "iPhone Air")
        XCTAssertNil(CloudExfiltrator.stateEvent(from: unknown), "an unknown setting is dropped")
    }

    /// A settings record never alerts the other devices: it is an audit row, like an arm.
    func testASettingsRecordNeverAlerts() {
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "settingOff.camera"))
        XCTAssertFalse(CloudExfiltrator.disarmSignalWanted(kind: "settingOff.otherDeviceAlerts"))
    }

    // MARK: - The engine

    /// A1's case: the Camera tripwire switched off in Settings is on the record when Settings
    /// closes, once; closing again with nothing changed adds nothing.
    func testSwitchingTheCameraOffIsRecordedWhenSettingsCloses() {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()   // the first look adopts the settings as they are
        rig.settings.enabledSensors.remove(.camera)
        rig.engine.recordProtectionChanges()   // Settings closes
        XCTAssertEqual(settingsRecords(rig), ["settingOff.camera"])
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingOff.camera"], "nothing new")
    }

    /// A switch turned off and on again within one visit leaves nothing.
    func testAChangeUndoneBeforeSettingsClosesLeavesNothing() {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()
        rig.settings.jammingResponse.toggle()
        rig.settings.jammingResponse.toggle()
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), [])
    }

    /// Launch adopts the settings already present without calling them a change, before the
    /// first Settings visit can edit them (D6's first-visit regression).
    func testTheFirstLookAdoptsWithoutARecord() throws {
        let rig = makeRig { $0.enabledSensors.remove(.camera) }
        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "com.malinois.protection.recorded"))
        XCTAssertEqual(try JSONDecoder().decode(ProtectionSettings.self, from: data), ProtectionSettings(rig.settings))
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), [])
    }

    /// The phone check's sequence, with no earlier arm or Settings close to establish a baseline:
    /// Vision off on the first visit, then on during a second visit. Both changes must survive.
    func testTheFirstSettingsVisitRecordsVisionOffAndTheNextRecordsItOn() {
        let rig = makeRig { $0.enabledSensors.insert(.vision) }
        rig.settings.enabledSensors.remove(.vision)
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingOff.vision"])
        rig.settings.enabledSensors.insert(.vision)
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingOn.vision", "settingOff.vision"])
    }

    /// Sound on then off in the very first visit has no net effect and leaves no row.
    func testTheFirstSettingsVisitLeavesNoRecordForSoundOnThenOff() {
        let rig = makeRig { $0.enabledSensors.remove(.audio) }
        rig.settings.enabledSensors.insert(.audio)
        rig.settings.enabledSensors.remove(.audio)
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), [])
    }

    /// An app ended with Settings open must keep its old baseline across launch, so the next
    /// arm or Settings close still records what changed; launch itself adds no settings row.
    func testRelaunchPreservesAnExistingBaselineForAnUnreportedChange() throws {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()
        let baseline = try XCTUnwrap(UserDefaults.standard.data(forKey: "com.malinois.protection.recorded"))
        rig.settings.enabledSensors.remove(.camera)
        let relaunched = TestIsolation.track(MonitoringEngine(
            settings: rig.settings, eventStore: rig.store, cloud: CloudExfiltrator(), camera: FakeCamera(),
            entitlements: ProEntitlements(resolvedAs: .trial), timing: EngineCharacterizationTests.fastTiming))
        XCTAssertEqual(UserDefaults.standard.data(forKey: "com.malinois.protection.recorded"), baseline)
        XCTAssertEqual(settingsRecords(rig), [], "launch must not invent an audit row")
        relaunched.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingOff.camera"])
    }

    /// An unreadable saved baseline is re-established before any edit, so the first visit
    /// after recovery is still recorded; the unreadable history itself is not invented.
    func testAnUnreadableBaselineIsAdoptedBeforeTheFirstSettingsEdit() {
        UserDefaults.standard.set(Data([0xFF]), forKey: "com.malinois.protection.recorded")
        let rig = makeRig()
        XCTAssertEqual(settingsRecords(rig), [])
        rig.settings.enabledSensors.remove(.camera)
        rig.engine.recordProtectionChanges()
        XCTAssertEqual(settingsRecords(rig), ["settingOff.camera"])
    }

    /// A change that Settings never reported (the app ended with Settings open) is on the record
    /// at the next arm, before the session starts.
    func testAnArmRecordsAChangeSettingsNeverReported() {
        let rig = makeRig()
        rig.engine.recordProtectionChanges()
        rig.settings.notifyOtherDevices = !rig.settings.notifyOtherDevices
        let kind = rig.settings.notifyOtherDevices ? "settingOn.otherDeviceAlerts" : "settingOff.otherDeviceAlerts"
        rig.engine.beginArming()
        XCTAssertEqual(settingsRecords(rig), [kind])
        rig.engine.disarm()
    }
}
