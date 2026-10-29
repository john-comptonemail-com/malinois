import XCTest
@testable import Malinois

/// Item 140's A1 (gpt6-astra-1 in the top-down review of 1.8 (73)): the byte-limit cleanup takes a snapshot of each
/// event's media, measures the files off the main actor, then deletes. A late capture that attached to a synced event
/// while the files were measured (`EvidenceCapturePipeline.preserveLate`: the file, `updateAndReopenForReupload`) was
/// deleted with the event's other media, and its loss went unmarked: the snapshot still said the event was synced.
/// The first test is gpt6-astra's probe, adapted.
@MainActor
final class Item140CleanupRaceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem140")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    /// A synced event, `secondsAgo` old, with one 100-byte file from the front camera.
    private func syncedEvent(in store: EventStore, secondsAgo: TimeInterval) throws -> Event {
        let start = Date().addingTimeInterval(-secondsAgo)
        var event = Event(startDate: start, endDate: start, triggeredSensors: [.motion], cloudSyncState: .synced)
        let name = UUID().uuidString + ".jpg"
        event.mediaFilename = name
        event.primaryCamera = "front"
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        return event
    }

    /// What `preserveLate` does when the rear camera's capture lands late: the file, then `updateAndReopenForReupload`
    /// (one write since item 155's S1).
    private func attachLateRear(to id: UUID, in store: EventStore) throws -> String {
        let name = UUID().uuidString + ".jpg"
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        var current = try XCTUnwrap(store.events.first { $0.id == id })
        current.secondaryMediaFilename = name
        current.secondaryCamera = "rear"
        store.updateAndReopenForReupload(current)
        return name
    }

    /// Holds the cleanup's pass once its files are measured, until `hold` is cleared.
    private func holdAfterMeasuring(_ store: EventStore, measured: TestFlag, hold: TestFlag) {
        store.mediaMeasuredForTesting = {
            measured.value = true
            while hold.value { try? await Task.sleep(nanoseconds: 10_000_000) }
        }
    }

    private func media(of id: UUID, in store: EventStore) -> [String] {
        guard let event = store.events.first(where: { $0.id == id }) else { return [] }
        return [event.mediaFilename, event.secondaryMediaFilename].compactMap { $0 }
    }

    private func fileExists(_ name: String, in store: EventStore) -> Bool {
        FileManager.default.fileExists(atPath: store.mediaDirectory.appendingPathComponent(name).path)
    }

    /// gpt6-astra's probe: one synced event over a 10-byte limit gains a late rear capture while its files are
    /// measured. The limit still takes it (a storage emergency), but on the record: evidence that never uploaded is
    /// never deleted unmarked.
    func testALateCaptureTheLimitTakesIsMarkedLost() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 10
        let event = try syncedEvent(in: store, secondsAgo: 0)
        let measured = TestFlag()
        let hold = TestFlag(true)
        holdAfterMeasuring(store, measured: measured, hold: hold)
        defer { hold.value = false; store.mediaMeasuredForTesting = nil; store.drainIOForTesting() }
        store.add(event)
        let entered = await waitUntil(timeout: 3) { measured.value }
        XCTAssertTrue(entered)
        let rear = try attachLateRear(to: event.id, in: store)
        XCTAssertEqual(store.events.first?.cloudSyncState, .pending)
        hold.value = false
        let cleaned = await waitUntil(timeout: 3) { media(of: event.id, in: store).isEmpty }
        XCTAssertTrue(cleaned, "the limit takes the event's media")
        store.drainIOForTesting()
        XCTAssertFalse(fileExists(rear, in: store))
        // Since item 166's codex-24 (the owner's option (b)) the loss is on the record as a check owed, and marked once
        // iCloud, asked at the engine's sweep (no engine here), holds none of the capture's files.
        XCTAssertEqual(store.events.first?.mediaDiscardUnchecked, true,
                       "never-uploaded rear evidence must not disappear without the loss on the record")
        store.resolveDiscardCheck(event.id, landed: [], epoch: nil)
        XCTAssertEqual(store.events.first?.mediaDiscarded, true, "marked once iCloud holds none of it")
    }

    /// The same race where the limit has room: the oldest of three synced events, chosen while the files were
    /// measured, gains a late rear capture. It is judged again as it is now, a pending event, so the next pass
    /// frees the two newer synced events instead, and the changed event keeps both its files.
    func testALateCaptureOnAnEventChosenForCleanupIsKept() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 250
        let oldest = try syncedEvent(in: store, secondsAgo: 30)
        let middle = try syncedEvent(in: store, secondsAgo: 20)
        let newest = try syncedEvent(in: store, secondsAgo: 10)
        let measured = TestFlag()
        let hold = TestFlag(true)
        holdAfterMeasuring(store, measured: measured, hold: hold)
        defer { hold.value = false; store.mediaMeasuredForTesting = nil; store.drainIOForTesting() }
        store.add(oldest)
        store.add(middle)
        store.add(newest)
        let entered = await waitUntil(timeout: 3) { measured.value }
        XCTAssertTrue(entered)
        let rear = try attachLateRear(to: oldest.id, in: store)
        hold.value = false
        let settled = await waitUntil(timeout: 3) {
            media(of: middle.id, in: store).isEmpty && media(of: newest.id, in: store).isEmpty
        }
        XCTAssertTrue(settled, "the next pass frees the two newer synced events")
        store.drainIOForTesting()
        XCTAssertEqual(media(of: oldest.id, in: store), [try XCTUnwrap(oldest.mediaFilename), rear],
                       "the event that changed while its files were measured keeps both files")
        XCTAssertTrue(fileExists(rear, in: store))
        XCTAssertTrue(fileExists(try XCTUnwrap(oldest.mediaFilename), in: store))
        XCTAssertNil(store.events.first { $0.id == oldest.id }?.mediaDiscarded)
    }

    /// An event that did not change while the files were measured is freed by the same pass, as before: the check
    /// defers only what changed.
    func testAnUnchangedEventIsFreedByTheSamePass() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 150
        let oldest = try syncedEvent(in: store, secondsAgo: 20)
        let newest = try syncedEvent(in: store, secondsAgo: 10)
        var passes = 0
        store.mediaMeasuredForTesting = { passes += 1 }
        defer { store.mediaMeasuredForTesting = nil; store.drainIOForTesting() }
        store.add(oldest)
        store.add(newest)
        let freed = await waitUntil(timeout: 3) { media(of: oldest.id, in: store).isEmpty }
        XCTAssertTrue(freed)
        XCTAssertEqual(passes, 1, "one pass measured and freed it")
        XCTAssertEqual(media(of: newest.id, in: store).count, 1)
        XCTAssertNil(store.events.first { $0.id == oldest.id }?.mediaDiscarded, "synced media is a cache, not a loss")
    }

    // MARK: - Item 155's T1: the checkpoint observer hook across threads (BACKLOG 163, step 12)

    /// Tests set and clear `EventStore.checkpointObserverForTesting` on the main thread, and every snapshot write
    /// calls it on the store's I/O queue. Read there, it was a data race: 1.8.2's step 1 gate caught it twice
    /// (`tsan-79-8e2810f.log`), when a tearDown cleared the hook while a store was still writing; the store now reads it
    /// on the main actor, when it queues the write. This drives the real path, snapshot writes in flight while the hook
    /// changes. Under ThreadSanitizer (the gate runs this class with it) it fails while the queue reads the hook;
    /// without ThreadSanitizer it passes either way.
    func testTheCheckpointObserverCanChangeWhileTheStoreWrites() {
        let store = EventStore()
        let observer: @Sendable (URL, [Event], Data) -> Void = { _, _, _ in }
        for i in 0..<200 {
            store.flush()
            EventStore.checkpointObserverForTesting = i.isMultiple(of: 2) ? observer : nil
        }
        store.drainIOForTesting()
        EventStore.checkpointObserverForTesting = nil
        XCTAssertNil(EventStore.checkpointObserverForTesting)
    }

    /// A write calls the observer that was set when the write was queued, never one set while it waited:
    /// Item152IdentityFailureTests sets its observer after a sweep whose writes may still be queued, and must see
    /// only its own. The first observer holds the I/O queue inside the first write while a second write is queued
    /// under it, then the second observer is set and a third write queued.
    func testTheCheckpointObserverSeesOnlyWritesQueuedAfterItWasSet() {
        let store = EventStore()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let first = CallCount()
        let second = CallCount()
        EventStore.checkpointObserverForTesting = { _, _, _ in
            if first.record() == 1 { entered.signal(); release.wait() }
        }
        store.flush()
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success, "the first write reached its observer")
        store.flush()
        EventStore.checkpointObserverForTesting = { _, _, _ in second.record() }
        store.flush()
        release.signal()
        store.drainIOForTesting()
        EventStore.checkpointObserverForTesting = nil
        XCTAssertEqual(first.count, 2, "the first observer saw the two writes queued while it was set")
        XCTAssertEqual(second.count, 1, "the second saw only the write queued after it was set")
    }
}

/// Counts a hook's calls, which come on the store's I/O queue, behind a lock.
private final class CallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    @discardableResult
    func record() -> Int {
        lock.withLock {
            calls += 1
            return calls
        }
    }
}
