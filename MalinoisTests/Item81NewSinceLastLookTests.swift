//
//  Item81NewSinceLastLookTests.swift
//  MalinoisTests
//
//  BACKLOG 81 (1.4, the owner's ruling 2026-09-25: option 3): Home's Event Log button counts what
//  is new since the owner last looked, "Event Log (3 new)", hidden at 0, instead of a total that
//  leaves out arm/disarm and sticks at the cap. The owner's ruling 2026-09-26: the app remembers
//  which records were in the log when it was last opened or closed ("remember what I've seen"),
//  so a record that reaches this phone late still counts; the log's history when the feature
//  arrives counts as seen, and so does a restore into an empty log. Written before the change,
//  red at that commit. The launch-pull tests (the 1.4 review, item 89, C1) were written before
//  their fix and were red at that commit too; they drive the pull through the engine's iCloud
//  stand-in.
//

import XCTest
import SwiftUI
@testable import Malinois

@MainActor
final class Item81NewSinceLastLookTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem81-")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func tamper(_ secondsAgo: TimeInterval = 0) -> Event {
        let at = Date().addingTimeInterval(-secondsAgo)
        return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .localOnly)
    }

    private func armed() -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .localOnly, stateChange: "armed")
    }

    private func disarmed() -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: .localOnly, stateChange: "disarmed")
    }

    /// Another device's tamper, as a pull from iCloud brings it. A negative age is a time after now.
    private func mirror(_ secondsAgo: TimeInterval) -> Event {
        let at = Date().addingTimeInterval(-secondsAgo)
        return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .synced,
                     sourceDevice: "iPhone Air")
    }

    /// One launch of a Pro phone: the log as the last launch left it, the entitlement check
    /// resolving, and the launch pull that follows it, answered by `records` when it reaches
    /// iCloud (`reached`) and by nothing when it does not. Returns once the pull has merged what
    /// came back, with the store and how many records the pull asked for.
    private func launch(iCloud records: [Event], reached: Bool) async -> (store: EventStore, asked: Int?) {
        let store = EventStore()
        let entitlements = ProEntitlements.unresolvedForTesting()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store,
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        var asked: Int?
        engine.cloudFetchForTesting = { limit in
            asked = limit
            return (reached ? records : [], reached)
        }
        entitlements.resolveForTesting(as: .trial)
        let deadline = Date().addingTimeInterval(5)
        while (asked == nil || engine.cloudRestoreInProgress) && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(asked, "the launch pull ran")
        return (store, asked)
    }

    // MARK: - The rule

    /// Pure: the records Home counts (everything but arm/disarm and the other state records)
    /// that the owner has not seen; nothing is new until the seen mark exists.
    func testNewMeansNotSeenAndNotAStateRecord() {
        let seenTamper = tamper(60), newTamper = tamper(), state = armed()
        let events = [newTamper, state, seenTamper]
        XCTAssertEqual(EventStore.newRecordCount(in: events, seen: [seenTamper.id]), 1, "the unseen tamper only")
        XCTAssertEqual(EventStore.newRecordCount(in: events, seen: []), 2, "state records never count")
        XCTAssertEqual(EventStore.newRecordCount(in: events, seen: nil), 0, "no mark yet: nothing is new")
    }

    /// Pure: the button's words. No em-dash, hidden at 0.
    func testTheButtonSaysHowManyAreNew() {
        XCTAssertEqual(HomeView.eventLogTitle(newCount: 0), "Event Log")
        XCTAssertEqual(HomeView.eventLogTitle(newCount: 1), "Event Log (1 new)")
        XCTAssertEqual(HomeView.eventLogTitle(newCount: 3), "Event Log (3 new)")
    }

    /// Pure (item 89, C1): what a pull inserts is history when it is dated before the install
    /// (a reinstall, or a new device on the account); anything later is news.
    func testHistoryIsWhatPredatesTheInstall() {
        let installedAt = Date()
        let before = mirror(60), after = mirror(-60)
        XCTAssertEqual(EventStore.historyIDs(inserted: [before, after], installedAt: installedAt), [before.id])
    }

    /// Pure (item 89, C1): the launch pull asks for everything while a restore is owed, however
    /// many rows the log gained meanwhile, as it does for an empty log; one page otherwise.
    func testTheLaunchPullAsksForEverythingWhileARestoreIsOwed() {
        XCTAssertEqual(MonitoringEngine.launchSyncLimit(localEventCount: 2, restoreOwed: true, cap: 500, page: 100), 500)
        XCTAssertEqual(MonitoringEngine.launchSyncLimit(localEventCount: 2, restoreOwed: false, cap: 500, page: 100), 100)
        XCTAssertEqual(MonitoringEngine.launchSyncLimit(localEventCount: 0, restoreOwed: false, cap: 500, page: 100), 500)
    }

    // MARK: - The store

    /// Opening the log (the mark) and what comes after it.
    func testRecordsAfterTheLogWasOpenedAreNewAndStateRecordsAreNot() {
        let store = EventStore()
        store.add(tamper(120))
        store.markAllSeen()
        XCTAssertEqual(store.newRecordCount, 0, "just looked")
        store.add(tamper())
        XCTAssertEqual(store.newRecordCount, 1, "one tamper since")
        store.add(armed())
        XCTAssertEqual(store.newRecordCount, 1, "an arm is not news")
        store.markAllSeen()
        XCTAssertEqual(store.newRecordCount, 0, "looked again")
    }

    /// The first launch with this feature: whatever the log already holds (an update from 1.3.x)
    /// is history, not news.
    func testWhatTheLogHeldBeforeTheFeatureCountsAsSeen() throws {
        let before = EventStore()
        for age in [300.0, 200, 100] { before.add(tamper(age)) }
        let folder = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(EventStore.seenFileName))   // a 1.3.x folder
        let updated = EventStore()
        XCTAssertEqual(updated.newRecordCount, 0, "three old tampers, none new")
        updated.add(tamper())
        XCTAssertEqual(updated.newRecordCount, 1, "the first one after the update is")
    }

    /// The mark is kept with the log, so a relaunch does not forget what the owner saw.
    func testTheMarkSurvivesARelaunch() {
        let first = EventStore()
        first.add(tamper(200))
        first.add(tamper(100))
        first.markAllSeen()
        first.add(tamper())
        let relaunched = EventStore()
        XCTAssertEqual(relaunched.newRecordCount, 1, "two seen before the relaunch, one new")
    }

    /// The authenticated route must clear the badge before publishing the new screen,
    /// without waiting for SwiftUI's appearance/disappearance callbacks to catch up.
    func testLogNavigationClearsSeenCountBeforePublishingOpenAndClose() {
        let store = EventStore()
        store.completeRestore()
        store.add(tamper())
        var presented = false
        var countsAtTransition: [Int] = []
        let destination = Binding(get: { presented }, set: {
            countsAtTransition.append(store.newRecordCount)
            presented = $0
        })
        let route = HomeView.eventLogPresentation(destination, store: store)
        route.wrappedValue = true  // called only after PIN/biometric success
        XCTAssertTrue(presented)
        XCTAssertEqual(countsAtTransition, [0], "the opening screen must observe the cleared count")
        store.mergeFromCloud([mirror(600)])  // a delayed arrival during the visit
        route.wrappedValue = false          // Back or backgrounding
        XCTAssertFalse(presented)
        XCTAssertEqual(countsAtTransition, [0, 0], "Home must see zero on the first return")
        XCTAssertEqual(store.newRecordCount, 0)
    }

    /// A delayed cloud pull that completes after the visit remains unread. Neither a
    /// duplicate dismissal nor a cancelled PIN request is permission to mark it seen.
    func testLateCloudArrivalAfterLogExitStaysNewUntilNextAuthenticatedVisit() async {
        let store = EventStore()
        store.completeRestore()
        var presented = true
        let route = HomeView.eventLogPresentation(Binding(get: { presented }, set: { presented = $0 }), store: store)
        route.wrappedValue = false
        await Task.yield()   // stand in for the suspended pull resuming after navigation
        store.mergeFromCloud([mirror(3600)])
        XCTAssertEqual(store.newRecordCount, 1)
        route.wrappedValue = false   // already closed / PIN cancelled
        XCTAssertEqual(store.newRecordCount, 1, "closing an area that was never reopened cannot acknowledge news")
        route.wrappedValue = true
        XCTAssertEqual(store.newRecordCount, 0, "one authenticated visit suffices")
        route.wrappedValue = false
        XCTAssertEqual(store.newRecordCount, 0)
    }

    // MARK: - The launch pull (the 1.4 review, item 89, C1)

    /// The review's case. A reinstall whose first launch cannot reach iCloud (offline); the owner
    /// arms and disarms; the next launch reaches it. What comes down from before the install is
    /// history, whatever the log gained meanwhile; another device's tamper since the install is
    /// news; and the pull asks for everything, as a restore does.
    func testARestoreThatWaitsPastTheFirstArmIsStillHistory() async {
        let first = await launch(iCloud: [], reached: false)
        first.store.add(armed())
        first.store.add(disarmed())
        let fromBefore = (1...5).map { mirror(Double($0) * 3600) }   // hours before the install
        let next = await launch(iCloud: fromBefore + [mirror(-60)], reached: true)
        XCTAssertEqual(next.store.newRecordCount, 1, "five old tampers are history; the one since the install is news")
        XCTAssertEqual(next.asked, EventStore.maxEvents, "the owed restore asks for everything, not one page")
    }

    /// A phone that only ever receives (the owner's everyday iPhone) keeps an empty log until the
    /// first mirror arrives. When that mirror comes down with a launch pull (its push missed), it
    /// is news: a log that is empty because nothing has happened yet is not a restore.
    func testTheFirstMirrorOnAPhoneThatOnlyReceivesIsNews() async {
        _ = await launch(iCloud: [], reached: true)   // the first launch: iCloud holds nothing yet
        let next = await launch(iCloud: [mirror(-60)], reached: true)
        XCTAssertEqual(next.store.newRecordCount, 1, "the first mirror is news")
    }

    /// A restore counts nothing from before the install (history, not news); once it is
    /// settled, what arrives counts, a late mirror from before the install included.
    func testARestoreIsHistoryButLaterMirrorsAreNews() {
        let store = EventStore()   // a new install: the log starts empty, so a restore is owed
        let restored = (1...5).map { mirror(Double($0) * 100) }
        store.mergeFromCloud(restored)
        XCTAssertEqual(store.newRecordCount, 0, "five restored, none new")
        store.completeRestore()
        store.mergeFromCloud([mirror(3600)])
        XCTAssertEqual(store.newRecordCount, 1, "once the restore is settled, another device's tamper is news")
    }

    /// The owed restore (item 89, C1) is noted when an install first reads an empty log, is still
    /// owed after a relaunch, whatever the log gained, and stays settled once settled.
    func testARestoreIsOwedByANewInstallUntilSettled() {
        let installed = EventStore()
        XCTAssertNotNil(installed.restoreOwedSince, "an empty log on the first read: a restore is owed")
        installed.add(armed())
        XCTAssertNotNil(EventStore().restoreOwedSince, "a relaunch still owes it")
        installed.completeRestore()
        XCTAssertNil(EventStore().restoreOwedSince, "settled, and it stays settled")
    }

    /// An update from 1.3.x: the log already holds records the first time it is read with the
    /// feature, so they are history and no restore is owed.
    func testAnUpdateOwesNoRestore() throws {
        let before = EventStore()
        before.add(tamper(100))
        let folder = try XCTUnwrap(EventStore.rootOverrideForTesting)
        for name in [EventStore.seenFileName, EventStore.restoreOwedFileName] {   // a 1.3.x folder
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        XCTAssertNil(EventStore().restoreOwedSince)
    }
}
