//
//  Item235DeleteOwedEntryTests.swift
//  MalinoisTests
//
//  BACKLOG item 235's first half, A11 (1.13, item 240's list; docs/design/1.13-fixes.md, part 3a; the owner, 2026-11-12:
//  "as you recommend, wording approved", W3). A set-aside log's Delete wrote its status entry once the store's delete had
//  returned: Malinois stopped in between (the time the store takes to find and remove the log's photos) left the log gone
//  and no entry (ADR 0078's decision 7). Now the Delete writes a note beside the log first, with the ID its entry will
//  have; the note goes once the entry is written. At the next launch, once the set-aside logs are listed, a note whose log
//  is gone and whose entry is not in the log gets its entry, at the moment of the Delete, under the note's ID, with no
//  counts (W3); a note whose log is still there, or whose entry is in the log, is dropped. Through the engine's own
//  Delete and a store made again over the same folder, as at a launch. Written before the fix, red at that commit (where
//  the note is a stub that writes nothing, and the kind reads no counts not known).
//

import XCTest
@testable import Malinois

@MainActor
final class Item235DeleteOwedEntryTests: XCTestCase {
    private static let setAsideAt = Date(timeIntervalSince1970: 1_762_520_000)   // the logs' names say so
    private static let unknownCounts = "; Malinois was stopped before it could count what went with it"

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem235")
    }

    override func tearDown() {
        EventStore.setAsideDeleteBeginsForTesting = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The note, before the delete; gone after the entry

    /// The engine's Delete writes the note before the store's delete begins, names its entry by the note's ID, and
    /// retires the note once the entry is written.
    func testTheEnginesDeleteWritesItsNoteFirstAndRetiresItAfterTheEntry() async throws {
        let (store, log) = try storeWithASetAsideLog()
        let engine = engine(on: store)
        let seen = NotesSeen()
        EventStore.setAsideDeleteBeginsForTesting = { root in seen.notes = Self.notes(in: root) }
        let outcome = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(outcome, .deleted)
        let note = try XCTUnwrap(seen.notes?.first, "a note on disk as the delete began")
        XCTAssertEqual(seen.notes?.count, 1)
        XCTAssertEqual(note.log, log.lastPathComponent)
        XCTAssertEqual(note.setAsideAt, Self.setAsideAt)
        let entry = try XCTUnwrap(deletionEntries(in: store).first, "the Delete's entry")
        XCTAssertEqual(entry.id, note.id, "the entry has the note's ID")
        store.drainIOForTesting()
        try await waitUntil("the note retired once a saved log holds the entry") { Self.notes(in: try self.root()) == nil }
    }

    // MARK: - The next launch

    /// Malinois stopped after the delete and before the entry: the next launch writes the entry, at the moment of the
    /// Delete, under the note's ID, with no counts, in the owner's words (W3); then the note goes.
    func testAStopBetweenTheDeleteAndItsEntryOwesTheEntryAtTheNextLaunch() async throws {
        let (store, log) = try storeWithASetAsideLog()
        let note = store.oweSetAsideDeleteEntry(for: SetAsideLog(url: log), at: Date(timeIntervalSinceNow: -60))
        let report = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        XCTAssertTrue(report.removedLog)
        store.drainIOForTesting()   // stopped here: no entry written, the note not retired
        let relaunched = EventStore()
        _ = engine(on: relaunched)
        try await waitUntil("the owed entry") { !self.deletionEntries(in: relaunched).isEmpty }
        let entry = try XCTUnwrap(deletionEntries(in: relaunched).first)
        XCTAssertEqual(entry.id, note.id)
        XCTAssertEqual(entry.startDate.timeIntervalSince1970, note.at.timeIntervalSince1970, accuracy: 0.001,
                       "at the moment of the Delete")
        XCTAssertEqual(entry.stateChange.flatMap(Event.setAsideDeleted(kind:)),
                       Event.SetAsideDeleted(setAsideAt: Self.setAsideAt, records: nil, mediaRemoved: nil, mediaLeft: nil))
        XCTAssertTrue(entry.sensorSummary.hasSuffix(" was deleted" + Self.unknownCounts), entry.sensorSummary)
        XCTAssertEqual(deletionEntries(in: relaunched).count, 1)
        relaunched.drainIOForTesting()
        try await waitUntil("the note retired") { Self.notes(in: try self.root()) == nil }
    }

    /// Malinois stopped before the delete: the log is still there, nothing was deleted, and the next launch writes no
    /// entry and drops the note.
    func testANoteWhoseLogIsStillThereIsDropped() async throws {
        let (store, log) = try storeWithASetAsideLog()
        _ = store.oweSetAsideDeleteEntry(for: SetAsideLog(url: log))
        store.drainIOForTesting()
        XCTAssertNotNil(Self.notes(in: try root()), "the note on disk")
        let relaunched = EventStore()
        _ = engine(on: relaunched)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(deletionEntries(in: relaunched).isEmpty, "nothing was deleted: no entry")
        relaunched.drainIOForTesting()
        XCTAssertNil(Self.notes(in: try root()), "the note dropped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "the log untouched")
    }

    /// Malinois stopped after the entry and before the note's retirement: the next launch finds the entry in the log by
    /// the note's ID, writes none again, and drops the note.
    func testANoteWhoseEntryIsInTheLogIsDroppedWithNoSecondEntry() async throws {
        let (store, log) = try storeWithASetAsideLog()
        let engine = engine(on: store)
        let note = store.oweSetAsideDeleteEntry(for: SetAsideLog(url: log))
        _ = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        _ = engine.logStateChange(Event.setAsideDeletedKind(Event.SetAsideDeleted(
            setAsideAt: Self.setAsideAt, records: 1, mediaRemoved: 0, mediaLeft: false)), id: note.id)
        store.drainIOForTesting()   // stopped here: the entry written, the note not retired
        XCTAssertNotNil(Self.notes(in: try root()), "the note still on disk")
        let relaunched = EventStore()
        _ = self.engine(on: relaunched)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(deletionEntries(in: relaunched).map(\.id), [note.id], "the one entry, not a second")
        relaunched.drainIOForTesting()
        XCTAssertNil(Self.notes(in: try root()), "the note dropped")
    }

    /// Two Deletes in a row, both stopped before their entries: two notes, two entries at the next launch.
    func testTwoDeletesInARowOweTwoEntries() async throws {
        let (store, first) = try storeWithASetAsideLog()
        let second = try setAsideLog(named: "events.corrupt-1762530000.json")
        store.refreshSetAsideLogs()
        let notes = [store.oweSetAsideDeleteEntry(for: SetAsideLog(url: first)),
                     store.oweSetAsideDeleteEntry(for: SetAsideLog(url: second))]
        _ = await store.deleteSetAsideLogReporting(SetAsideLog(url: first))
        _ = await store.deleteSetAsideLogReporting(SetAsideLog(url: second))
        store.drainIOForTesting()
        let relaunched = EventStore()
        _ = engine(on: relaunched)
        try await waitUntil("two owed entries") { self.deletionEntries(in: relaunched).count == 2 }
        XCTAssertEqual(Set(deletionEntries(in: relaunched).map(\.id)), Set(notes.map(\.id)))
    }

    // MARK: - The kind and its words

    /// The kind carries counts not known as "-", all three together, and reads them back; the older forms read as before;
    /// a "-" in one count alone is no entry of a Delete.
    func testTheKindCarriesCountsNotKnown() {
        let at = Date(timeIntervalSince1970: 1_762_520_700)
        let owed = Event.SetAsideDeleted(setAsideAt: at, records: nil, mediaRemoved: nil, mediaLeft: nil)
        XCTAssertEqual(Event.setAsideDeletedKind(owed), "setAsideDeleted.1762520700.-.-.-")
        XCTAssertEqual(Event.setAsideDeleted(kind: "setAsideDeleted.1762520700.-.-.-"), owed)
        XCTAssertEqual(Event.setAsideDeleted(kind: "setAsideDeleted.-.-.-.-"),
                       Event.SetAsideDeleted(setAsideAt: nil, records: nil, mediaRemoved: nil, mediaLeft: nil))
        XCTAssertEqual(Event.setAsideDeleted(kind: "setAsideDeleted.1762520700.37.4.0"),
                       Event.SetAsideDeleted(setAsideAt: at, records: 37, mediaRemoved: 4, mediaLeft: false), "as before")
        for malformed in ["setAsideDeleted.1762520700.37.-.-", "setAsideDeleted.1762520700.-.-.0",
                          "setAsideDeleted.1762520700.-.4.-", "setAsideDeleted.1762520700.37.-.0"] {
            XCTAssertNil(Event.setAsideDeleted(kind: malformed), malformed)
        }
    }

    /// W3, word for word (the owner's "wording approved", 2026-11-12), with the log's time and without.
    func testTheWordsAreTheApprovedOnes() {
        let at = Date(timeIntervalSince1970: 1_762_520_700)
        let when = "\(at.formatted(.dateTime.month(.abbreviated).day())), \(at.formatted(date: .omitted, time: .shortened))"
        XCTAssertEqual(Event.setAsideDeletedSummary(kind: "setAsideDeleted.1762520700.-.-.-"),
                       "A set-aside log from \(when) was deleted; Malinois was stopped before it could count what went with it")
        XCTAssertEqual(Event.setAsideDeletedSummary(kind: "setAsideDeleted.-.-.-.-"),
                       "A set-aside log was deleted; Malinois was stopped before it could count what went with it")
    }

    // MARK: - Helpers

    /// The notes' file in `root`, decoded; nil when there is none.
    nonisolated private static func notes(in root: URL) -> [EventStore.SetAsideDeleteOwed]? {
        let url = root.appendingPathComponent(EventStore.setAsideDeletesOwedFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([EventStore.SetAsideDeleteOwed].self, from: data)
    }

    private func root() throws -> URL { try XCTUnwrap(EventStore.rootOverrideForTesting) }

    /// A store whose folder holds a set-aside log of one record, listed.
    private func storeWithASetAsideLog() throws -> (store: EventStore, log: URL) {
        let store = EventStore()
        store.drainIOForTesting()
        let log = try setAsideLog(named: "events.corrupt-1762520000.json")
        store.refreshSetAsideLogs()
        return (store, log)
    }

    /// A set-aside log of one record in the store's folder.
    private func setAsideLog(named name: String) throws -> URL {
        let url = try root().appendingPathComponent(name)
        let start = Date(timeIntervalSince1970: 1_762_510_000)
        let record = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion])
        try JSONEncoder().encode([record]).write(to: url)
        return url
    }

    /// An engine on `store`, on the free tier, as the screens' rigs make one.
    private func engine(on store: EventStore) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .free),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    /// The status entries of set-aside logs' Deletes in `store`'s log.
    private func deletionEntries(in store: EventStore) -> [Event] {
        store.events.filter { $0.stateChange.flatMap(Event.setAsideDeleted(kind:)) != nil }
    }

    /// Lets the main run loop turn until `condition` holds; after five seconds, fails, naming what it waited for.
    private func waitUntil(_ what: String, _ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while try !condition() {
            guard clock.now < deadline else { return XCTFail("waited five seconds: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// What the notes' file held as the store's delete began, read on the store's queue.
    private final class NotesSeen: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [EventStore.SetAsideDeleteOwed]?
        var notes: [EventStore.SetAsideDeleteOwed]? {
            get { lock.withLock { seen } }
            set { lock.withLock { seen = newValue } }
        }
    }
}
