//
//  Item84TestIsolationTests.swift
//  MalinoisTests
//
//  BACKLOG 84 (filed 2026-09-26 while tracing an intermittent item-77 failure): tests leaked
//  state into each other. An event store looked its folder up again on every write, so one
//  that outlived its test wrote into the next test's folder — or, with no override set, into
//  the test host's real log; an engine a test left armed kept running, and the recovery flags
//  engines keep in UserDefaults carried into later tests. Written before the fix, red at that
//  commit. This class cleans up after itself directly, so its red run leaks nothing either; the
//  flags it clears are the shared list's, so a prefix added there is cleared here too (item 93).
//

import XCTest
@testable import Malinois

@MainActor
final class Item84TestIsolationTests: XCTestCase {

    // Used by setUp, the test and tearDown, which XCTest runs one after another on the main thread;
    // setUp and tearDown are not main-actor isolated, so these are not either (item 97).
    nonisolated(unsafe) private var folders: [URL] = []
    nonisolated(unsafe) private var engines: [MonitoringEngine] = []

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = newFolder()
    }

    override func tearDown() {
        let engines = self.engines
        MainActor.assumeIsolated { for engine in engines { engine.disarm() } }   // on the main thread (item 97)
        self.engines.removeAll()
        clearOwnFlags()
        EventStore.rootOverrideForTesting = nil
        for dir in folders { try? FileManager.default.removeItem(at: dir) }
        folders.removeAll()
        super.tearDown()
    }

    nonisolated private func newFolder() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem84-" + UUID().uuidString, isDirectory: true)
        folders.append(dir)
        return dir
    }

    /// The flags present that the shared list names (`TestIsolation.recoveryFlagPrefixes`). The class
    /// reads that list rather than keeping a copy, which missed item 91's recorded settings (item 93).
    nonisolated private func recoveryFlagsPresent() -> [String] {
        UserDefaults.standard.dictionaryRepresentation().keys
            .filter { key in TestIsolation.recoveryFlagPrefixes.contains { key.hasPrefix($0) } }
            .sorted()
    }

    /// What this class's tearDown clears.
    nonisolated private func clearOwnFlags() {
        for key in recoveryFlagsPresent() { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// An engine armed through grace (0 s), calibration and the review, on this test's store.
    private func armedEngine(file: StaticString = #filePath, line: UInt = #line) -> MonitoringEngine {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let engine = MonitoringEngine(settings: settings, eventStore: EventStore(), cloud: CloudExfiltrator(),
                                      camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: EngineCharacterizationTests.fastTiming)
        engines.append(engine)
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while engine.state != .armed && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertEqual(engine.state, .armed, "grace 0 + calibration + review reach .armed", file: file, line: line)
        return engine
    }

    // MARK: - The store keeps its folder

    /// A store keeps the folder it was built with: after the override moves on (the next test's
    /// setUp), its birth journal still lands in its own folder, never in the new one.
    func testAStoreKeepsWritingToTheFolderItWasBuiltIn() throws {
        let own = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let store = EventStore()
        let next = newFolder()
        EventStore.rootOverrideForTesting = next   // the next test begins

        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion]))

        XCTAssertTrue(FileManager.default.fileExists(atPath: own.appendingPathComponent("events.journal").path),
                      "the birth line lands in the store's own folder")
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.appendingPathComponent("events.journal").path),
                       "and never in the next test's")
    }

    /// The same for media: a capture stored after the override moves on lands in the store's
    /// own Media folder.
    func testAStoreKeepsItsMediaInTheFolderItWasBuiltIn() async throws {
        let own = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let store = EventStore()
        let next = newFolder()
        EventStore.rootOverrideForTesting = next

        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg")

        let name = try XCTUnwrap(stored?.filename)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: own.appendingPathComponent("Media").appendingPathComponent(name).path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: next.appendingPathComponent("Media").appendingPathComponent(name).path))
    }

    // MARK: - The shared cleanup

    /// The recovery flags an armed engine leaves in UserDefaults are all cleared by the shared
    /// helper, so none reaches the next test's recovery.
    func testClearingTheRecoveryFlagsLeavesNoneOfAnArmedSessionBehind() {
        let engine = armedEngine()
        XCTAssertFalse(recoveryFlagsPresent().isEmpty, "an armed session leaves its flags")

        TestIsolation.clearRecoveryFlags()

        XCTAssertEqual(recoveryFlagsPresent(), [], "none left for the next test")
        engine.disarm()
    }

    /// This class's own cleanup clears item 91's recorded protection settings: every arm records
    /// them, and they outlived this class, whose copy of the list predated them (the ultracode
    /// review's U3, item 93). The key itself is checked, so the test holds whatever list the
    /// cleanup reads.
    func testThisClassesOwnCleanupLeavesNoSharedFlagBehind() {
        let recordedProtection = "com.malinois.protection.recorded"
        let engine = armedEngine()
        engine.disarm()
        XCTAssertNotNil(UserDefaults.standard.object(forKey: recordedProtection),
                        "an arm records the protection settings")
        clearOwnFlags()
        XCTAssertNil(UserDefaults.standard.object(forKey: recordedProtection), "none left for the next class")
        XCTAssertEqual(recoveryFlagsPresent(), [])
    }

    /// A tracked engine is disarmed by the shared tearDown, so one a failing test left armed
    /// stops there instead of running into the next test.
    func testTrackedEnginesAreDisarmedAtTearDown() {
        let engine = TestIsolation.track(armedEngine())
        XCTAssertEqual(engine.state, .armed)

        TestIsolation.disarmTrackedEngines()

        XCTAssertEqual(engine.state, .disarmed)
    }

    /// An engine hears its Pro check through the main run loop, so a test that never turns the loop
    /// leaves the answer waiting. It used to land in the next test that turned the loop, where the
    /// engine acted on that test's flags: it took the re-arm owed to that test's own engine (the
    /// test-suite audit's ME206). The shared tearDown lets the answer land in the test that left it.
    func testAnEnginesQueuedProAnswerLandsInItsOwnTest() {
        let owed = "com.malinois.recovery.pendingReArm"
        TestIsolation.setUp(folderPrefix: "MalinoisItem84")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .free)))
        engines.append(engine)   // this class's tearDown disarms it too, so a red run leaks nothing
        TestIsolation.tearDown()   // a test that never turned the main run loop ends

        EventStore.rootOverrideForTesting = newFolder()   // the next test begins
        UserDefaults.standard.set(true, forKey: owed)   // owing a re-arm to an engine of its own
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))

        XCTAssertTrue(UserDefaults.standard.bool(forKey: owed), "the earlier test's engine took no re-arm")
        XCTAssertEqual(engine.state, .disarmed, "and did not re-arm itself")
    }

    // MARK: - The test runner's app

    /// The app the test runner launches to host these tests builds nothing of its own: no engine,
    /// no event log, nothing listening. Its engine used to answer this suite's notices and write
    /// into its real log (item 85 was found that way).
    func testTheTestRunnersAppBuildsNoServicesOfItsOwn() {
        XCTAssertFalse(MalinoisApp.builtServices, "the test runner's launch starts an empty stand-in")
    }

    /// The rule behind it: the test runner's launch has XCTest in the process, or the runner's
    /// variables in the environment. Any other launch, a Debug build run from Xcode for the device
    /// legs included, is the real app.
    func testTheTestRunnersLaunchIsRecognizedAndNoOtherIs() {
        XCTAssertFalse(TestHost.isTestRunnerLaunch(xcTestLoaded: false, environment: [:]), "a normal launch")
        XCTAssertFalse(TestHost.isTestRunnerLaunch(xcTestLoaded: false, environment: ["OS_ACTIVITY_DT_MODE": "YES"]),
                       "a Debug build run from Xcode")
        XCTAssertTrue(TestHost.isTestRunnerLaunch(xcTestLoaded: true, environment: [:]), "XCTest injected")
        XCTAssertTrue(TestHost.isTestRunnerLaunch(xcTestLoaded: false, environment: ["XCInjectBundleInto": "unused"]),
                      "the runner's variable")
        XCTAssertTrue(TestHost.isTestRunnerLaunch(xcTestLoaded: NSClassFromString("XCTestCase") != nil,
                                                  environment: ProcessInfo.processInfo.environment),
                      "this process, the test runner's")
    }
}
