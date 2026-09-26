//
//  Item79RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for BACKLOG 79 (owner-reported 2026-09-20): with a large backlog, the Event
//  Log's spinner stopped while the sync carried on, and only a batch of arm/disarm records
//  landed per pull-to-refresh. Written before the fixes — red at that commit — and each fix
//  turns its own tests green. The pending sweep is driven through a Debug-only seam that stands
//  in for iCloud (the simulator has no CloudKit container), so what these pin is the SWEEP:
//  who it tells that it is running, when it makes another pass, and when it stops.
//

import XCTest
import CloudKit
import Combine
@testable import Malinois

@MainActor
final class Item79RegressionTests: XCTestCase {

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
    }

    /// The characterization timing, with the sweep's waits compressed the same way.
    private static let sweepTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.sweepWaitFloor = 0.05
        t.sweepWaitCeiling = 0.2
        return t
    }()

    nonisolated private static let throttle = CloudExfiltrator.TransientFailure(retryAfter: 30)

    override func setUp() {
        super.setUp()
        EventStore.rootOverrideForTesting = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem79-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDown() {
        if let dir = EventStore.rootOverrideForTesting { try? FileManager.default.removeItem(at: dir) }
        EventStore.rootOverrideForTesting = nil
        super.tearDown()
    }

    /// A Pro engine on a throwaway store. The entitlement resolving at construction fires the
    /// launch sweep once; it finds no iCloud on the simulator and ends, and the short settle
    /// lets it, so every sweep a test then sees is the one the test started.
    private func makeRig() async -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        let store = EventStore()
        let engine = MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                      camera: FakeCamera(),
                                      entitlements: ProEntitlements(resolvedAs: .trial),
                                      timing: Self.sweepTiming)
        // Online is pinned, so the host Mac's own network cannot decide a follow-up pass.
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(nanoseconds: 200_000_000)
        return Rig(engine: engine, store: store)
    }

    /// The caller gets control back after the first pass; the sweep's end is the published
    /// flag dropping, which is what the banner itself watches.
    private func sweepEnds(_ rig: Rig) async {
        await waitUntil(timeout: 5) { !rig.engine.pendingSweepActive }
    }

    /// Arm/disarm audit records that never reached iCloud — the backlog the owner was syncing.
    private func seedUnsynced(_ rig: Rig, count: Int) {
        let base = Date().addingTimeInterval(-3600)
        for i in 0..<count {
            let at = base.addingTimeInterval(Double(i))
            rig.store.add(Event(startDate: at, endDate: at, triggeredSensors: [],
                                cloudSyncState: .localOnly,
                                stateChange: i.isMultiple(of: 2) ? "armed" : "disarmed"))
        }
    }

    private func unsynced(_ rig: Rig) -> Int { EventStore.unsyncedCount(in: rig.store.events) }

    @discardableResult
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    private func ckError(_ code: CKError.Code, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: CKError.errorDomain, code: code.rawValue, userInfo: userInfo)
    }

    // MARK: - The spinner tells the truth (option 1)

    /// The owner's first symptom. The app comes to the foreground and starts a sweep; the owner
    /// opens the Event Log a moment later; the log's own request is turned away at once by the
    /// single-flight guard, the log finishes its pull, and its spinner stops — while the sweep
    /// that turned it away is still uploading. The engine must say a sweep is running, whoever
    /// started it.
    func testASweepStartedElsewhereStillShowsAsRunning() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 3)
        var release = false
        rig.engine.sweepUploadForTesting = { _ in
            while !release { try? await Task.sleep(nanoseconds: 10_000_000) }
            return (.synced, nil)
        }

        // The foreground or a reconnect starts the sweep, not the Event Log.
        let sweep = Task { await rig.engine.retryPendingSync() }
        let shown = await waitUntil(timeout: 2) { rig.engine.pendingSweepActive }
        XCTAssertTrue(shown, "a running sweep says so, whoever started it")

        // The log opens mid-sweep: its request returns at once…
        await rig.engine.retryPendingSync()
        // …and that return is not the sweep ending.
        XCTAssertTrue(rig.engine.pendingSweepActive, "the log's request returning is not the sweep ending")
        XCTAssertTrue(EventLogView.bannerShowsSpinner(viewRetrying: false,
                                                      sweepActive: rig.engine.pendingSweepActive))

        release = true
        await sweep.value
        XCTAssertFalse(rig.engine.pendingSweepActive, "the flag drops when the sweep is done")
        XCTAssertEqual(unsynced(rig), 0)
    }

    /// Pure: the banner's spinner shows for the screen's own request OR for the engine's sweep.
    func testTheBannerSpinnerFollowsTheEngineSweep() {
        XCTAssertTrue(EventLogView.bannerShowsSpinner(viewRetrying: true, sweepActive: false))
        XCTAssertTrue(EventLogView.bannerShowsSpinner(viewRetrying: false, sweepActive: true))
        XCTAssertTrue(EventLogView.bannerShowsSpinner(viewRetrying: true, sweepActive: true))
        XCTAssertFalse(EventLogView.bannerShowsSpinner(viewRetrying: false, sweepActive: false))
    }

    /// Pure: between passes the count stops moving, and the banner says why. iCloud being
    /// unavailable is the bigger news and keeps its own line.
    func testTheBannerSaysWhyTheCountHasStoppedMoving() {
        XCTAssertNil(EventLogView.bannerCaption(accountReady: true, sweepWaiting: false))
        XCTAssertEqual(EventLogView.bannerCaption(accountReady: true, sweepWaiting: true),
                       "Uploads are paused for a moment. The rest will continue automatically.")
        XCTAssertEqual(EventLogView.bannerCaption(accountReady: false, sweepWaiting: true),
                       EventLogView.bannerCaption(accountReady: false, sweepWaiting: false))
        XCTAssertEqual(EventLogView.bannerCaption(accountReady: false, sweepWaiting: false)?.hasPrefix("Sign in to iCloud"), true)
    }

    // MARK: - The sweep finishes the job (option 2)

    /// The owner's second symptom. iCloud takes the first records of a large backlog and then
    /// answers "slow down"; the sweep used to make its one pass, fail the rest, and leave them
    /// until the next pull-to-refresh. ONE trigger must now carry the whole backlog up.
    func testAThrottledSweepFinishesWithoutAnotherTrigger() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 8)
        var calls = 0
        var throttled = false
        rig.engine.sweepUploadForTesting = { _ in
            calls += 1
            if calls == 3 {   // iCloud takes the first two, then says slow down, once
                throttled = true
                return (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: 0.05))
            }
            return (.synced, nil)
        }

        await rig.engine.retryPendingSync()
        await sweepEnds(rig)

        XCTAssertTrue(throttled)
        XCTAssertEqual(unsynced(rig), 0, "one trigger carries the whole backlog up, across the throttle")
        XCTAssertFalse(rig.engine.pendingSweepActive)
    }

    /// A throttle ends the pass: what is in flight finishes, and the rest waits for the
    /// follow-up pass instead of each spending its attempts against a door the server has just
    /// said is closed. The wait between passes is published, so the banner can say why the
    /// count has stopped moving.
    func testAThrottleEndsThePassAndTheWaitIsPublished() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 12)
        var sawWaiting = false
        let sub = rig.engine.$pendingSweepWaiting.sink { if $0 { sawWaiting = true } }
        defer { sub.cancel() }
        var firstPassCalls = 0
        rig.engine.sweepUploadForTesting = { _ in
            if sawWaiting { return (.synced, nil) }   // the follow-up pass: the door is open again
            firstPassCalls += 1
            return (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: 0.05))
        }

        await rig.engine.retryPendingSync()
        // The caller is released after the first pass — the log's pull and the launch restore
        // follow this call, and must not sit behind the wait — while the sweep carries on.
        XCTAssertTrue(rig.engine.pendingSweepActive, "the sweep outlives the call that started it")
        XCTAssertTrue(rig.engine.pendingSweepWaiting)
        await sweepEnds(rig)

        XCTAssertLessThanOrEqual(firstPassCalls, 3, "only what was in flight spends an attempt on a closed door")
        XCTAssertTrue(sawWaiting, "the wait between passes is published for the banner")
        XCTAssertFalse(rig.engine.pendingSweepWaiting, "and cleared when the sweep moves on")
        XCTAssertEqual(unsynced(rig), 0)
    }

    /// One record that cannot get through — a large clip stalling on a slow link fails the same
    /// way a lost path does, with no wait named — must not hold the others back: the first pass
    /// carries up everything else, as it always did, and the sweep's retries of the one are
    /// bounded.
    func testOneRecordThatCannotGetThroughDoesNotHoldTheOthersBack() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 8)
        guard let stuck = rig.store.events.first?.id else { return XCTFail("nothing seeded") }
        var leftAtFirstWait: Int?
        let sub = rig.engine.$pendingSweepWaiting.sink { waiting in
            if waiting, leftAtFirstWait == nil { leftAtFirstWait = EventStore.unsyncedCount(in: rig.store.events) }
        }
        defer { sub.cancel() }
        var stuckCalls = 0
        rig.engine.sweepUploadForTesting = { event in
            guard event.id == stuck else { return (.synced, nil) }
            stuckCalls += 1
            return (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: nil))
        }

        await rig.engine.retryPendingSync()
        await sweepEnds(rig)

        XCTAssertEqual(leftAtFirstWait, 1, "the first pass carried up everything but the one")
        XCTAssertEqual(unsynced(rig), 1)
        XCTAssertGreaterThan(stuckCalls, 1, "the one is retried by the sweep itself")
        XCTAssertLessThanOrEqual(stuckCalls, 1 + MonitoringEngine.sweepMaxIdlePasses, "and the retries are bounded")
        XCTAssertFalse(rig.engine.pendingSweepActive)
    }

    /// An outage with the path still reported up: every save fails and the server names no
    /// wait. Three failures in a row end each pass, and three passes that land nothing end the
    /// sweep — a sweep over a large backlog used to spend every record's attempts on it.
    func testAnOutageSpendsFewAttemptsAndStops() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 12)
        var calls = 0
        rig.engine.sweepUploadForTesting = { _ in
            calls += 1
            return (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: nil))
        }

        await rig.engine.retryPendingSync()
        await sweepEnds(rig)

        XCTAssertEqual(unsynced(rig), 12)
        XCTAssertLessThanOrEqual(calls, 15, "at most five attempts a pass (three, plus two already handed out), three passes")
        XCTAssertFalse(rig.engine.pendingSweepActive)
        XCTAssertFalse(rig.engine.pendingSweepWaiting)
    }

    /// A refusal — a full iCloud, a signed-out account — is an answer, not a closed door: one
    /// pass, no wait, and the records stay for the next trigger to re-ask.
    func testARefusalGetsOnePassAndNoFollowUp() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 5)
        var sawWaiting = false
        let sub = rig.engine.$pendingSweepWaiting.sink { if $0 { sawWaiting = true } }
        defer { sub.cancel() }
        var calls = 0
        rig.engine.sweepUploadForTesting = { _ in
            calls += 1
            return (.localOnly, nil)
        }

        await rig.engine.retryPendingSync()

        XCTAssertEqual(calls, 5, "every record gets its one attempt")
        XCTAssertFalse(sawWaiting)
        XCTAssertEqual(unsynced(rig), 5)
        XCTAssertFalse(rig.engine.pendingSweepActive)
    }

    /// Offline, the reconnect trigger owns the retry: the sweep does not sit in a wait loop
    /// against a path that is not there.
    func testNoFollowUpPassWhileOffline() async {
        let rig = await makeRig()
        seedUnsynced(rig, count: 5)
        rig.engine.simulateConnectivityForTesting(online: false)
        var sawWaiting = false
        let sub = rig.engine.$pendingSweepWaiting.sink { if $0 { sawWaiting = true } }
        defer { sub.cancel() }
        rig.engine.sweepUploadForTesting = { _ in
            (.localOnly, CloudExfiltrator.TransientFailure(retryAfter: nil))
        }

        await rig.engine.retryPendingSync()

        XCTAssertFalse(sawWaiting, "offline: the reconnect trigger owns the retry")
        XCTAssertEqual(unsynced(rig), 5)
        XCTAssertFalse(rig.engine.pendingSweepActive)
    }

    // MARK: - The pure rules

    private func delay(remaining: Int = 10,
                       transient: CloudExfiltrator.TransientFailure? = Item79RegressionTests.throttle,
                       online: Bool = true, pass: Int = 1, idle: Int = 0) -> TimeInterval? {
        MonitoringEngine.sweepFollowUpDelay(remaining: remaining, transient: transient, online: online,
                                            pass: pass, idlePasses: idle, floor: 2, ceiling: 120)
    }

    func testTheFollowUpDelayRule() {
        XCTAssertEqual(delay(), 30, "the server's own number")
        XCTAssertEqual(delay(transient: .init(retryAfter: 600)), 120, "never longer than the ceiling")
        XCTAssertEqual(delay(transient: .init(retryAfter: 0.1)), 2, "never shorter than the floor")
        XCTAssertEqual(delay(transient: .init(retryAfter: nil)), 2, "no hint: the floor")
        XCTAssertEqual(delay(transient: .init(retryAfter: nil), idle: 2), 8, "no hint and no progress: doubling")
        XCTAssertEqual(delay(transient: .init(retryAfter: .nan)), 2, "a hint that is not a number: the floor")

        XCTAssertNil(delay(remaining: 0), "nothing left")
        XCTAssertNil(delay(transient: nil), "a refusal earns no follow-up")
        XCTAssertNil(delay(online: false), "offline: the reconnect trigger owns it")
        XCTAssertNil(delay(pass: MonitoringEngine.sweepMaxPasses), "the pass cap")
        XCTAssertNil(delay(idle: MonitoringEngine.sweepMaxIdlePasses), "passes that land nothing, in a row")
    }

    func testWhenAPassStopsHandingOutRecords() {
        let named = CloudExfiltrator.TransientFailure(retryAfter: 30)
        let unnamed = CloudExfiltrator.TransientFailure(retryAfter: nil)
        XCTAssertTrue(MonitoringEngine.sweepDoorClosed(transient: named, failuresInARow: 1),
                      "the server named a wait: at once")
        XCTAssertTrue(MonitoringEngine.sweepDoorClosed(transient: named, failuresInARow: 0),
                      "even when this record landed: the answer is about the device, not the record")
        XCTAssertFalse(MonitoringEngine.sweepDoorClosed(transient: unnamed, failuresInARow: 1),
                       "one record that cannot get through holds nobody back")
        XCTAssertFalse(MonitoringEngine.sweepDoorClosed(transient: unnamed, failuresInARow: 2))
        XCTAssertTrue(MonitoringEngine.sweepDoorClosed(transient: unnamed,
                                                       failuresInARow: MonitoringEngine.sweepMaxFailuresInARow),
                      "an outage: everything handed out has failed")
        XCTAssertFalse(MonitoringEngine.sweepDoorClosed(transient: nil, failuresInARow: 10),
                       "refusals never close it: each record gets its one attempt")
    }

    /// A save that gave up tells the sweep why: transient or not, and the server's own
    /// Retry-After uncapped — the 4 s ceiling is for trigger-time pushes and stays there.
    func testASaveThatGaveUpTellsTheSweepWhy() {
        let throttled = ckError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: 30.0])
        XCTAssertEqual(CloudExfiltrator.transientFailure(from: throttled),
                       CloudExfiltrator.TransientFailure(retryAfter: 30))
        XCTAssertEqual(CloudExfiltrator.retryDelay(for: throttled, attempt: 1), 4,
                       "the trigger-time cap stands")

        let partial = ckError(.partialFailure,
                              userInfo: [CKPartialErrorsByItemIDKey: [UUID(): ckError(.zoneBusy)]])
        XCTAssertEqual(CloudExfiltrator.transientFailure(from: partial),
                       CloudExfiltrator.TransientFailure(retryAfter: nil),
                       "a per-record throttle inside a partial failure counts")

        let nonsense = ckError(.requestRateLimited, userInfo: [CKErrorRetryAfterKey: -5.0])
        XCTAssertEqual(CloudExfiltrator.transientFailure(from: nonsense),
                       CloudExfiltrator.TransientFailure(retryAfter: nil),
                       "a hint that is not a usable number is no hint")

        // Several saves can give up inside one pass: the longest wait the server named stands.
        let cloud = CloudExfiltrator()
        XCTAssertNil(cloud.lastTransientFailure)
        cloud.noteTransientFailure(.init(retryAfter: 10))
        cloud.noteTransientFailure(.init(retryAfter: 30))
        cloud.noteTransientFailure(.init(retryAfter: nil))
        XCTAssertEqual(cloud.lastTransientFailure, CloudExfiltrator.TransientFailure(retryAfter: 30))
        cloud.clearTransientFailure()
        XCTAssertNil(cloud.lastTransientFailure)
        cloud.noteTransientFailure(.init(retryAfter: nil))
        XCTAssertEqual(cloud.lastTransientFailure, CloudExfiltrator.TransientFailure(retryAfter: nil))

        XCTAssertNil(CloudExfiltrator.transientFailure(from: ckError(.quotaExceeded)))
        XCTAssertNil(CloudExfiltrator.transientFailure(from: ckError(.limitExceeded)))
        XCTAssertNil(CloudExfiltrator.transientFailure(from: ckError(.notAuthenticated)))
        XCTAssertNil(CloudExfiltrator.transientFailure(from: NSError(domain: "x", code: 1)))
    }

    // MARK: - The device legs' seeded backlog (Debug builds only)

    /// The seed stands in for the owner's long stretch in Airplane Mode: arm/disarm records, none
    /// uploaded, first-hand (not mirrors, which the sweep would skip), oldest first, one second apart.
    func testTheSeededBacklogLooksLikeALongOfflineStretch() {
        let end = Date(timeIntervalSince1970: 1_000_000)
        let seeded = EventStore.seededBacklog(count: 4, endingAt: end)
        XCTAssertEqual(seeded.map(\.stateChange), ["armed", "disarmed", "armed", "disarmed"])
        XCTAssertEqual(seeded.map(\.startDate), [-3.0, -2, -1, 0].map { end.addingTimeInterval($0) })
        XCTAssertTrue(seeded.allSatisfy { $0.cloudSyncState == .localOnly && !$0.isMirrored })
        XCTAssertTrue(EventStore.seededBacklog(count: 0, endingAt: end).isEmpty)
        XCTAssertTrue(EventStore.seededBacklog(count: -1, endingAt: end).isEmpty)
    }

    /// Test data never evicts an event only this device holds: the seed uses the free room, then
    /// only as much as there are mirrored copies for the log to drop (iCloud still holds them).
    func testTheSeedMakesRoomOnlyByDroppingCopies() {
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 0, cap: 500, mirrored: 0), 100)
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 450, cap: 500, mirrored: 0), 50)
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 500, cap: 500, mirrored: 0), 0,
                       "full of this device's own events: nothing")
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 600, cap: 500, mirrored: 0), 0)
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 500, cap: 500, mirrored: 30), 30,
                       "full: as many as there are copies")
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 500, cap: 500, mirrored: 300), 100)
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 450, cap: 500, mirrored: 20), 70,
                       "the free room, then the copies")
        XCTAssertEqual(EventStore.seedRoom(requested: 100, current: 500, cap: 500, mirrored: -5), 0)
    }

    /// The owner's Air, 2026-09-25: the log was at its cap and the seed added nothing. Through the
    /// real store at the real cap: seeding drops only the oldest mirrored copies, and every event
    /// this device captured stays.
    func testSeedingAtTheCapDropsOnlyCopies() {
        let store = EventStore()
        let old = Date().addingTimeInterval(-86_400)
        let copies = (0..<(EventStore.maxEvents - 3)).map { i in
            Event(startDate: old.addingTimeInterval(Double(i)), endDate: old.addingTimeInterval(Double(i)),
                  triggeredSensors: [.motion], cloudSyncState: .synced, sourceDevice: "Another iPhone")
        }
        _ = store.merge(copies)
        let ownIDs = (0..<3).map { _ in
            let e = Event(startDate: Date().addingTimeInterval(-600), endDate: Date().addingTimeInterval(-600),
                          triggeredSensors: [.touch], cloudSyncState: .localOnly)
            store.add(e)
            return e.id
        }
        XCTAssertEqual(store.events.count, EventStore.maxEvents, "the log starts full")

        let result = store.seedUnsyncedBacklogForTesting(count: 100)

        XCTAssertEqual(result.added, 100)
        XCTAssertEqual(result.droppedCopies, 100)
        XCTAssertEqual(store.events.count, EventStore.maxEvents)
        XCTAssertEqual(store.events.filter(\.isMirrored).count, EventStore.maxEvents - 3 - 100)
        XCTAssertTrue(ownIDs.allSatisfy { id in store.events.contains { $0.id == id } },
                      "every event this device captured stays")
    }

    /// Through the real store: the seeded rows land newest-first, all counted as not yet synced,
    /// beside what was already there.
    func testSeedingAddsNewestFirstAndCountsAsUnsynced() {
        let store = EventStore()
        let real = Event(startDate: Date().addingTimeInterval(-600), endDate: Date().addingTimeInterval(-600),
                         triggeredSensors: [.motion], cloudSyncState: .synced)
        store.add(real)

        let result = store.seedUnsyncedBacklogForTesting(count: 6)

        XCTAssertEqual(result.added, 6)
        XCTAssertEqual(result.droppedCopies, 0)
        XCTAssertEqual(store.events.count, 7)
        XCTAssertEqual(EventStore.unsyncedCount(in: store.events), 6)
        XCTAssertEqual(store.events.map(\.startDate), store.events.map(\.startDate).sorted(by: >),
                       "the log stays newest-first")
        XCTAssertEqual(store.events.first?.stateChange, "disarmed")
        XCTAssertEqual(store.events.last?.id, real.id, "the real event is untouched, and oldest")
    }
}
