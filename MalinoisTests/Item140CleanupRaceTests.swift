import XCTest
@testable import Malinois

/// Item 140's A1 (gpt6-astra-1 in the top-down review of 1.8 (73)): the byte-limit cleanup takes a snapshot of each
/// event's media, measures the files off the main actor, then deletes. A late capture that attached to a synced event
/// while the files were measured (`EvidenceCapturePipeline.preserveLate`: the file, `update`, `reopenForReupload`) was
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

    /// What `preserveLate` does when the rear camera's capture lands late: the file, `update`, `reopenForReupload`.
    private func attachLateRear(to id: UUID, in store: EventStore) throws -> String {
        let name = UUID().uuidString + ".jpg"
        try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        var current = try XCTUnwrap(store.events.first { $0.id == id })
        current.secondaryMediaFilename = name
        current.secondaryCamera = "rear"
        store.update(current)
        store.reopenForReupload(id)
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
        XCTAssertEqual(store.events.first?.mediaDiscarded, true,
                       "never-uploaded rear evidence must not disappear without the loss marker")
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
}
