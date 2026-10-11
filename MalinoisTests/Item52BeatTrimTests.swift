//
//  Item52BeatTrimTests.swift
//  MalinoisTests
//
//  BACKLOG 52, follow-up 2 (the owner's ruling (b), 2026-09-29, for 1.5). Nothing deleted old
//  beats: every armed watch left a small record per five minutes in the owner's iCloud for good.
//  The daily retention pass now also deletes a watch's per-beat trail once the watch is past the
//  retention setting, keeping its latest record (all "Last heard from" reads): this phone's own
//  watches only, never under Manual or Keep forever, never a trail whose last beat is newer than
//  the cutoff (so the 30-day floor protects beats, not just watch starts), never the live watch,
//  and a bounded number per pass. The watches are kept in a list of their own, filled as each
//  Pro watch goes live and once from the log, because the log's cap drops an old watch's arm
//  record before it comes due (a Fable review of the first version found both). Beats the latest
//  record never counted (the two records of a beat save separately) go too, but only when their
//  own server time is older than the cutoff. A second review asked for the one-watch decisions
//  to be tested where they are made, with the floor inside them, and for the log's arm records
//  to be added at the first Pro watch too, and only from a log this launch read from disk.
//

import XCTest
import CloudKit
@testable import Malinois

@MainActor
final class Item52BeatTrimTests: XCTestCase {

