//
//  Item239StillStorageTests.swift
//  MalinoisTests
//
//  BACKLOG item 239 (ADR 0081, decisions 3, 4 and 6): a slow Vision trip's still, as the store keeps it and the evidence
//  signs it. The store saves it under the name its record was born with, and no other; it counts toward the byte limit
//  and goes with its record's photos, by the byte limit and the count limit; the launch's sweep keeps it while a record
//  names it; a set-aside log's Delete keeps it while the event log names it; a copy written back from before the limit
//  removed it cannot bring its name back. The signer signs it as the attachment `visionReference`, after the second
//  camera's file, with its time as the fact `visionReferenceTakenAt`, in the records that have one only; the evidence ZIP
//  carries it and checks out. Written before the code, red at that commit (against stubs that keep the old behaviour).
//

import XCTest
@testable import Malinois

@MainActor
final class Item239StillStorageTests: XCTestCase {

    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item239Still-\(UUID().uuidString)")
    nonisolated private var media: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    nonisolated private var out: URL { folder.appendingPathComponent("Out", isDirectory: true) }
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }
    private let signedAt = TestApp.date(2026, 11, 12, 21, 0)
    private let photo = Data("a photo's bytes".utf8)
    private let rear = Data("the rear camera's bytes".utf8)
    private let still = Data("the reference still's bytes".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestIsolation.setUp(folderPrefix: "MalinoisItem239Still")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The store saves it under its record's name, and no other

    func testTheStoreSavesTheStillUnderItsRecordsNameAndNoOther() throws {
        let store = EventStore()
        let record = slowTrip(minutesAgo: 1)
        store.add(record)
        store.saveVisionReference(still, for: record)
        store.drainIOForTesting()
        let name = try XCTUnwrap(record.visionReferenceFilename)
        XCTAssertEqual(try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(name)), still, "saved under its name")

        let stranger = slowTrip(minutesAgo: 2)   // not in the log
        store.saveVisionReference(still, for: stranger)
        var odd = slowTrip(minutesAgo: 3)
        odd.visionReferenceFilename = "../outside.jpg"   // not a name the store gives
        store.add(odd)
        store.saveVisionReference(still, for: odd)
        let taken = slowTrip(minutesAgo: 4)
        store.add(taken)
        let takenName = try XCTUnwrap(taken.visionReferenceFilename)
        let earlier = Data("a file already there".utf8)
        try earlier.write(to: store.mediaDirectory.appendingPathComponent(takenName))
        store.saveVisionReference(still, for: taken)
        store.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaDirectory
            .appendingPathComponent(try XCTUnwrap(stranger.visionReferenceFilename)).path), "not for a record the log does not have")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaDirectory.deletingLastPathComponent()
            .appendingPathComponent("outside.jpg").path), "not under a name of another form")
        XCTAssertEqual(try? Data(contentsOf: store.mediaDirectory.appendingPathComponent(takenName)), earlier,
                       "never over a file already there")
    }

    // MARK: - The limits take it with its record's photos

    func testTheByteLimitCountsTheStillAndTakesItWithItsRecordsPhoto() async throws {
        let store = EventStore()
        store.mediaBudgetForTesting = 150
        var record = slowTrip(minutesAgo: 1)
        record.mediaFilename = UUID().uuidString + ".jpg"
        let photoFile = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.mediaFilename))
        let stillFile = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename))
        try Data(count: 100).write(to: photoFile)
        try Data(count: 100).write(to: stillFile)
        store.add(record)   // 200 bytes: over the limit with the still alone
        let removed = await eventually { store.events.first { $0.id == record.id }?.mediaFilename == nil }
        XCTAssertTrue(removed, "the still counts toward the limit, so the record's files go")
        store.drainIOForTesting()
        let kept = try XCTUnwrap(store.events.first { $0.id == record.id })
        XCTAssertNil(kept.visionReferenceFilename, "the record no longer names the still")
        XCTAssertEqual(kept.visionReferenceTakenAt, record.visionReferenceTakenAt, "its time stays, as a photo's camera does")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stillFile.path), "the still went with the photo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: photoFile.path))
    }

    func testTheCountLimitTakesTheStillWithItsRecord() throws {
        let store = EventStore()
        let record = slowTrip(minutesAgo: 600)
        let stillFile = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename))
        try still.write(to: stillFile)
        store.add(record)   // the oldest
        let base = Date().addingTimeInterval(-300)
        for i in 1...EventStore.maxIncidentEvents {
            let at = base.addingTimeInterval(Double(i))
            store.add(Event(startDate: at, endDate: at, triggeredSensors: [.motion]))
        }
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == record.id }, "the limit took the oldest record")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stillFile.path), "and its still")
    }

    func testTheLaunchSweepKeepsAStillARecordNamesAndTakesOneNoneDoes() throws {
        let store = EventStore()
        let record = slowTrip(minutesAgo: 1)
        let named = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename))
        let stray = store.mediaDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try still.write(to: named)
        try still.write(to: stray)
        store.add(record)
        store.drainIOForTesting()
        for url in [named, stray] {   // past the sweep's age floor
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: url.path)
        }
        let relaunched = EventStore()
        relaunched.drainIOForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: named.path), "a still a record names stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "the control: one none names goes")
    }

    func testDeletingASetAsideLogKeepsAStillTheEventLogNames() async throws {
        let store = EventStore()
        let record = slowTrip(minutesAgo: 1)
        let stillFile = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename))
        try still.write(to: stillFile)
        store.add(record)
        store.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([record]).write(to: log)   // a set-aside log with a copy of the same record
        let report = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        XCTAssertEqual(report.outcome, .deleted)
        store.drainIOForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stillFile.path), "the event log names it: it stays")
        XCTAssertEqual(report.mediaRemoved, 0)
    }

    /// The control: a still only the set-aside log names goes with it (a set-aside log finds names by their bytes).
    func testDeletingASetAsideLogTakesAStillOnlyItNames() async throws {
        let store = EventStore()
        let record = slowTrip(minutesAgo: 1)
        let stillFile = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename))
        try still.write(to: stillFile)
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([record]).write(to: log)
        let report = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        store.drainIOForTesting()
        XCTAssertEqual(report.mediaRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stillFile.path))
    }

    func testAnOlderCopyCannotBringBackAStillTheLimitRemoved() {
        let born = slowTrip(minutesAgo: 1)
        var pruned = born
        pruned.visionReferenceFilename = nil   // the limit took the still
        XCTAssertNil(EventStore.preservingMonotonicFields(current: pruned, incoming: born).visionReferenceFilename,
                     "a copy from before the limit (the trip response's own, written back) does not name it again")
        XCTAssertEqual(EventStore.preservingMonotonicFields(current: born, incoming: born).visionReferenceFilename,
                       born.visionReferenceFilename, "the control: while it is there, a write-back keeps it")
    }

    // MARK: - The evidence signs it, and the ZIP carries it

    func testAStillIsSignedAfterTheSecondCamerasFileWithItsTime() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = try writtenSlowTrip(minute: 1)
        await signer.logWritten(generation: 1, events: [record])
        let revision = try latestRevision(of: record.id)
        XCTAssertEqual(revision.attachments.map(\.name), ["primary", "secondary", "visionReference", "visionTrace"])
        XCTAssertEqual(revision.attachments.first { $0.name == "visionReference" }?.digest, EvidenceHash.digest(of: still))
        let taken = try XCTUnwrap(record.visionReferenceTakenAt)
        XCTAssertEqual(revision.facts.last?.key, "visionReferenceTakenAt", "the last fact")
        XCTAssertEqual(revision.facts.last?.value, EvidenceForm.milliseconds(since1970: taken).map(EvidenceJSON.int))
    }

    /// A record without a still has the facts it had before 1.13, so no record of an earlier version is signed again.
    func testARecordWithoutAStillHasTheFactsItHadBefore() {
        let start = TestApp.date(2026, 11, 12, 20, 0)
        let trip = Event(startDate: start, endDate: start, triggeredSensors: [.vision], visionTrace: [0.5])
        XCTAssertEqual(trip.evidenceFacts.map(\.key),
                       ["startDate", "endDate", "triggeredSensors", "stateChange", "interrupted", "interruptionCause",
                        "sustainedCount", "wrongPINCount", "cancelCount", "ownerAttributed", "capturedOffline", "thermalState",
                        "captureFailure", "captureFailuresByCamera", "primaryCamera", "primaryDuration", "secondaryCamera",
                        "secondaryDuration", "mediaDiscarded"])
    }

    func testTheZIPCarriesTheStillAndChecksOut() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = try writtenSlowTrip(minute: 1)
        await signer.logWritten(generation: 1, events: [record])
        let made = try await EvidenceExporter(signer: signer, mediaDirectory: media, temporaryDirectory: out)
            .folder(of: record, log: [record], in: out)
        let bundle = try XCTUnwrap(made, "a bundle")
        let report = try EvidenceBundle.check(bundle, appID: TestApp.id, roots: [chain.rootDER])
        XCTAssertEqual(report.attachments.map(\.name), ["primary", "secondary", "visionReference", "visionTrace"])
        XCTAssertEqual(report.attachments.map(\.outcome), [.matches, .matches, .matches, .matches])
        XCTAssertEqual(report.problems, [])
        XCTAssertEqual(try? Data(contentsOf: bundle.appendingPathComponent("\(EvidenceBundle.attachmentsFolder)/visionReference.jpg")),
                       still, "the still, as a JPEG named for its attachment")
    }

    /// Once the limit has taken the still, the next revision leaves its attachment out, as for a photo, and keeps its
    /// time, a fact of what was recorded; the ZIP then checks out without it.
    func testOnceTheStillIsGoneTheNextRevisionLeavesItOutAndKeepsItsTime() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = try writtenSlowTrip(minute: 1)
        await signer.logWritten(generation: 1, events: [record])
        var after = record
        try FileManager.default.removeItem(at: media.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename)))
        after.visionReferenceFilename = nil
        await signer.logWritten(generation: 2, events: [after])
        let revision = try latestRevision(of: record.id)
        XCTAssertEqual(revision.revision, 2)
        XCTAssertEqual(revision.attachments.map(\.name), ["primary", "secondary", "visionTrace"])
        XCTAssertEqual(revision.facts.last?.key, "visionReferenceTakenAt", "its time stays")
        let made = try await EvidenceExporter(signer: signer, mediaDirectory: media, temporaryDirectory: out)
            .folder(of: after, log: [after], in: out)
        let report = try EvidenceBundle.check(try XCTUnwrap(made), appID: TestApp.id, roots: [chain.rootDER])
        XCTAssertEqual(report.problems, [])
    }

    // MARK: - Helpers

    /// A slow trip's record, born naming its still (a name of the store's form) and its time; no file written.
    private func slowTrip(minutesAgo: Double) -> Event {
        let at = Date().addingTimeInterval(-minutesAgo * 60)
        var record = Event(startDate: at, endDate: at, triggeredSensors: [.vision], visionTrace: [0.02, 0.03])
        record.visionReferenceFilename = UUID().uuidString + ".jpg"
        record.visionReferenceTakenAt = at.addingTimeInterval(-1_800)
        return record
    }

    /// A slow trip's record whose two cameras' photos and still are in the signer's media folder.
    private func writtenSlowTrip(minute: Int) throws -> Event {
        let start = TestApp.date(2026, 11, 12, 20, minute)
        var record = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.vision],
                           primaryCamera: "front", secondaryCamera: "rear", visionTrace: [0.02, 0.03])
        record.mediaFilename = UUID().uuidString + ".jpg"
        record.secondaryMediaFilename = UUID().uuidString + ".jpg"
        record.visionReferenceFilename = UUID().uuidString + ".jpg"
        record.visionReferenceTakenAt = start.addingTimeInterval(-1_800.25)
        try photo.write(to: media.appendingPathComponent(try XCTUnwrap(record.mediaFilename)))
        try rear.write(to: media.appendingPathComponent(try XCTUnwrap(record.secondaryMediaFilename)))
        try still.write(to: media.appendingPathComponent(try XCTUnwrap(record.visionReferenceFilename)))
        return record
    }

    private func makeSigner() throws -> (EvidenceSigner, FakeKeyService, TestAttestationChain) {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let time = TestClock(signedAt)
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.13 (88)", now: { time.now }, retryAfter: 0)
        return (signer, keys, chain)
    }

    /// The latest revision of record `id` the signature file holds.
    private func latestRevision(of id: UUID) throws -> EvidenceForm.Record {
        let revisions = try XCTUnwrap(file.read()).filter { $0.kind == .signature }.compactMap { entry -> EvidenceForm.Record? in
            guard let statement = entry.statement, case .record(let record)? = try? EvidenceForm.read(statement), record.id == id else {
                return nil
            }
            return record
        }
        return try XCTUnwrap(revisions.last, "a revision signed")
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
