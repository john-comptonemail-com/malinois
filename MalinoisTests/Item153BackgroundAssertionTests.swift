//
//  Item153BackgroundAssertionTests.swift
//  MalinoisTests
//
//  BACKLOG 153's MAL-01, item 145 step 18 (ADR 0003 amended). The extra running time iOS grants an app whose scene
//  has left the foreground is asked for with a background-task assertion. Every cloud push asked for it only once
//  its identity lookup and its queue wait were over, and the engine spawned its push tasks without one, so the lapse
//  record written as the phone was locked, and a trip's fact pushed just before a lock or a kill, ran unprotected
//  through their first step. Now each push begins its assertion before the lookup and ends it on every return, and
//  the engine holds one from before it spawns a push task. The provider is a seam: the recorder here sees each begin
//  and end in order against the identity lookup it also observes. Written before the change, red at that commit
//  (against the seam alone, the assertions where they were).
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item153BackgroundAssertionTests: XCTestCase {
    nonisolated private static let lapseKey = "com.malinois.armed.backgroundLapseLogged"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem153Assertion")
        UserDefaults.standard.removeObject(forKey: Self.lapseKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.lapseKey)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// What the provider and the identity lookup saw, in order: "begin <name>", "lookup", "end <name>".
    @MainActor
    private final class Timeline {
        private(set) var entries: [String] = []
        private var names: [Int: String] = [:]
        func note(_ entry: String) { entries.append(entry) }

        var provider: BackgroundAssertion.Provider {
            BackgroundAssertion.Provider(
                begin: { [self] name, _ in
                    let id = UIBackgroundTaskIdentifier(rawValue: names.count + 1)
                    names[id.rawValue] = name
                    note("begin \(name)")
                    return id
                },
                end: { [self] id in note("end \(names[id.rawValue] ?? "?")") })
        }

        var begins: Int { entries.filter { $0.hasPrefix("begin") }.count }
        var ends: Int { entries.filter { $0.hasPrefix("end") }.count }
        var lookups: Int { entries.filter { $0 == "lookup" }.count }

        /// The first thing is a begin, the lookup ran after it, every begin has its end, and the last thing is an end.
        func assertCovered(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(entries.first?.hasPrefix("begin") == true, "the first thing is a begin: \(entries)",
                          file: file, line: line)
            XCTAssertGreaterThanOrEqual(lookups, 1, "the lookup ran: \(entries)", file: file, line: line)
            XCTAssertEqual(begins, ends, "every begin has its end: \(entries)", file: file, line: line)
            XCTAssertTrue(entries.last?.hasPrefix("end") == true, "the last thing is an end: \(entries)",
                          file: file, line: line)
        }
    }

    private struct CloudRig {
        let policy: CloudEnrollment
        let cloud: CloudExfiltrator
        let directory: URL
    }

    /// A verified installation on "account-A" whose saves land at once, the recorder and the observed lookup
    /// installed after the verification so the timeline holds only the push under test.
    private func verifiedRig(_ timeline: Timeline) async throws -> CloudRig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let policy = CloudEnrollment(file: directory.appendingPathComponent("enrollment.json"), authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let enrolled = await cloud.enrollCloudAccess()
        try XCTSkipUnless(enrolled, "the enrollment could not be written")
        cloud.saveAttemptForTesting = { _ in }
        cloud.accountIdentityForTesting = { timeline.note("lookup"); return "account-A" }
        BackgroundAssertion.providerForTesting = timeline.provider
        return CloudRig(policy: policy, cloud: cloud, directory: directory)
    }

    private func touchEvent(_ rig: CloudRig) -> Event {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        rig.policy.registerLocalEvent(event)
        return event
    }

    private func statusEvent(_ rig: CloudRig) -> Event {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [])
        event.stateChange = "armed"
        rig.policy.registerLocalEvent(event)
        return event
    }

    /// Waits for `condition`, yielding the main actor meanwhile (an async test holds the actor; the tasks under test
    /// run only while this awaits).
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    // MARK: - The three pushes

    /// The fact push begins its assertion before the identity lookup runs and ends it after the push returns.
    func testTheFactPushBeginsItsAssertionBeforeTheIdentityLookup() async throws {
        let timeline = Timeline()
        let rig = try await verifiedRig(timeline)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let landed = await rig.cloud.pushFact(touchEvent(rig))
        XCTAssertTrue(landed, "the push landed: \(timeline.entries)")
        timeline.assertCovered()
    }

    /// The evidence push the same: its lease attempt is its first step.
    func testTheEvidencePushBeginsItsAssertionBeforeTheIdentityLookup() async throws {
        let timeline = Timeline()
        let rig = try await verifiedRig(timeline)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let outcome = await rig.cloud.exfiltrate(touchEvent(rig), fullMediaURL: nil)
        XCTAssertNotEqual(outcome.syncState, .localOnly, "the push landed: \(timeline.entries)")
        timeline.assertCovered()
    }

    /// The status push the same.
    func testTheStatusPushBeginsItsAssertionBeforeTheIdentityLookup() async throws {
        let timeline = Timeline()
        let rig = try await verifiedRig(timeline)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let landed = await rig.cloud.pushStateChange(statusEvent(rig))
        XCTAssertTrue(landed, "the push landed: \(timeline.entries)")
        timeline.assertCovered()
    }

    // MARK: - Every return

    /// A lookup that fails for want of a network denies the push, and one that finds no account declines it: the
    /// assertion begun before the lookup ends on those returns too, one begin, the lookup, one end.
    func testADeniedOrDeclinedPushStillEndsItsAssertion() async throws {
        let denied = Timeline()
        let rig = try await verifiedRig(denied)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let event = touchEvent(rig)
        rig.cloud.accountIdentityForTesting = { denied.note("lookup"); throw CKError(.networkFailure) }
        let outcome = await rig.cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(outcome.syncState, .localOnly, "denied for want of a network")
        denied.assertCovered()
        XCTAssertEqual(denied.entries.count, 3, "one begin, the lookup, one end: \(denied.entries)")

        let declined = Timeline()
        BackgroundAssertion.providerForTesting = declined.provider
        rig.cloud.accountIdentityForTesting = { declined.note("lookup"); return nil }   // iCloud: no account
        let pushed = await rig.cloud.pushFact(event)
        XCTAssertFalse(pushed, "no account declines the push")
        declined.assertCovered()
        XCTAssertEqual(declined.entries.count, 3, "one begin, the lookup, one end: \(declined.entries)")
    }

    // MARK: - The engine's spawns

    private struct EngineRig {
        let engine: MonitoringEngine
        let store: EventStore
        let cloud: CloudExfiltrator
    }

    /// A trial install verified on "account-A", armed with no grace when asked, saves landing at once, the recorder
    /// and the observed lookup installed last.
    private func engineRig(_ timeline: Timeline, armed: Bool) async throws -> EngineRig {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let policy = CloudEnrollment(file: root.appendingPathComponent("enrollment-153/state.json"),
                                     authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.responseMode = .alert
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming,
                                                          thermalState: { .nominal }))
        let enrolled = await cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled, "the verification succeeded")
        await engine.cloudAccessVerified()
        if armed {
            engine.beginArming()
            engine.confirmGuidedAccessAndStartGrace()
            let live = await waitFor({ engine.state == .armed }, timeout: 5)
            XCTAssertTrue(live, "grace 0 + calibration + review reach .armed")
        }
        // The verification queues a sweep and a pull of its own; let them finish before the recorder goes in, or
        // their lookups and the sweep's push of the record under test land on the timeline (the first run: the
        // disarmed rig had no arming wait to absorb them).
        let settled = await settle(engine, cloud)
        XCTAssertTrue(settled, "the verification's own cloud work finished")
        cloud.saveAttemptForTesting = { _ in }
        cloud.accountIdentityForTesting = { timeline.note("lookup"); return "account-A" }
        BackgroundAssertion.providerForTesting = timeline.provider
        return EngineRig(engine: engine, store: store, cloud: cloud)
    }

    /// Waits until no sweep is active and the identity lookup has been quiet for 300 ms, within 10 s.
    private func settle(_ engine: MonitoringEngine, _ cloud: CloudExfiltrator) async -> Bool {
        var lookups = 0
        cloud.accountIdentityForTesting = { lookups += 1; return "account-A" }
        var seen = 0
        var quietSince = Date()
        return await waitFor({
            if lookups != seen { seen = lookups; quietSince = Date() }
            return !engine.pendingSweepActive && Date().timeIntervalSince(quietSince) > 0.3
        }, timeout: 10)
    }

    /// The lapse record written as the scene leaves the foreground holds an assertion before its push task runs: a
    /// begin is on the timeline before the call returns, with no lookup yet, and the push then runs under it.
    func testTheLapseRecordHoldsAnAssertionBeforeItsPushTaskRuns() async throws {
        let timeline = Timeline()
        let rig = try await engineRig(timeline, armed: true)
        rig.engine.handleEnteredBackground()
        XCTAssertTrue(timeline.entries.first?.hasPrefix("begin") == true,
                      "held before the push task runs, while the scene is still leaving: \(timeline.entries)")
        XCTAssertEqual(timeline.lookups, 0, "the push task has not run yet: \(timeline.entries)")
        let pushed = await waitFor({ timeline.lookups >= 1 && timeline.begins == timeline.ends }, timeout: 5)
        XCTAssertTrue(pushed, "the push ran and every assertion ended: \(timeline.entries)")
        timeline.assertCovered()
        XCTAssertTrue(rig.store.events.contains { $0.interrupted == true }, "the lapse left its record")
        rig.engine.disarm()
    }

    /// A status record holds an assertion before its push task runs, the same way.
    func testAStatusRecordHoldsAnAssertionBeforeItsPushTaskRuns() async throws {
        let timeline = Timeline()
        let rig = try await engineRig(timeline, armed: false)
        rig.engine.logStateChange("armed")
        XCTAssertTrue(timeline.entries.first?.hasPrefix("begin") == true,
                      "held before the push task runs: \(timeline.entries)")
        XCTAssertEqual(timeline.lookups, 0, "the push task has not run yet: \(timeline.entries)")
        let pushed = await waitFor({ timeline.lookups >= 1 && timeline.begins == timeline.ends }, timeout: 5)
        XCTAssertTrue(pushed, "the push ran and every assertion ended: \(timeline.entries)")
        timeline.assertCovered()
        XCTAssertTrue(rig.store.events.contains { $0.stateChange == "armed" }, "the record is in the log")
    }
}
