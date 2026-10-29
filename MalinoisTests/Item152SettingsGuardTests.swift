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
//  "exists but cannot be read". Written before the change, red at that commit (against compile-only stubs). Item 165's
//  A3 (Codex's codex-4 on 224a07a; item 163's step 39): the recovery re-arm and the watch relay, which ran on the
//  defaults when the app became active before the stored settings loaded, now wait for them; red before its change.
//  Its residuals, Codex's codex-19 (a reconnect) and codex-21 (an arm's warm-up): an automatic setup of the account's
//  alert subscriptions follows the owner's choice as it is after each wait, and an "off" under way supersedes it; each
//  red before its change.
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

    // MARK: - Item 165's A3: recovery and the watch relay wait for the stored settings

    /// The relay's sends, kept for the test.
    private final class SentAlerts {
        var messages: [WatchAlertMessage] = []
    }

    /// item 165's A3 (codex-4 on 224a07a): the armed app was killed, and the app launched again before the first unlock,
    /// its settings waiting with the defaults in memory; then it becomes active before the stored settings load. The
    /// recovery re-arm must not start on the defaults (their 15-second grace period, not the owner's 42), and the watch
    /// relay must not send the interruption's alert on the default switch (alerts on, the owner's off). Once the
    /// settings load, the re-arm runs on the owner's grace period, and the relay reads the owner's switch.
    func testRecoveryAndTheWatchRelayWaitForTheStoredSettings() throws {
        try storeOwnersSettings()   // alerts off, a 42-second grace period, Guided Access not required
        try seal()
        let settings = AppSettings.load()
        XCTAssertTrue(settings.awaitingUnlock, "before the first unlock")
        UserDefaults.standard.set(0.5, forKey: MonitoringEngine.armedMarkerKey)   // the armed app was killed
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }
        let pro = ProEntitlements(resolvedAs: .trial)
        let sent = SentAlerts()
        let relay = WatchAlertRelay(store: store, settings: settings, entitlements: pro,
                                    send: { sent.messages.append($0) })
        relay.start()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: pro,
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          protectedDataAvailable: { false }))
        defer { engine.disarm(); withExtendedLifetime(relay) {} }
        XCTAssertTrue(engine.launchRecoveryWaiting, "the recovery waits for the unlock")
        unseal()   // unlocked: the stored settings can load, and have not yet
        engine.handleScenePhase(true)   // the app becomes active first
        XCTAssertTrue(store.events.contains { $0.interrupted == true }, "the interruption is on the record")
        XCTAssertTrue(sent.messages.isEmpty, "no alert sent on the default switch")
        XCTAssertEqual(engine.state, .disarmed, "no re-arm on the defaults")
        settings.resolveIfReadable()   // the stored settings load
        XCTAssertFalse(settings.awaitingUnlock)
        XCTAssertEqual(engine.state, .arming, "the owed re-arm runs once they have")
        XCTAssertEqual(engine.graceRemaining, 42, "on the owner's grace period")
        XCTAssertTrue(sent.messages.isEmpty, "and the owner's switch is off")
    }

    // MARK: - Item 165's A3 residual: automatic alert subscriptions (codex-19 on 946b248, codex-21 on b00a120)

    /// A wait a test holds: shut, it holds the waits that begin until it is released; open, they pass. It counts the
    /// waits begun, so a test waits for the one it holds instead of sleeping (Codex's note on 946b248..b00a120).
    @MainActor
    private final class Gate {
        private var isShut: Bool
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private(set) var entered = 0
        init(shut: Bool = true) { isShut = shut }
        func wait() async {
            entered += 1
            guard isShut else { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func shut() { isShut = true }
        func release() {
            isShut = false
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    /// What the cloud was asked: the alert subscriptions saved and removed (their identifiers, in order), and the
    /// automatic setups (the arm's warm-up, a reconnect's refresh) begun and finished. A test can have the device
    /// authentication refused, or the removal fail.
    @MainActor
    private final class CloudCalls {
        var saved: [String] = []
        var removed: [String] = []
        var setupsBegun = 0
        var setupsFinished = 0
        var authenticationRefused = false
        var removalFails = false
    }

    /// The tamper and disarm subscriptions' identifiers, in the order they are saved.
    private var alertSubscriptions: [String] {
        [CloudExfiltrator.makeTamperSubscription().subscriptionID, CloudExfiltrator.makeDisarmSubscription().subscriptionID]
    }

    /// An installation verified for "account-a", the account holding no subscription, every subscription saved or
    /// removed and every automatic setup counted; the lease, the arm, the reconnect, the switch's account-wide "off"
    /// and the choice of what to save run as shipped. A gate holds its wait while shut: the account lookup, the
    /// listing of the account's subscriptions, a save, or the device authentication an "off" asks for (which must
    /// start open: the verification here asks it too). `pro` is the owner's Pro, a trial unless a test passes its own.
    private func makeAlertsRig(_ settings: AppSettings, lookup: Gate? = nil, listing: Gate? = nil, save: Gate? = nil,
                               authentication: Gate? = nil,
                               pro: ProEntitlements? = nil) async throws -> (MonitoringEngine, CloudExfiltrator, CloudCalls) {
        let file = try XCTUnwrap(EventStore.rootOverrideForTesting)
            .appendingPathComponent("grant-" + UUID().uuidString).appendingPathComponent("state.json")
        let calls = CloudCalls()
        let enrollment = CloudEnrollment(file: file, authenticate: { _ in
            await authentication?.wait()
            return !calls.authenticationRefused
        })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let cloud = CloudExfiltrator(enrollment: enrollment)
        cloud.accountIdentityForTesting = {
            await lookup?.wait()
            return "account-a"
        }
        cloud.existingSubscriptionsForTesting = {
            await listing?.wait()
            return []
        }
        cloud.subscriptionSaveForTesting = { subscription in
            calls.saved.append(subscription.subscriptionID)
            await save?.wait()
            return true
        }
        cloud.subscriptionRemovalForTesting = { ids in
            calls.removed += ids
            return !calls.removalFails
        }
        cloud.automaticSetupBeganForTesting = { calls.setupsBegun += 1 }
        cloud.automaticSetupFinishedForTesting = { calls.setupsFinished += 1 }
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: cloud,
                                                          camera: FakeCamera(), entitlements: pro ?? ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return (engine, cloud, calls)
    }

    /// The owner's stored settings, loaded, with cross-device alerts switched on.
    private func alertsOnSettings() throws -> AppSettings {
        try storeOwnersSettings()
        let settings = AppSettings.load()
        XCTAssertFalse(settings.awaitingUnlock)
        settings.notifyOtherDevices = true
        return settings
    }

    /// The owner's "off" as Settings' switch makes it (`applyCrossDeviceAlerts`): the account-wide removal, with its
    /// device authentication, and the switch saved off only once the removal has landed.
    private func turnAlertsOff(_ cloud: CloudExfiltrator, _ settings: AppSettings) async -> Bool {
        let landed = await cloud.setCrossDeviceAlerts(false)
        if landed { settings.notifyOtherDevices = false }
        return landed
    }

    /// The owner's "on" as Settings' switch makes it: the account-wide setup, and the switch saved on once it landed.
    private func turnAlertsOn(_ cloud: CloudExfiltrator, _ settings: AppSettings) async -> Bool {
        let landed = await cloud.setCrossDeviceAlerts(true)
        if landed { settings.notifyOtherDevices = true }
        return landed
    }

    /// Polls until `condition` holds, for at most three seconds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// item 165's A3 residual (codex-19 on 946b248): while the stored settings wait for the first unlock, their alerts
    /// switch reads as the default's (on), and a reconnect set the account's alert subscriptions up on it, after the
    /// owner's "off" had loaded. A reconnect while they wait asks for nothing.
    func testAReconnectBeforeTheSettingsLoadSetsNoAlertSubscriptionUp() async throws {
        try storeOwnersSettings()   // alerts off
        try seal()
        let settings = AppSettings.load()
        XCTAssertTrue(settings.awaitingUnlock, "before the first unlock")
        let (engine, _, calls) = try await makeAlertsRig(settings)
        engine.simulateConnectivityForTesting(online: false)
        engine.simulateConnectivityForTesting(online: true)   // a reconnect, the settings still waiting
        XCTAssertEqual(engine.alertRefreshesAskedForTesting, 0, "no refresh asked for on the defaults")
        unseal()
        settings.resolveIfReadable()   // the owner's "off" loads
        XCTAssertFalse(settings.notifyOtherDevices)
        XCTAssertEqual(calls.saved, [], "no alert subscription set up against the owner's off")
    }

    /// item 165's A3 residual: a refresh asked for with alerts on carried that "on" through the account lookup, so an
    /// "off" made meanwhile did not stop it. The refresh asks again after each wait.
    func testAnAlertsOffDuringARefreshSetsNoAlertSubscriptionUp() async throws {
        let settings = try alertsOnSettings()
        let lookup = Gate()
        let (engine, _, calls) = try await makeAlertsRig(settings, lookup: lookup)
        engine.simulateConnectivityForTesting(online: false)
        engine.simulateConnectivityForTesting(online: true)   // the refresh starts, and waits on the account lookup
        let held = await eventually { calls.setupsBegun == 1 }
        XCTAssertTrue(held, "the refresh waits on the account lookup")
        settings.notifyOtherDevices = false   // the owner's "off", meanwhile
        lookup.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the refresh finished")
        XCTAssertEqual(calls.saved, [], "the refresh asked again and set nothing up")
    }

    /// The control: with alerts on, a reconnect sets the account's alert subscriptions up, as before.
    func testAReconnectWithAlertsOnSetsTheAlertSubscriptionsUp() async throws {
        let settings = try alertsOnSettings()
        let (engine, _, calls) = try await makeAlertsRig(settings)
        engine.simulateConnectivityForTesting(online: false)
        engine.simulateConnectivityForTesting(online: true)
        XCTAssertEqual(engine.alertRefreshesAskedForTesting, 1, "the reconnect asked for a refresh")
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the refresh finished")
        XCTAssertEqual(calls.saved, alertSubscriptions, "the tamper and disarm subscriptions")
    }

    /// codex-21 on b00a120, the control: an arm with alerts on sets the account's alert subscriptions up, the tamper
    /// subscription first, as before.
    func testAnArmWithAlertsOnSetsTheAlertSubscriptionsUp() async throws {
        let settings = try alertsOnSettings()
        let (engine, _, calls) = try await makeAlertsRig(settings)
        engine.beginArming()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, alertSubscriptions, "the tamper and disarm subscriptions")
    }

    /// codex-21 on b00a120: the arm's warm-up carried the choice read at the arm through its account lookup, so an
    /// "off" the owner made meanwhile (the arm cancelled, then Settings' switch, its removal landed) did not stop it:
    /// the lookup ended after the off, and the warm-up set the subscriptions up again. It asks again after each wait.
    func testAnAlertsOffDuringTheArmsAccountLookupSetsNoAlertSubscriptionUp() async throws {
        let settings = try alertsOnSettings()
        let lookup = Gate()
        let (engine, cloud, calls) = try await makeAlertsRig(settings, lookup: lookup)
        engine.beginArming()
        let held = await eventually { calls.setupsBegun == 1 }
        XCTAssertTrue(held, "the arm's warm-up waits on the account lookup")
        cloud.accountIdentityForTesting = { "account-a" }   // the off's own lookups answer at once
        engine.cancelArming()
        let landed = await turnAlertsOff(cloud, settings)
        XCTAssertTrue(landed, "the owner's off landed")
        lookup.release()   // the warm-up's lookup ends after the off
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, [], "no alert subscription set up after the owner's off")
    }

    /// codex-21, the Pro half of the live choice: cross-device alerts are Pro's, and the arm's warm-up asks for Pro as
    /// it is after each wait, not as it was at the arm. The trial ends while a cancelled arm's warm-up waits on the
    /// account lookup, the switch untouched: nothing is set up.
    func testATrialThatEndsDuringTheArmsAccountLookupSetsNoAlertSubscriptionUp() async throws {
        let settings = try alertsOnSettings()
        let lookup = Gate()
        let pro = ProEntitlements(resolvedAs: .trial)
        let (engine, _, calls) = try await makeAlertsRig(settings, lookup: lookup, pro: pro)
        engine.beginArming()
        let held = await eventually { calls.setupsBegun == 1 }
        XCTAssertTrue(held, "the arm's warm-up waits on the account lookup")
        engine.cancelArming()
        pro.resolveForTesting(as: .free)   // the trial ends
        lookup.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertTrue(settings.notifyOtherDevices, "the switch is still on")
        XCTAssertEqual(calls.saved, [], "no alert subscription set up once Pro had ended")
    }

    /// codex-21: the same, the owner's off made while the warm-up's listing of the account's subscriptions waits.
    func testAnAlertsOffDuringTheArmsListingSetsNoAlertSubscriptionUp() async throws {
        let settings = try alertsOnSettings()
        let listing = Gate()
        let (engine, cloud, calls) = try await makeAlertsRig(settings, listing: listing)
        engine.beginArming()
        let held = await eventually { listing.entered == 1 }
        XCTAssertTrue(held, "the arm's warm-up waits on the listing")
        engine.cancelArming()
        let landed = await turnAlertsOff(cloud, settings)
        XCTAssertTrue(landed, "the owner's off landed")
        listing.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, [], "no alert subscription set up after the owner's off")
    }

    /// codex-21: the owner's off made while the warm-up's first save waits. That save was under way before the off,
    /// and what CloudKit accepts of it stays (the known limit); no other save begins after the off.
    func testAnAlertsOffBetweenTheArmsSavesStartsNoOtherSave() async throws {
        let settings = try alertsOnSettings()
        let save = Gate()
        let (engine, cloud, calls) = try await makeAlertsRig(settings, save: save)
        engine.beginArming()
        let held = await eventually { calls.saved.count == 1 }
        XCTAssertTrue(held, "the arm's warm-up waits on its first save")
        engine.cancelArming()
        let landed = await turnAlertsOff(cloud, settings)
        XCTAssertTrue(landed, "the owner's off landed")
        save.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, Array(alertSubscriptions.prefix(1)), "no save began after the owner's off")
    }

    /// codex-21, the off's own wait: Settings saves the switch off only once the removal has landed, so while the
    /// owner's off waits on Face ID or the passcode the switch still reads on. A warm-up that reaches its saves then
    /// is superseded by the off under way, and saves nothing.
    func testAnArmReachingItsSavesWhileTheOwnersOffWaitsSavesNothing() async throws {
        let settings = try alertsOnSettings()
        let listing = Gate()
        let authentication = Gate(shut: false)
        let (engine, cloud, calls) = try await makeAlertsRig(settings, listing: listing, authentication: authentication)
        engine.beginArming()
        let listed = await eventually { listing.entered == 1 }
        XCTAssertTrue(listed, "the arm's warm-up waits on the listing")
        engine.cancelArming()
        await assertNothingSavedWhileTheOffWaits(cloud, settings, calls, listing: listing, authentication: authentication)
    }

    /// codex-21: the same for a reconnect's refresh, whose live choice (codex-19) reads the switch, still on while the
    /// owner's off waits.
    func testAReconnectReachingItsSavesWhileTheOwnersOffWaitsSavesNothing() async throws {
        let settings = try alertsOnSettings()
        let listing = Gate()
        let authentication = Gate(shut: false)
        let (engine, cloud, calls) = try await makeAlertsRig(settings, listing: listing, authentication: authentication)
        engine.simulateConnectivityForTesting(online: false)
        engine.simulateConnectivityForTesting(online: true)
        let listed = await eventually { listing.entered == 1 }
        XCTAssertTrue(listed, "the refresh waits on the listing")
        await assertNothingSavedWhileTheOffWaits(cloud, settings, calls, listing: listing, authentication: authentication)
    }

    /// Codex's note on d084392: an "off" that fails also stands down the automatic setup under way, which saves
    /// nothing; the switch stays on, and the next automatic setup, under a fresh count, sets the subscriptions up.
    /// Here Face ID or the passcode is refused.
    func testAnOffRefusedAtFaceIDStandsTheSetupUnderWayDownButNotTheNext() async throws {
        try await assertAFailedOffStandsTheSetupUnderWayDownButNotTheNext { $0.authenticationRefused = true }
    }

    /// The same when the off's removal fails.
    func testAnOffWhoseRemovalFailsStandsTheSetupUnderWayDownButNotTheNext() async throws {
        try await assertAFailedOffStandsTheSetupUnderWayDownButNotTheNext { $0.removalFails = true }
    }

    private func assertAFailedOffStandsTheSetupUnderWayDownButNotTheNext(_ fail: (CloudCalls) -> Void) async throws {
        let settings = try alertsOnSettings()
        let listing = Gate()
        let (engine, cloud, calls) = try await makeAlertsRig(settings, listing: listing)
        engine.beginArming()
        let listed = await eventually { listing.entered == 1 }
        XCTAssertTrue(listed, "the arm's warm-up waits on the listing")
        engine.cancelArming()
        fail(calls)
        let landed = await turnAlertsOff(cloud, settings)
        XCTAssertFalse(landed, "the owner's off failed")
        XCTAssertTrue(settings.notifyOtherDevices, "the switch stays on")
        listing.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, [], "the warm-up under way stood down")
        engine.simulateConnectivityForTesting(online: false)
        engine.simulateConnectivityForTesting(online: true)   // the next automatic setup
        let refreshed = await eventually { calls.setupsFinished == 2 }
        XCTAssertTrue(refreshed, "the reconnect's refresh finished")
        XCTAssertEqual(calls.saved, alertSubscriptions, "the next setup set the subscriptions up")
    }

    /// Codex's note on d084392: the switch's own "on" is not held back by the counting it does: turned back on right
    /// after an "off" landed, while the old arm's warm-up still waits, it sets the subscriptions up itself, and the
    /// old warm-up saves nothing, so each is saved once.
    func testAnOnRightAfterAnOffSetsTheSubscriptionsUpOnceWhileTheOldWarmUpStandsDown() async throws {
        let settings = try alertsOnSettings()
        let listing = Gate()
        let (engine, cloud, calls) = try await makeAlertsRig(settings, listing: listing)
        engine.beginArming()
        let listed = await eventually { listing.entered == 1 }
        XCTAssertTrue(listed, "the arm's warm-up waits on the listing")
        engine.cancelArming()
        let off = await turnAlertsOff(cloud, settings)
        XCTAssertTrue(off, "the owner's off landed")
        let on = Task { await turnAlertsOn(cloud, settings) }
        let waiting = await eventually { listing.entered == 2 }
        XCTAssertTrue(waiting, "the owner's on waits on its own listing")
        listing.release()
        let landed = await on.value
        XCTAssertTrue(landed, "the owner's on landed")
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the arm's warm-up finished")
        XCTAssertEqual(calls.saved, alertSubscriptions, "each subscription saved once, by the owner's on")
    }

    /// With an automatic setup held in its listing: the owner's off begins and waits on the device authentication;
    /// the listing ends, and the setup finishes having saved nothing; then the off lands.
    private func assertNothingSavedWhileTheOffWaits(_ cloud: CloudExfiltrator, _ settings: AppSettings, _ calls: CloudCalls,
                                                    listing: Gate, authentication: Gate) async {
        authentication.shut()
        let asked = authentication.entered
        let off = Task { await turnAlertsOff(cloud, settings) }
        let waiting = await eventually { authentication.entered == asked + 1 }
        XCTAssertTrue(waiting, "the owner's off waits on the device authentication")
        XCTAssertTrue(settings.notifyOtherDevices, "the switch still reads on")
        listing.release()
        let finished = await eventually { calls.setupsFinished == 1 }
        XCTAssertTrue(finished, "the automatic setup finished")
        XCTAssertEqual(calls.saved, [], "nothing saved while the owner's off was under way")
        authentication.release()
        let landed = await off.value
        XCTAssertTrue(landed, "the owner's off landed")
        XCTAssertEqual(calls.removed.count, 3, "the tamper, disarm and 1.0 subscriptions removed")
        XCTAssertEqual(calls.saved, [], "and nothing saved after it")
    }
}
