//
//  Item86RegressionTests.swift
//  MalinoisTests
//
//  Regression tests for BACKLOG 86 (1.4) and its follow-up from the 2026-09-28 review. The event
//  log must tell a SEALED file (Data Protection still holding the key: the phone locked, or an
//  instant from unlocking) from a DAMAGED one: setting a sealed, healthy log aside strands the
//  evidence (V-01), and leaving a damaged one in place refuses every write.
//
//  Item 86 first asked UIKit, whose answer inside `MalinoisApp.init` is "locked" even on an
//  unlocked phone (ADR 0016), and ended the wait when the app became active, on the premise that
//  an app on screen means an unlocked phone. The review found the app's own record of the
//  opposite (KeychainService and RootView, found live 2026-08-30): a lock-screen notification tap
//  can make the app active in the instant before the keys arrive, where a healthy log would have
//  been set aside. The rule now: bytes that can be read but not decoded are damaged whatever the
//  lock state, and are set aside at once; bytes that cannot be read wait, and are set aside only
//  when UIKit says the phone is unlocked (at launch, at the unlock notice, or when the app becomes
//  active and the read is tried again).
//
//  A file with its read permission removed stands in for a sealed one (the Simulator has no Data
//  Protection); the store's `protectedDataAvailable` seam gives UIKit's answer.
//

import XCTest
@testable import Malinois