    nonisolated private static let keys = ["com.malinois.beats.sessions", "com.malinois.beats.sessionsSeeded",
                               "com.malinois.cloudRetention.lastRun", "com.malinois.cloudRetention.lastAttempt"]
    private var asked: [[UUID]] = []
    private let now = Date()

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem52Trim")
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
    }

    override func tearDown() {
        for key in Self.keys { UserDefaults.standard.removeObject(forKey: key) }
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func session(daysAgo days: Double) -> BeatSession {
        BeatSession(id: UUID(), start: daysAgo(days))
    }

    /// The watches waiting, as the engine keeps them, and the log already added once.
    private func keep(sessions: [BeatSession]) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(sessions), forKey: "com.malinois.beats.sessions")
        UserDefaults.standard.set(true, forKey: "com.malinois.beats.sessionsSeeded")
    }

    /// A log on disk holding this phone's own arm records from `days` ago, as a 1.4 phone leaves
    /// it, for the next store to read; their ids.
    private func writeLogToDisk(armedDaysAgo days: [Double]) throws -> [UUID] {
        let records = days.map { days -> Event in
            let at = daysAgo(days)
            return Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "armed")
        }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: root.appendingPathComponent("events.json"))
        return records.map(\.id)
    }

    private func makeEngine(store: EventStore? = nil, retention: CloudRetention = .months12,
                            entitlement: ProEntitlements.Status = .trial) -> MonitoringEngine {
        let store = store ?? EventStore()
        let settings = AppSettings()
        settings.cloudRetention = retention
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        return TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                    camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: entitlement),
                                                    timing: EngineCharacterizationTests.fastTiming))
    }

    private func goLive(_ engine: MonitoringEngine) {
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while engine.state != .armed && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The same from an async test, whose wait must sleep the test's task so the engine's own
    /// tasks run on the main actor meanwhile: spinning the run loop there, as `goLive` does, runs
    /// none of them, and the watch never goes live (the owner's run of 2026-09-29).
    private func goLiveAwaiting(_ engine: MonitoringEngine) async {
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        let deadline = Date().addingTimeInterval(5)
        while engine.state != .armed && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    /// The retention pass runs at most daily; a test makes the next one due.
    private func makeThePassDueAgain() {
        UserDefaults.standard.removeObject(forKey: "com.malinois.cloudRetention.lastRun")
        UserDefaults.standard.removeObject(forKey: "com.malinois.cloudRetention.lastAttempt")
    }

    private func answering(_ outcomes: [UUID: BeatTrimOutcome] = [:],
                           otherwise: BeatTrimOutcome = .trimmed) -> @MainActor ([BeatSession]) async -> [UUID: BeatTrimOutcome] {
        { sessions in
            self.asked.append(sessions.map(\.id))
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, outcomes[$0.id] ?? otherwise) })
        }
    }

    // MARK: - The rules

    /// A watch's trail runs from its first beat to the number its latest record carries, and
    /// never includes the latest record.
    func testTheTrailsRecordNamesRunFromTheFirstBeatToTheLast() {
        let id = UUID()
        let names = CloudExfiltrator.beatTrailRecordNames(session: id, through: 3)
        XCTAssertEqual(names, (1...3).map { CloudExfiltrator.beatRecordName(session: id, sequence: $0) })
        XCTAssertFalse(names.contains(CloudExfiltrator.latestBeatRecordName(session: id)), "the latest is kept")
        XCTAssertEqual(CloudExfiltrator.beatTrailRecordNames(session: id, through: 0), [])
    }

    /// The trim goes a little past the latest record's number (a last beat whose trail record
    /// saved while its latest did not), never past a year of beats, and not at all without a number.
    func testTheTrailsUpperBoundAddsATailAndCapsTheNumber() {
        let margin = CloudExfiltrator.beatTrailTailMargin
        XCTAssertEqual(CloudExfiltrator.beatTrailUpperBound(sequence: 3), 3 + margin)
        XCTAssertEqual(CloudExfiltrator.beatTrailUpperBound(sequence: 10_000_000), CloudExfiltrator.maxBeatsPerSession + margin)
        XCTAssertEqual(CloudExfiltrator.beatTrailUpperBound(sequence: -4), margin)
        XCTAssertNil(CloudExfiltrator.beatTrailUpperBound(sequence: nil))
    }

    /// Beats past the latest record's number go only when they too are older than the cutoff: one
    /// newer means the watch beat inside the window after all (a phone asleep between its latest
    /// record's beat and them), and one that could not be read is asked about again.
    func testBeatsPastTheLatestNumberGoOnlyWhenOlderThanTheCutoff() {
        let cutoff = daysAgo(40)
        let older = cutoff.addingTimeInterval(-3_600), newer = cutoff.addingTimeInterval(3_600)
        func verdict(_ tail: [BeatTailRecord]) -> BeatTrimOutcome? {
            CloudExfiltrator.beatTailVerdict(tail, requestedCutoff: cutoff, now: now)
        }
        XCTAssertNil(verdict([.absent, .absent]))
        XCTAssertNil(verdict([.at(older), .absent]))
        XCTAssertNil(verdict([]))
        XCTAssertEqual(verdict([.at(older), .at(newer)]), .notYet)
        XCTAssertEqual(verdict([.at(cutoff)]), .notYet, "the cutoff itself is inside")
        XCTAssertEqual(verdict([.unreadable, .absent]), .failed)
        XCTAssertEqual(verdict([.unreadable, .at(newer)]), .notYet)
    }

    /// Due: watches begun before the cutoff, oldest first, never the live one.
    func testDueWatchesAreOldNotLiveAndOldestFirst() {
        let cutoff = daysAgo(365)
        let recent = session(daysAgo: 10), older = session(daysAgo: 500), old = session(daysAgo: 400)
        let live = session(daysAgo: 450)
        let due = MonitoringEngine.sessionsDueForBeatTrim(sessions: [recent, old, live, older], cutoff: cutoff, live: live.id)
        XCTAssertEqual(due, [older, old])
    }

    /// The log's own arm records join the list once: not another phone's, not other records,
    /// not a watch already there.
    func testTheLogsOwnArmRecordsJoinTheListOnce() {
        let known = session(daysAgo: 300)
        let at = daysAgo(200)
        let own = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "armed")
        let mirrored = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "armed", sourceDevice: "iPhone Air")
        let disarm = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "disarmed")
        let knownRecord = Event(id: known.id, startDate: known.start, endDate: known.start, triggeredSensors: [],
                                stateChange: "armed")
        XCTAssertEqual(MonitoringEngine.seededBeatSessions([known], from: [own, mirrored, disarm, knownRecord]),
                       [known, BeatSession(id: own.id, start: own.startDate)])
    }

    // MARK: - One watch's trim

    /// The latest record decides one watch's trim: last heard from before the cutoff by the
    /// server's clock, delete through its number and the 12 past it; at the cutoff or after, not
    /// yet; no record, nothing to trim; a failed or partial answer, ask again.
    func testTheLatestRecordDecidesWhatOneTrimDoes() {
        let cutoff = daysAgo(400), margin = CloudExfiltrator.beatTrailTailMargin
        func step(_ latest: Result<FetchedBeat, Error>?, start: Date? = nil) -> BeatTrimStep {
            CloudExfiltrator.beatTrimStep(start: start ?? daysAgo(500), latest: latest, requestedCutoff: cutoff, now: now)
        }
        func beat(_ modified: Date?, _ sequence: Int?) -> Result<FetchedBeat, Error> {
            .success(FetchedBeat(modified: modified, sequence: sequence))
        }
        XCTAssertEqual(step(beat(cutoff.addingTimeInterval(-1), 100)), .deleteThrough(100 + margin))
        XCTAssertEqual(step(beat(cutoff, 100)), .stop(.notYet), "the cutoff itself is inside")
        XCTAssertEqual(step(beat(daysAgo(10), 100)), .stop(.notYet))
        XCTAssertEqual(step(.failure(CKError(.unknownItem))), .stop(.trimmed), "it never beat: nothing to trim")
        XCTAssertEqual(step(.failure(CKError(.networkFailure))), .stop(.failed))
        XCTAssertEqual(step(nil), .stop(.failed), "an answer that leaves the record out")
        XCTAssertEqual(step(beat(nil, 100)), .stop(.failed), "no server time")
        XCTAssertEqual(step(beat(daysAgo(450), nil)), .stop(.failed), "no number")
        XCTAssertEqual(step(beat(daysAgo(450), 100), start: cutoff), .stop(.notYet), "begun at the cutoff")
    }

    /// The 30-day floor holds inside both decisions, whatever cutoff is asked: asked to delete
    /// everything, a watch last heard from 10 days ago keeps its trail, and so does one with a
    /// beat 10 days old past its latest record's number.
    func testTheFloorHoldsWhateverCutoffIsAsked() {
        let everything = now
        func step(start: Double, lastBeat: Double) -> BeatTrimStep {
            CloudExfiltrator.beatTrimStep(start: daysAgo(start), latest: .success(FetchedBeat(modified: daysAgo(lastBeat), sequence: 5)),
                                          requestedCutoff: everything, now: now)
        }
        XCTAssertEqual(step(start: 500, lastBeat: 10), .stop(.notYet))
        XCTAssertEqual(step(start: 500, lastBeat: 31), .deleteThrough(5 + CloudExfiltrator.beatTrailTailMargin))
        XCTAssertEqual(step(start: 20, lastBeat: 31), .stop(.notYet), "begun inside the floor")
        XCTAssertEqual(CloudExfiltrator.beatTailVerdict([.at(daysAgo(10))], requestedCutoff: everything, now: now), .notYet)
        XCTAssertNil(CloudExfiltrator.beatTailVerdict([.at(daysAgo(31))], requestedCutoff: everything, now: now))
    }

    /// Before deleting, a trim looks at the last 12 numbers it would delete: those past the
    /// latest record's.
    func testTheTailIsTheLastTwelveNumbersATrimWouldDelete() {
        let id = UUID(), margin = CloudExfiltrator.beatTrailTailMargin
        XCTAssertEqual(CloudExfiltrator.beatTailRecordNames(session: id, through: 3 + margin),
                       (4...(3 + margin)).map { CloudExfiltrator.beatRecordName(session: id, sequence: $0) })
        XCTAssertEqual(CloudExfiltrator.beatTailRecordNames(session: id, through: margin),
                       (1...margin).map { CloudExfiltrator.beatRecordName(session: id, sequence: $0) }, "a latest numbered 0")
    }

    /// The tail's answers are read name by name: a time is a beat, "not found" is absence, and
    /// anything else, a record with no time or a name the answer leaves out included, is unreadable.
    func testTheTailsAnswersAreReadNameByName() {
        let at = daysAgo(40)
        let answers: [String: Result<FetchedBeat, Error>] = [
            "a": .success(FetchedBeat(modified: at, sequence: nil)),
            "b": .success(FetchedBeat(modified: nil, sequence: nil)),
            "c": .failure(CKError(.unknownItem)),
            "d": .failure(CKError(.networkFailure))
        ]
        XCTAssertEqual(CloudExfiltrator.beatTailRecords(["a", "b", "c", "d", "e"], answers: answers),
                       [.at(at), .unreadable, .absent, .unreadable, .unreadable])
    }

    // MARK: - The list

    /// A Pro watch joins the list when it goes live, under its arm record's id.
    func testAProWatchJoinsTheListWhenItGoesLive() {
        let store = EventStore()
        let engine = makeEngine(store: store)
        goLive(engine)
        let armed = store.events.first { $0.stateChange == "armed" }
        XCTAssertNotNil(armed)
        XCTAssertEqual(MonitoringEngine.beatSessions().map(\.id), armed.map { [$0.id] })
        engine.disarm()
    }

    /// A free watch never beats, so it never joins the list.
    func testAFreeWatchDoesNotJoinTheList() {
        let engine = makeEngine(entitlement: .free)
        goLive(engine)
        XCTAssertEqual(MonitoringEngine.beatSessions(), [])
        engine.disarm()
    }

    /// The log's own arm records join at the first Pro watch after the update, not only at the
    /// first retention pass: under Manual or Keep forever there is no pass, and meanwhile the
    /// log's cap drops 1.4's arm records one by one.
    func testTheFirstProWatchAddsTheLogsOwnArmRecords() throws {
        let fromBefore = try writeLogToDisk(armedDaysAgo: [400, 300])
        let store = EventStore()   // this launch reads the log from disk
        let engine = makeEngine(store: store, retention: .forever)
        goLive(engine)
        let live = try XCTUnwrap(store.events.first { $0.stateChange == "armed" && !fromBefore.contains($0.id) })
        XCTAssertEqual(Set(MonitoringEngine.beatSessions().map(\.id)), Set(fromBefore + [live.id]))
        engine.disarm()
    }

    /// The log's arm records are added only from a log this launch read from disk: one still
    /// locked after a restart, or one started fresh, reads as empty, and adding from it would
    /// mark the job done with nothing added.
    func testNothingIsAddedFromALogNotReadFromDisk() async {
        let store = EventStore()   // no log on disk: a fresh one
        let at = daysAgo(400)
        store.add(Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "armed"))
        let engine = makeEngine(store: store)
        engine.beatTrailsTrimForTesting = answering()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "com.malinois.beats.sessionsSeeded"), "left for a launch that reads it")
    }

    // MARK: - The retention pass

    /// The pass hands over the due watches, oldest first, and forgets only those trimmed: one
    /// whose last beat is too recent, and one that failed, wait for a later pass.
    func testThePassForgetsOnlyTheTrimmedWatches() async throws {
        let trimmed = session(daysAgo: 500), notYet = session(daysAgo: 450), failed = session(daysAgo: 400)
        let recent = session(daysAgo: 10)
        try keep(sessions: [recent, trimmed, notYet, failed])
        let engine = makeEngine()
        engine.beatTrailsTrimForTesting = answering([notYet.id: .notYet, failed.id: .failed])
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [[trimmed.id, notYet.id, failed.id]])
        XCTAssertEqual(MonitoringEngine.beatSessions(), [recent, notYet, failed])
    }

    /// The log's arm records are added once: one that reaches the log later is not added by a
    /// later pass.
    func testTheLogsArmRecordsAreAddedOnce() async throws {
        let fromBefore = try writeLogToDisk(armedDaysAgo: [400])
        let store = EventStore()
        let engine = makeEngine(store: store)
        engine.beatTrailsTrimForTesting = answering(otherwise: .notYet)
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [fromBefore])
        let at = daysAgo(450)
        store.add(Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "armed"))
        makeThePassDueAgain()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [fromBefore, fromBefore], "the later record is not added")
    }

    /// The live watch is never handed over, whatever its start says.
    func testTheLiveWatchIsNeverHandedOver() async throws {
        let store = EventStore()
        let engine = makeEngine(store: store)
        await goLiveAwaiting(engine)
        let live = try XCTUnwrap(store.events.first { $0.stateChange == "armed" }, "the watch went live")
        let old = session(daysAgo: 450)
        try keep(sessions: [BeatSession(id: live.id, start: daysAgo(400)), old])
        engine.beatTrailsTrimForTesting = answering()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked, [[old.id]])
        engine.disarm()
    }

    /// A watch that joins the list while the trims are out is kept: the pass reads the list
    /// again before it saves.
    func testAWatchJoiningDuringThePassIsKept() async throws {
        let old = session(daysAgo: 400), joined = session(daysAgo: 0)
        try keep(sessions: [old])
        let engine = makeEngine()
        engine.beatTrailsTrimForTesting = { sessions in
            try? self.keep(sessions: MonitoringEngine.beatSessions() + [joined])
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, BeatTrimOutcome.trimmed) })
        }
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(MonitoringEngine.beatSessions(), [joined])
    }

    /// Manual and Keep forever delete nothing, beats included.
    func testNothingIsTrimmedUnderManualOrKeepForever() async throws {
        try keep(sessions: [session(daysAgo: 400)])
        for retention in [CloudRetention.manual, .forever] {
            let engine = makeEngine(retention: retention)
            engine.beatTrailsTrimForTesting = answering()
            makeThePassDueAgain()
            await engine.enforceCloudRetentionIfDue()
        }
        XCTAssertEqual(asked, [])
    }

    /// One pass hands over a bounded number of watches, the oldest; the rest go at the next pass.
    func testOnePassHandsOverABoundedNumberOfWatches() async throws {
        let sessions = (0..<(MonitoringEngine.beatTrimSessionsPerPass + 5)).map { session(daysAgo: 400 + Double($0)) }
        try keep(sessions: sessions)
        let engine = makeEngine()
        engine.beatTrailsTrimForTesting = answering()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked.first?.count, MonitoringEngine.beatTrimSessionsPerPass)
        XCTAssertEqual(asked.first?.first, sessions.last?.id, "the oldest first")
        makeThePassDueAgain()
        await engine.enforceCloudRetentionIfDue()
        XCTAssertEqual(asked.flatMap { $0 }.count, sessions.count, "each watch once")
        XCTAssertEqual(MonitoringEngine.beatSessions(), [])
    }
}
