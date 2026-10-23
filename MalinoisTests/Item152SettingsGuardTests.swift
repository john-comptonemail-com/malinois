//
//  Item152SettingsGuardTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 3 (with lead 17 and hardening note (a)), item 145 step 12 (ADR 0055). A silent push or iOS's
//  prewarming can start Malinois before the first unlock after a restart, when the preferences store reads as empty.
//  The launch took that for a fresh install and ran the whole process on the defaults (iCloud backup on, retention
//  12 months, Sound and Vision off): a Settings close saved them over the owner's choices, the launch seeds and the
//  protection-settings baseline were written from them, and uploads went out as if backup were on. Now a canary
//  file with first-unlock protection tells a sealed store from a fresh install. Sealed, the settings start
//  unresolved (the defaults in memory, flagged): nothing saves, seeds, purges or uploads, and the stored settings
//  load into the same object at the unlock. A damaged settings blob now resets retention to Keep forever. The sealed
//  canary is planted here as a file the process cannot read (its permissions), the one way the simulator can give
//  "exists but cannot be read". Written before the change, red at that commit (against compile-only stubs).
//

import XCTest
@testable import Malinois

@MainActor
final class Item152SettingsGuardTests: XCTestCase {

    nonisolated private static let settingsKey = "com.malinois.settings"
    nonisolated private static let protectionKey = "com.malinois.protection.recorded"
    nonisolated private static let onboardingKeys = ["com.malinois.onboarding.hasDisarmedOnce",
                                         "com.malinois.onboarding.acknowledgedDisarmBriefing",
                                         "com.malinois.onboarding.acknowledgedGuidedAccessBriefing"]
    nonisolated private static let retentionAttemptKey = "com.malinois.cloudRetention.lastAttempt"
    nonisolated private static let retentionRunKey = "com.malinois.cloudRetention.lastRun"