@MainActor
final class Item86RegressionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem86")
    }

    override func tearDown() {
        unseal()   // so the folder can be read and removed
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func root() throws -> URL {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    nonisolated private var logURL: URL? { EventStore.rootOverrideForTesting?.appendingPathComponent("events.json") }

    /// A log on disk that can be read but not decoded: what a damaged file looks like.
    private func plantDamagedLog() throws {
        try Data("not json".utf8).write(to: root().appendingPathComponent("events.json"))
    }

    /// A readable, healthy log on disk holding `events`.
    private func plantLog(_ events: [Event]) throws {
        try JSONEncoder().encode(events).write(to: root().appendingPathComponent("events.json"))
    }

    /// Stands in for Data Protection: the file's contents can no longer be read.
    private func seal() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: XCTUnwrap(logURL).path)
    }

    /// The keys arrive: the contents can be read again.
    nonisolated private func unseal() {
        guard let path = logURL?.path, FileManager.default.fileExists(atPath: path) else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }

    private func backups() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root().path).filter { $0.hasPrefix("events.corrupt-") }
    }

    /// The ids in the log on disk, or nil while it cannot be read.
    private func idsOnDisk() -> Set<UUID>? {
        guard let url = logURL, let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([Event].self, from: data) else { return nil }
        return Set(events.map(\.id))
    }

    private func motionEvent(secondsAgo: TimeInterval = 0) -> Event {
        let at = Date().addingTimeInterval(-secondsAgo)
        return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .localOnly)
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Spins the main run loop for `seconds`: the wait a test needs when what it checks is that
    /// nothing more happens.
    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    // MARK: - A damaged log

    /// Bytes that can be read but not decoded are damaged, whatever UIKit says about the lock: a
    /// sealed file cannot be read at all. The log is set aside at launch, and Home is told.
    func testADamagedLogIsSetAsideAtOnceEvenWhenTheLaunchReadsLocked() throws {
        try plantDamagedLog()
        let store = EventStore(protectedDataAvailable: { false })   // UIKit's answer inside MalinoisApp.init
        XCTAssertTrue(store.logWasQuarantined, "damaged, whatever the lock state: set aside at once")
        XCTAssertEqual(try backups().count, 1, "preserved as a backup, not clobbered")
    }

    /// Records made after a damaged log was set aside reach the new log. Before, every write was
    /// refused until an unlock notice an unlocked phone never sends.
    func testRecordsAfterADamagedLogWasSetAsideAreWritten() throws {
        try plantDamagedLog()
        let store = EventStore(protectedDataAvailable: { false })
        let recorded = motionEvent()
        store.add(recorded)
        XCTAssertTrue(pump(until: { self.idsOnDisk()?.contains(recorded.id) == true }, timeout: 3),
                      "the record is written to the new log")
    }

    // MARK: - A sealed log

    /// A healthy log that cannot be read at launch waits (V-01), and once it can be read it is
    /// loaded with what was recorded meanwhile.
    func testASealedLogWaitsAndIsLoadedWithWhatWasRecordedOnceReadable() throws {
        let earlier = motionEvent(secondsAgo: 60)
        try plantLog([earlier])
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertFalse(store.logWasQuarantined, "sealed: it waits")
        let recorded = motionEvent()
        store.add(recorded)
        unseal()
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.events.contains { $0.id == earlier.id } }, timeout: 3), "loaded at the unlock")
        XCTAssertTrue(store.events.contains { $0.id == recorded.id }, "with what was recorded meanwhile")
        XCTAssertEqual(try backups().count, 0)
    }

    /// The review's case: the app becomes active in the instant before the keys arrive (a
    /// lock-screen notification tap). The log is still sealed and UIKit still says so: it must
    /// not be set aside. When the keys arrive, it is loaded.
    func testASealedLogIsNotSetAsideWhenTheAppBecomesActiveBeforeTheKeysArrive() throws {
        let earlier = motionEvent(secondsAgo: 60)
        try plantLog([earlier])
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        settle(0.3)
        XCTAssertFalse(store.logWasQuarantined, "still sealed: the healthy log is not set aside")
        XCTAssertEqual(try backups().count, 0)
        unseal()
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.events.contains { $0.id == earlier.id } }, timeout: 3),
                      "the keys arrive: the log is loaded, nothing lost")
    }

    /// A log whose contents still cannot be read once UIKit says the phone is unlocked is broken,
    /// not sealed: set aside when the app becomes active and the read is tried again.
    func testAnUnreadableLogIsSetAsideOnceUIKitSaysThePhoneIsUnlocked() throws {
        try plantLog([motionEvent(secondsAgo: 60)])
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertFalse(store.logWasQuarantined, "at launch it waits")
        phone.unlocked = true   // the phone is unlocked, and the file still cannot be read
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { store.logWasQuarantined }, timeout: 3), "broken, not sealed: set aside, and Home says so")
        XCTAssertEqual(try backups().count, 1)
    }

    /// After a log that waited for the unlock turns out broken and is set aside, records are
    /// written again: the set-aside ends the wait, or every write stays refused for the rest of
    /// the process with nothing on Home saying so (32.R4). The damaged-at-launch test above never
    /// waited, so it could not show this (test-suite audit, WB32).
    func testRecordsAfterADeferredLogWasSetAsideAreWritten() throws {
        try plantLog([motionEvent(secondsAgo: 60)])
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        phone.unlocked = true   // unlocked, and the file still cannot be read: broken
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { store.logWasQuarantined }, timeout: 3), "set aside")
        let recorded = motionEvent()
        store.add(recorded)
        XCTAssertTrue(pump(until: { self.idsOnDisk()?.contains(recorded.id) == true }, timeout: 3),
                      "the record is written to the new log")
    }

    /// An upgrade may first read its old log at unlock, with a new record queued.
    /// Status migration must preserve watch IDs and retire all obsolete journal lines.
    func testLegacyRetentionMigrationAfterUnlockKeepsQueuedIncidentAndWatchRegistry() throws {
        let now = Date()
        let status = (0..<150).map { i in
            Event(startDate: now.addingTimeInterval(-Double(i + 1)), endDate: now,
                  triggeredSensors: [], stateChange: "armed")
        }
        try plantLog(status)
        try seal()
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertTrue(MonitoringEngine.beatSessions().isEmpty)
        let recorded = motionEvent()
        store.add(recorded)
        // Older matching journal lines plus an in-memory queued incident exercise the
        // unlock reconciliation path even when journal recovery has no missing IDs.
        let journal = try root().appendingPathComponent("events.journal")
        let lines = status.reduce(into: Data()) { $0.append(EventStore.journalLine(for: $1)!) }
        try lines.write(to: journal)
        unseal()
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.events.count == 101 }, timeout: 3))
        XCTAssertTrue(store.events.contains { $0.id == recorded.id })
        XCTAssertEqual(Set(MonitoringEngine.beatSessions().map(\.id)), Set(status.map(\.id)))
        XCTAssertTrue(pump(until: { !FileManager.default.fileExists(atPath: journal.path) }, timeout: 3),
                      "obsolete journal lines must retire in the same upgrade session")
    }

    // MARK: - A normal launch

    /// A log read cleanly at launch is left alone when the app becomes active: nothing reloaded,
    /// nothing set aside.
    func testALogReadCleanlyAtLaunchIsLeftAloneWhenTheAppBecomesActive() throws {
        let earlier = motionEvent(secondsAgo: 60)
        try plantLog([earlier])
        let store = EventStore(protectedDataAvailable: { false })   // never asked: the read succeeds
        let recorded = motionEvent()
        store.add(recorded)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        settle(0.3)
        XCTAssertEqual(Set(store.events.map(\.id)), [earlier.id, recorded.id], "the log as it was, plus the new record")
        XCTAssertFalse(store.logWasQuarantined)
        XCTAssertEqual(try backups().count, 0)
    }
}