    // Read and written by setUp and tearDown, which XCTest runs on the main thread without main-actor isolation
    // (item 97), so they are kept outside the actor.
    nonisolated(unsafe) private var savedSettings: Data?
    nonisolated(unsafe) private var savedOnboarding: [String: Any] = [:]
    nonisolated(unsafe) private var canaryFolder = URL(fileURLWithPath: NSTemporaryDirectory())
    nonisolated private var canary: URL { canaryFolder.appendingPathComponent("canary") }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152Guard")
        let defaults = UserDefaults.standard
        savedSettings = defaults.data(forKey: Self.settingsKey)
        for key in Self.onboardingKeys { savedOnboarding[key] = defaults.object(forKey: key) }
        canaryFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem152Canary-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: canaryFolder, withIntermediateDirectories: true)
        AppSettings.canaryURLOverrideForTesting = canary
        defaults.removeObject(forKey: Self.settingsKey)
        for key in Self.onboardingKeys + [Self.retentionAttemptKey, Self.retentionRunKey] { defaults.removeObject(forKey: key) }
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        if let savedSettings { defaults.set(savedSettings, forKey: Self.settingsKey) }
        else { defaults.removeObject(forKey: Self.settingsKey) }
        for key in Self.onboardingKeys {
            if let value = savedOnboarding[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        for key in [Self.retentionAttemptKey, Self.retentionRunKey] { defaults.removeObject(forKey: key) }
        defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(Self.settingsKey + ".corrupt-") }
            .forEach { defaults.removeObject(forKey: $0) }
        unseal()
        try? FileManager.default.removeItem(at: canaryFolder)
        AppSettings.canaryURLOverrideForTesting = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// A canary the process cannot read: what a file with first-unlock protection is before the unlock.
    nonisolated private func seal() throws {
        try Data("1".utf8).write(to: canary)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: canary.path)
    }

    nonisolated private func unseal() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: canary.path)
    }

    /// The owner's settings, every value away from its default, stored as the app stores them. The object is let
    /// go: its autosave must not write over what a test stores later.
    @discardableResult
    private func storeOwnersSettings(backup: Bool = false, retention: CloudRetention = .forever) throws -> Data {
        let owner = AppSettings()
        owner.enabledSensors = [.motion, .audio, .touch]
        owner.sensitivities[.motion] = .high
        owner.gracePeriodSeconds = 42
        owner.captureMode = .clip5
        owner.cameraPosition = .front
        owner.cameraReadiness = .batterySaver
        owner.deviceLabel = "Study iPhone"
        owner.illumination = .off
        owner.clipAudio = true
        owner.notifyOtherDevices = false
        owner.cloudBackup = backup
        owner.cloudRetention = retention
        owner.jammingResponse = false
        owner.responseMode = .siren
        owner.alertMessage = "Hands off"
        owner.scramblePINPad = true
        owner.biometricUnlock = true
        owner.requireGuidedAccess = false
        owner.sirenRampUp = false
        let data = try JSONEncoder().encode(owner)
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
        return data
    }

    private func storedSettings() throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: XCTUnwrap(UserDefaults.standard.data(forKey: Self.settingsKey)))
    }

    private func makeEngineAndStore(_ settings: AppSettings, pro: Bool = false) -> (MonitoringEngine, EventStore) {
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }   // no account: a lease fails at once, so nothing waits on CloudKit
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: pro ? .trial : .free),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, store)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    /// Spins the main run loop for `seconds`: the wait a test needs when what it checks is that nothing happens.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Two encodings of the settings hold the same values: every key, every value (the tripwire set as a set).
    private func assertSameSettings(_ a: Data, _ b: Data, _ message: String, file: StaticString = #filePath,
                                    line: UInt = #line) throws {
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: a) as? [String: Any])
        let right = try XCTUnwrap(JSONSerialization.jsonObject(with: b) as? [String: Any])
        XCTAssertEqual(Set(left.keys), Set(right.keys), message, file: file, line: line)
        for (key, value) in left {
            if let names = value as? [String], let others = right[key] as? [String] {
                XCTAssertEqual(Set(names), Set(others), "\(key): \(message)", file: file, line: line)
            } else {
                XCTAssertEqual(value as? NSObject, right[key] as? NSObject, "\(key): \(message)", file: file, line: line)
            }
        }
    }

    // MARK: - The rule

    /// The canary tells a sealed store from a fresh install: missing or readable, the store's answer stands; existing
    /// but unreadable, the store is sealed whatever it answered.
    func testTheRuleTellsASealedStoreFromAFreshInstall() {
        let data = Data("{}".utf8)
        XCTAssertEqual(AppSettings.storeReading(canary: .missing, stored: nil), .fresh, "nothing anywhere: a fresh install")
        XCTAssertEqual(AppSettings.storeReading(canary: .missing, stored: data), .stored(data),
                       "an install from before the canary, or one whose canary was lost")
        XCTAssertEqual(AppSettings.storeReading(canary: .readable, stored: data), .stored(data))
        XCTAssertEqual(AppSettings.storeReading(canary: .readable, stored: nil), .fresh, "launched before, never saved")
        XCTAssertEqual(AppSettings.storeReading(canary: .unreadable, stored: nil), .sealed,
                       "exists but cannot be read: before the first unlock")
        XCTAssertEqual(AppSettings.storeReading(canary: .unreadable, stored: data), .sealed, "whatever the store says meanwhile")
    }

    // MARK: - A sealed store

    /// Sealed, the launch's settings are the defaults, flagged, and nothing writes them over the owner's: not a save,
    /// not the autosave after an edit.
    func testASealedStoreLoadsUnresolvedDefaultsThatNeverSave() throws {
        let stored = try storeOwnersSettings()
        try seal()
        let settings = AppSettings.load()
        XCTAssertTrue(settings.awaitingUnlock, "the store is sealed: the settings wait")
        XCTAssertTrue(settings.cloudBackup, "the defaults meanwhile")
        XCTAssertEqual(settings.cloudRetention, .months12)
        XCTAssertEqual(settings.gracePeriodSeconds, 15)
        settings.save()
        XCTAssertEqual(UserDefaults.standard.data(forKey: Self.settingsKey), stored, "a save writes nothing")
        settings.gracePeriodSeconds = 99
        settle(0.7)   // past the autosave's debounce
        XCTAssertEqual(UserDefaults.standard.data(forKey: Self.settingsKey), stored, "the autosave writes nothing either")
    }

    /// The stored settings load into the same object at the unlock notice, every value; the flag clears, the canary
    /// is written again, and saves resume.
    func testTheStoredSettingsLoadIntoTheSameObjectAtTheUnlock() throws {
        let stored = try storeOwnersSettings()
        try seal()
        let settings = AppSettings.load()
        XCTAssertTrue(settings.awaitingUnlock)
        unseal()
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { !settings.awaitingUnlock }, timeout: 2), "resolved at the unlock")
        try assertSameSettings(try JSONEncoder().encode(settings), stored, "every stored value, into the same object")
        XCTAssertFalse(settings.cloudBackup)
        XCTAssertEqual(settings.cloudRetention, .forever)
        XCTAssertEqual(settings.gracePeriodSeconds, 42)
        XCTAssertEqual(AppSettings.canaryState(), .readable, "the canary is written again")
        settings.gracePeriodSeconds = 43
        settings.save()
        XCTAssertEqual(try storedSettings().gracePeriodSeconds, 43, "saves resume")
    }

    /// The canary is still sealed at the notice (the keys arrive an instant later): the settings keep waiting, and
    /// resolve at the next signal, the app becoming active, once the canary reads.
    func testAStoreStillSealedAtTheNoticeKeepsWaitingForTheNextSignal() throws {
        try storeOwnersSettings()
        try seal()
        let settings = AppSettings.load()
        settings.useProtectedDataAnswerForTesting { false }   // UIKit: locked
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        settle(0.2)
        XCTAssertTrue(settings.awaitingUnlock, "still sealed: still waiting")
        XCTAssertTrue(settings.cloudBackup, "still the defaults")
        unseal()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { !settings.awaitingUnlock }, timeout: 2), "the app active and the canary readable: resolved")
        XCTAssertFalse(settings.cloudBackup, "the owner's settings")
    }

    /// A canary that still cannot be read while UIKit says the phone is unlocked is broken, not sealed: the settings
    /// resolve from the store and the canary is written afresh (the event log's rule, ADR 0016, mirrored).
    func testABrokenCanaryOnAnUnlockedPhoneResolvesAndIsRewritten() throws {
        try storeOwnersSettings()
        try seal()
        let settings = AppSettings.load()
        XCTAssertTrue(settings.awaitingUnlock)
        settings.useProtectedDataAnswerForTesting { true }   // UIKit: unlocked, and the canary still unreadable
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { !settings.awaitingUnlock }, timeout: 2), "broken, not sealed: resolved")
        XCTAssertEqual(settings.gracePeriodSeconds, 42, "the owner's settings")
        XCTAssertEqual(AppSettings.canaryState(), .readable, "the broken canary replaced")
    }

    // MARK: - What waits

    /// The launch seeds (the disarm tip, the first-arm screen's parts) wait for the settings: nothing is written from an
    /// empty read, and they run at the unlock (the launch's own order, `makeServices`).
    func testTheLaunchSeedsWaitForTheUnlock() throws {
        try storeOwnersSettings()
        try seal()
        let sealed = AppSettings.load()
        let services = MalinoisApp.makeServices(settings: sealed, entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })   // no WatchConnectivity in a test
        TestIsolation.track(services.engine)
        for key in Self.onboardingKeys {
            XCTAssertNil(UserDefaults.standard.object(forKey: key), "\(key): seeded from an empty read")
        }
        unseal()
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { !sealed.awaitingUnlock }, timeout: 2))
        for key in Self.onboardingKeys {
            XCTAssertNotNil(UserDefaults.standard.object(forKey: key), "\(key): seeded at the unlock")
        }
    }

    /// The protection-settings baseline (item 91) is not adopted from the defaults, and no change is checked against
    /// them: an engine built on a sealed store records none; at the unlock it records the owner's settings, so the
    /// next arm reports no false change.
    func testTheProtectionBaselineWaitsAndThenRecordsTheOwnersSettings() throws {
        try storeOwnersSettings()   // Sound on, Guided Access not required: both away from the defaults
        try seal()
        let sealed = AppSettings.load()
        let (engine, store) = makeEngineAndStore(sealed)
        XCTAssertNil(UserDefaults.standard.data(forKey: Self.protectionKey), "no baseline from the defaults")
        engine.recordProtectionChanges()
        XCTAssertNil(UserDefaults.standard.data(forKey: Self.protectionKey), "a check while unresolved adopts nothing")
        XCTAssertTrue(store.events.isEmpty, "and reports nothing")
        unseal()
        sealed.resolveIfReadable()
        XCTAssertFalse(sealed.awaitingUnlock)
        let recorded = try JSONDecoder().decode(ProtectionSettings.self,
                                                from: XCTUnwrap(UserDefaults.standard.data(forKey: Self.protectionKey)))
        XCTAssertEqual(recorded, ProtectionSettings(sealed), "the owner's settings, at the unlock")
        XCTAssertTrue(recorded.tripwires.contains(.audio))
        XCTAssertFalse(recorded.requireGuidedAccess)
        engine.recordProtectionChanges()
        XCTAssertTrue(store.events.isEmpty, "no change against the owner's own settings")
    }

    /// No retention pass runs on unresolved settings (the defaults say 12 months; the owner may keep forever): the
    /// attempt is not even stamped. Resolved, the pass runs as before.
    func testNoRetentionPassRunsWhileUnresolved() async throws {
        try storeOwnersSettings(retention: .months3)
        try seal()
        let sealed = AppSettings.load()
        let (engine, _) = makeEngineAndStore(sealed, pro: true)
        await engine.enforceCloudRetentionIfDue()
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.retentionAttemptKey), "nothing stamped, nothing purged")
        unseal()
        sealed.resolveIfReadable()
        XCTAssertEqual(sealed.cloudRetention, .months3)
        await engine.enforceCloudRetentionIfDue()
        XCTAssertNotNil(UserDefaults.standard.object(forKey: Self.retentionAttemptKey), "resolved: the pass runs")
    }

    /// Uploads wait: while unresolved nothing is let through, no heartbeat goes out, the switch cannot be moved, and
    /// nothing recorded meanwhile is marked kept-local or held to no account by the switch (the owner may have
    /// backup on). Resolved with backup on, the record may upload as any other.
    func testUploadsWaitWithoutMarkingAnythingKeptLocal() throws {
        try storeOwnersSettings(backup: true)
        try seal()
        let sealed = AppSettings.load()
        let (engine, store) = makeEngineAndStore(sealed, pro: true)
        let event = engine.logStateChange("test")
        XCTAssertFalse(engine.backupAllows(event), "unresolved: the upload waits")
        XCTAssertFalse(engine.cloud.backupOn(), "and no heartbeat goes out")
        XCTAssertFalse(engine.cloud.enrollment.holdsNewEventsLocal(), "not held to no account by the switch")
        XCTAssertNil(store.events.first { $0.id == event.id }?.keptLocal, "not marked kept-local")
        XCTAssertFalse(engine.setCloudBackup(false), "the switch cannot be moved while unresolved")
        XCTAssertTrue(store.events.allSatisfy { $0.stateChange != Event.backupOffKind }, "so no entry says it was")
        unseal()
        sealed.resolveIfReadable()
        XCTAssertTrue(engine.backupAllows(event), "resolved with backup on: it may upload")
        XCTAssertTrue(engine.cloud.backupOn())
    }

    /// Resolved with backup off, the rule is the old one: a record made from then on is marked, and the switch's
    /// refusal applies to what waited too.
    func testResolvedWithBackupOffNewRecordsAreMarkedAsBefore() throws {
        try storeOwnersSettings(backup: false)
        try seal()
        let sealed = AppSettings.load()
        let (engine, store) = makeEngineAndStore(sealed)
        let during = engine.logStateChange("test")
        XCTAssertNil(store.events.first { $0.id == during.id }?.keptLocal, "recorded while unresolved: unmarked")
        unseal()
        sealed.resolveIfReadable()
        let after = engine.logStateChange("test")
        XCTAssertEqual(store.events.first { $0.id == after.id }?.keptLocal, true, "recorded with backup known off: marked")
        XCTAssertFalse(engine.backupAllows(during), "backup off refuses what waited, as it refuses everything")
    }

    // MARK: - A damaged store

    /// A settings blob that does not decode resets retention to Keep forever, not 12 months: nothing in iCloud is
    /// deleted on the strength of a setting the owner never chose. The iCloud switches stand as ADR 0049 says.
    func testADamagedStoreFallsBackToKeepForever() throws {
        UserDefaults.standard.set(Data(#"{"gracePeriodSeconds":"not a number","cloudBackup":true}"#.utf8),
                                  forKey: Self.settingsKey)
        let loaded = AppSettings.load()
        XCTAssertTrue(AppSettings.loadWasReset)
        XCTAssertEqual(loaded.cloudRetention, .forever)
        XCTAssertTrue(loaded.cloudBackup, "the readable switch stands (ADR 0049)")
        XCTAssertEqual(try storedSettings().cloudRetention, .forever, "stored at once")
        XCTAssertEqual(AppSettings.canaryState(), .readable, "a launch that read the settings, damaged or not")
    }

    // MARK: - The canary

    /// A launch that read the settings writes the canary: a fresh install's first launch, and every one after.
    func testALaunchThatReadTheSettingsWritesTheCanary() throws {
        XCTAssertEqual(AppSettings.canaryState(), .missing)
        _ = AppSettings.load()
        XCTAssertEqual(AppSettings.canaryState(), .readable, "a fresh install's first launch")
        try FileManager.default.removeItem(at: canary)
        try storeOwnersSettings()
        _ = AppSettings.load()
        XCTAssertEqual(AppSettings.canaryState(), .readable, "a launch that read stored settings")
    }
}
