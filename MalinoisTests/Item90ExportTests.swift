//
//  Item90ExportTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 4: the phone's export of a signed record (the owner's rulings of 2026-10-31; ADR 0067). Once no
//  pass is signing, the signer signs an export statement naming the record's latest revision and keeps it like any
//  signature; a write that comes meanwhile is signed after it. The bundle then holds every signature in the file's order:
//  in full the record's revisions, the status records of its watch (from the arm before it to the disarm after it), the
//  retention statements and this export's statement, every other as its hash; the phone's notes; and the attachments
//  the latest revision signed, from the files on the phone. iOS zips it in a folder of its own. A record with no
//  signature of this phone's has no bundle and spends no signature; nor does a record while no key can sign its export
//  statement (BACKLOG 187's deepseek-1). The watch is found in the log's own order, never by the clock (BACKLOG 187's
//  codex-2). What the export writes is checked with the bundle's own check (EvidenceBundle), App Attest played by the
//  test stand-in. Written before the code, red at that commit (against compile-only stubs).
//

import DeviceCheck
import XCTest
@testable import Malinois

@MainActor
final class Item90ExportTests: XCTestCase {

    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item90Export-\(UUID().uuidString)")
    nonisolated private var media: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    nonisolated private var out: URL { folder.appendingPathComponent("Out", isDirectory: true) }
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }
    private let signedAt = TestApp.date(2026, 10, 31, 2, 0)
    private let photo = Data("a photo's bytes".utf8)
    private let thumbnail = Data("a thumbnail's bytes".utf8)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - The bundle of an incident

    func testAnIncidentsBundleShowsItsRevisionsAndItsWatchAndChecksOut() async throws {
        let (signer, _, chain) = try makeSigner()
        let scene = try await signScene(signer)
        let made = try await exporter(signer).folder(of: scene.incident, log: scene.log, in: out)
        let bundle = try XCTUnwrap(made)
        XCTAssertEqual(bundle.lastPathComponent, EvidenceExporter.bundleName(for: scene.incident))
        let report = try check(bundle, chain)
        XCTAssertEqual(report.keys.count, 1)
        XCTAssertNotNil(report.keys.first?.key, "the key certified")
        XCTAssertEqual(report.signatures.compactMap(\.problem), [])
        XCTAssertEqual(report.sequences.first?.counters, Array(2...12))
        XCTAssertEqual(report.sequences.first?.retired, [1...1], "the retired trip's counter, named by the retention statement")
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.export?.record, scene.incident.id)
        XCTAssertEqual(report.export?.revision, 2, "the latest revision: the owner's \"it was me\"")
        XCTAssertEqual(report.export?.app, "1.10 (81)")
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.revisions.map(\.revision), [1, 2])
        XCTAssertEqual(report.missingRevisions, [])
        XCTAssertTrue(report.revisionsInOrder)
        XCTAssertEqual(report.attachments, [found("primary", .matches), found("thumbnail", .matches), found("motionTrace", .matches)])
        // In full: the incident's revisions and its watch's status records; every other record as its hash alone.
        let shown = Set(report.signatures.compactMap { line -> UUID? in
            if case .record(let revision)? = line.entry?.statement { return revision.id }
            return nil
        })
        XCTAssertEqual(shown, [scene.arm.id, scene.stall.id, scene.incident.id, scene.disarm.id])
        XCTAssertEqual(report.signatures.filter { $0.entry?.statement == nil }.count, 4,
                       "the two other trips and the later watch's arm and disarm")
        XCTAssertTrue(report.signatures.contains { line in
            if case .retention? = line.entry?.statement { return true }
            return false
        }, "the retention statement in full")
        XCTAssertEqual(report.notes, [])
        XCTAssertEqual(report.problems, [])
        // The export statement names every statement the bundle shows (item 182, the owner's "B"), and the bundle shows
        // each.
        XCTAssertEqual(report.export?.shown, try shownCounters(report))
        XCTAssertEqual(report.unshown, [])
    }

    func testARecordWithNoSignatureOfThisPhonesHasNoBundleAndSpendsNoSignature() async throws {
        let (signer, keys, _) = try makeSigner()
        let before = trip(1)
        await signer.certifyIfNeeded(records: [before.id])   // in the log when the key was certified: never signed
        var mirrored = trip(2)
        mirrored.sourceDevice = "Owner's iPad"
        let signed = trip(3)
        let log = [signed, mirrored, before]
        await signer.logWritten(generation: 1, events: log)
        let asked = await keys.assertionRequests
        for record in [before, mirrored] {
            let made = try await exporter(signer).folder(of: record, log: log, in: out)
            XCTAssertNil(made)
        }
        let after = await keys.assertionRequests
        XCTAssertEqual(after, asked, "no signature spent")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing written")
        let control = try await exporter(signer).folder(of: signed, log: log, in: out)
        XCTAssertNotNil(control, "the signed record has one")
    }

    func testTheExportStatementIsKeptSoTheNextBundleHasNoGapWhereItWas() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1), other = trip(2)
        let log = [other, record]
        await signer.logWritten(generation: 1, events: log)   // other 1, record 2
        let first = try await exporter(signer).folder(of: record, log: log, in: out.appendingPathComponent("first"))   // 3
        XCTAssertNotNil(first)
        let kept = try XCTUnwrap(file.read()).filter { $0.kind == .signature }
        XCTAssertEqual(kept.count, 3, "kept in the file like any signature")
        XCTAssertNil(kept.last?.record, "naming no record, so no record's retirement drops it")
        let made = try await exporter(signer).folder(of: other, log: log, in: out.appendingPathComponent("second"))   // 4
        let report = try check(try XCTUnwrap(made), chain)
        XCTAssertEqual(report.sequences.first?.counters, [1, 2, 3, 4])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertNil(at(report.signatures, 2)?.entry?.statement, "the first export, as its hash alone")
        XCTAssertNotNil(at(report.signatures, 2)?.entry, "its signature checks out")
        XCTAssertEqual(report.export?.record, other.id)
    }

    /// DeepSeek's deepseek-1 on 09d997f: with no key that could sign its export statement (App Attest lost the key, as
    /// after a restore from a backup, and Apple has not certified a new one, the phone offline), Share offered the bundle
    /// and the export made it without its export statement, so the verifier ended a bundle the phone itself made in
    /// PROBLEMS. Share now offers it only while a key is current, and an export whose statement could not be signed makes
    /// no bundle (the owner's "deepseek-1 a").
    func testWhileNoKeyCanSignShareOffersNoBundleAndNoneIsMade() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        let keyID = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(keyID.base64EncodedString())   // a restore from a backup
        await keys.failNextAttestations([DCError(.serverUnavailable)])   // and Apple out of reach: no new key yet
        let later = trip(2)
        await signer.logWritten(generation: 2, events: [later, record])   // its signature refused: the key is gone
        XCTAssertTrue(try XCTUnwrap(file.read()).contains { $0.kind == .keyLost && $0.key == keyID }, "the key noted lost")
        let offered = await signer.canExport(record.id)
        XCTAssertFalse(offered, "no bundle offered while no key can sign its export")
        let asked = await keys.assertionRequests
        let made = try await exporter(signer).folder(of: record, log: [later, record], in: out)
        XCTAssertNil(made, "and none made")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing written")
        let after = await keys.assertionRequests
        XCTAssertEqual(after, asked, "no signature asked for")
    }

    /// The same when the phone does not know yet that its key is gone (nothing signed since the restore): Share offers the
    /// bundle, and the export, its signature refused, notes the key lost and asks Apple for a new key at once, as a pass
    /// does, and signs its export statement with it (item 190's deepseek-3, the owner's "A5 a"): the first share after a
    /// restore has its bundle. With Apple out of reach, it makes none and writes nothing.
    func testAShareThatFindsItsKeyGoneCertifiesANewKeyAndMakesItsBundle() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        let keyID = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(keyID.base64EncodedString())   // a restore from a backup
        let offered = await signer.canExport(record.id)
        XCTAssertTrue(offered, "the phone cannot know before it signs")
        let made = try await exporter(signer).folder(of: record, log: [record], in: out.appendingPathComponent("first"))
        let report = try check(try XCTUnwrap(made, "a new key certified, and the export statement signed with it"), chain)
        XCTAssertTrue(try XCTUnwrap(file.read()).contains { $0.kind == .keyLost && $0.key == keyID }, "the key noted lost")
        let exportKey = try XCTUnwrap(report.signatures.last?.entry?.keyID)
        XCTAssertNotEqual(exportKey, keyID, "the export statement is the new key's")
        XCTAssertEqual(report.keys.compactMap(\.key?.statement.follows), [keyID], "which follows the key lost")
        XCTAssertEqual(report.export?.record, record.id)
        XCTAssertEqual(report.revisions.map(\.revision), [1])
        XCTAssertEqual(report.notes, [.keyLost(key: keyID, at: 1_793_412_000_000)], "the phone's note of the lost key")
        XCTAssertEqual(report.signatures.compactMap(\.problem), [])
        XCTAssertEqual(report.sequences.flatMap(\.missing), [])
        // The key gone again and Apple out of reach: no bundle without its export statement, and nothing written.
        await keys.lose(exportKey.base64EncodedString())
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        let none = try await exporter(signer).folder(of: record, log: [record], in: out.appendingPathComponent("second"))
        XCTAssertNil(none)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("second").path), "nothing written")
    }

    func testASignerJustLaunchedExportsFromTheFileItReads() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        // The app's next launch: the owner shares the record before the log's first write, once the signer has compared
        // the log as read, which the store hands it at launch (item 182, codex-3 on 68bd96b3).
        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { [signedAt] in signedAt },
                                        retryAfter: 0)
        await relaunched.logWritten(generation: 1, events: [record])
        let made = try await EvidenceExporter(signer: relaunched, mediaDirectory: media, temporaryDirectory: out)
            .folder(of: record, log: [record], in: out)
        let report = try check(try XCTUnwrap(made), chain)
        XCTAssertEqual(report.export?.record, record.id)
        XCTAssertEqual(report.export?.revision, 1)
    }

    func testABundleThatCannotBeMadeThrowsAndLeavesNothingBehind() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let photoFile = media.appendingPathComponent("photo.jpg")
        try photo.write(to: photoFile)
        var record = trip(1)
        record.mediaFilename = "photo.jpg"
        await signer.logWritten(generation: 1, events: [record])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: photoFile.path)   // cannot be read now
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: photoFile.path) }
        // Stopped when its bytes are checked against the signed revision, before anything is copied (item 190's
        // deepseek-2), where it threw at the copy before: no bundle either way.
        let made = try? await exporter(signer).bundle(of: record, log: [record])
        XCTAssertNil(made ?? nil, "a photo that cannot be read stops the bundle")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing left behind")
    }

    /// Item 190's deepseek-2: a link standing under the photo's name (an edited backup), to the very bytes signed: no
    /// bundle, as the signer signs nothing through a link and the bundle takes nothing through one.
    func testABundleIsNotMadeThroughALinkUnderThePhotosName() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let photoFile = media.appendingPathComponent("photo.jpg")
        try photo.write(to: photoFile)
        var record = trip(1)
        record.mediaFilename = "photo.jpg"
        await signer.logWritten(generation: 1, events: [record])
        let elsewhere = folder.appendingPathComponent("elsewhere.jpg")
        try photo.write(to: elsewhere)
        try FileManager.default.removeItem(at: photoFile)
        try FileManager.default.createSymbolicLink(at: photoFile, withDestinationURL: elsewhere)
        let made = try await exporter(signer).folder(of: record, log: [record], in: out.appendingPathComponent("link"))
        XCTAssertNil(made)
    }

    /// Item 190's codex-4 on 29d6501: the exporter checked the photo's bytes against the latest revision, then looked
    /// the file up again for the bundle and left out any it no longer found; the store's storage cleanup, on its own
    /// queue, can remove it in between, and the bundle went out without a file its record signed. Every attachment the
    /// latest revision signed is found, or there is no bundle.
    func testAPhotoRemovedAfterTheBytesCheckMakesNoBundle() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let photoFile = media.appendingPathComponent("photo.jpg")
        try photo.write(to: photoFile)
        var record = trip(1)
        record.mediaFilename = "photo.jpg"
        await signer.logWritten(generation: 1, events: [record])
        let exported = await signer.export(of: record.id, showing: [record.id])
        let snapshot = try XCTUnwrap(exported)
        EvidenceExporter.afterTheBytesCheckForTesting = { try? FileManager.default.removeItem(at: photoFile) }
        defer { EvidenceExporter.afterTheBytesCheckForTesting = nil }
        XCTAssertNil(EvidenceExporter.contents(of: record, log: [record], snapshot: snapshot, mediaDirectory: media))
    }

    /// And the copies the bundle holds are the bytes signed (the owner's "b"): a photo replaced between the check and its
    /// copy makes no bundle, and leaves nothing behind.
    func testAPhotoReplacedAfterTheBytesCheckMakesNoBundle() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let photoFile = media.appendingPathComponent("photo.jpg")
        try photo.write(to: photoFile)
        var record = trip(1)
        record.mediaFilename = "photo.jpg"
        await signer.logWritten(generation: 1, events: [record])
        EvidenceExporter.afterTheBytesCheckForTesting = { try? Data("a later photo".utf8).write(to: photoFile) }
        defer { EvidenceExporter.afterTheBytesCheckForTesting = nil }
        let made = try await exporter(signer).bundle(of: record, log: [record])
        XCTAssertNil(made)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing left behind")
    }

    // MARK: - One signature at a time

    func testAnExportWaitsForThePassSigningAndAWriteDuringAnExportWaitsForIt() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1)
        // A pass signing: the export asks App Attest for nothing until the pass is done.
        await keys.holdNextAssertion()
        let pass = Task { await signer.logWritten(generation: 1, events: [first]) }
        try await waitUntil { await keys.assertionRequests == 1 }
        let export = Task { await signer.export(of: first.id, showing: [first.id]) }
        try await Task.sleep(for: .milliseconds(200))
        let whilePassing = await keys.assertionRequests
        XCTAssertEqual(whilePassing, 1, "the export waits for the pass")
        await keys.releaseHeldAssertion()
        await pass.value
        let exported = await export.value
        XCTAssertEqual(exported?.signedExport, true)
        // A write during an export: signed after it, never between its statement and its snapshot.
        let second = trip(2)
        await keys.holdNextAssertion()
        let secondExport = Task { await signer.export(of: first.id, showing: [first.id]) }
        try await waitUntil { await keys.assertionRequests == 3 }
        let write = Task { await signer.logWritten(generation: 2, events: [second, first]) }
        try await Task.sleep(for: .milliseconds(200))
        let whileExporting = await keys.assertionRequests
        XCTAssertEqual(whileExporting, 3, "the write waits for the export")
        await keys.releaseHeldAssertion()
        let snapshotValue = await secondExport.value
        await write.value
        let snapshot = try XCTUnwrap(snapshotValue)
        let taken = try verify(snapshot.entries, chain)
        XCTAssertEqual(taken.map(\.counter), [1, 2, 3], "the snapshot ends with its export statement")
        XCTAssertTrue(isExport(taken.last))
        let all = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(all.map(\.counter), [1, 2, 3, 4], "the write signed after it, in the counter's order")
        XCTAssertEqual(all.last.flatMap(recordID), second.id)
    }

    // MARK: - What the bundle takes

    func testTheWatchIsItsStatusRecordsFromTheArmBeforeToTheDisarmAfter() {
        let earlierArm = status(1, "armed"), earlierDisarm = status(2, "disarmed")
        let arm = status(10, "armed"), stall = status(12, "motionStalled"), lapse = interruption(13)
        let incident = trip(14), other = trip(15), disarm = status(16, "disarmed"), afterDisarm = status(17, "backupOff")
        let laterArm = status(20, "armed")
        var mirroredArm = status(11, "armed")
        mirroredArm.sourceDevice = "Owner's iPad"
        // Newest first, as the store keeps them.
        let log = [laterArm, afterDisarm, disarm, other, incident, lapse, stall, mirroredArm, arm, earlierDisarm, earlierArm]
        XCTAssertEqual(EvidenceExporter.watch(around: incident, in: log), [arm.id, stall.id, lapse.id, disarm.id],
                       "another trip, another device's arm and a status after the disarm are not this watch's status records")
        XCTAssertEqual(EvidenceExporter.watch(around: incident, in: [incident, stall, arm]), [arm.id, stall.id],
                       "no disarm yet: to the log's end")
        XCTAssertEqual(EvidenceExporter.watch(around: incident, in: [laterArm, other, incident, arm]), [arm.id],
                       "no disarm: up to the next arm")
        XCTAssertEqual(EvidenceExporter.watch(around: incident, in: [disarm, incident, stall]), [disarm.id],
                       "no arm before it (retired): from the record itself")
        XCTAssertEqual(EvidenceExporter.watch(around: arm, in: log), [stall.id, lapse.id, disarm.id], "the arm itself")
        XCTAssertEqual(EvidenceExporter.watch(around: disarm, in: log), [arm.id, stall.id, lapse.id], "the disarm itself")
        XCTAssertEqual(EvidenceExporter.watch(around: trip(30), in: log), [], "a record not in the log")
    }

    /// Codex's codex-2 on 09d997f: the watch was found by sorting this phone's rows by their times, though the log keeps
    /// the order things happened (ADR 0069, section 6). With the clock set back during a watch it took the wrong window:
    /// the bundle showed the disarm alone, the arm and the clock's change as fingerprints, and passed. The watch is now
    /// found in the log's own order (the owner's "codex-2 a").
    func testTheWatchIsFoundInTheOrderThingsHappenedNotByTheClock() {
        // The clock set back 35 minutes between the arm and the incident.
        let arm = status(40, "armed"), back = status(5, Event.clockChangeKind(seconds: -2100))
        let incident = trip(10), disarm = status(15, "disarmed")
        XCTAssertEqual(EvidenceExporter.watch(around: incident, in: [disarm, incident, back, arm]), [arm.id, back.id, disarm.id])
        // The clock set back between two watches, the second's times among the first's.
        let firstArm = status(20, "armed"), firstTrip = trip(22), firstDisarm = status(24, "disarmed")
        let between = status(19, Event.clockChangeKind(seconds: -330))
        let secondArm = status(21, "armed"), secondTrip = trip(23), secondDisarm = status(26, "disarmed")
        // Newest first, as the store keeps them.
        let log = [secondDisarm, secondTrip, secondArm, between, firstDisarm, firstTrip, firstArm]
        XCTAssertEqual(EvidenceExporter.watch(around: firstTrip, in: log), [firstArm.id, firstDisarm.id])
        XCTAssertEqual(EvidenceExporter.watch(around: secondTrip, in: log), [secondArm.id, secondDisarm.id])
    }

    /// The same through an export: the bundle of an incident after the clock went back shows its whole watch in full,
    /// and its export statement names it.
    func testABundleAfterTheClockWentBackShowsItsWholeWatch() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let arm = status(40, "armed"), back = status(5, Event.clockChangeKind(seconds: -2100))
        let incident = trip(10), disarm = status(15, "disarmed")
        let log = [disarm, incident, back, arm]
        await signer.logWritten(generation: 1, events: log)
        let made = try await exporter(signer).folder(of: incident, log: log, in: out)
        let report = try check(try XCTUnwrap(made), chain)
        let shown = Set(report.signatures.compactMap { line -> UUID? in
            if case .record(let revision)? = line.entry?.statement { return revision.id }
            return nil
        })
        XCTAssertEqual(shown, [arm.id, back.id, incident.id, disarm.id], "the arm and the clock's change in full")
        XCTAssertEqual(report.export?.shown, try shownCounters(report))
        XCTAssertEqual(report.unshown, [])
    }

    func testTheBundlesContentsFollowTheFileInItsOrder() throws {
        let arm = status(10, "armed"), stall = status(12, "motionStalled"), incident = trip(13), other = trip(14)
        let disarm = status(15, "disarmed")
        let log = [disarm, other, incident, stall, arm]
        let keyA = Data(repeating: 0xA1, count: 32), keyB = Data(repeating: 0xB2, count: 32), keyC = Data(repeating: 0xC3, count: 32)
        let lostAt = Date(timeIntervalSince1970: 1_793_000_000)
        let entries: [EvidenceSignatureFile.Entry] = [
            .init(kind: .keyPending, key: keyA, statement: Data("statement A".utf8)),
            .init(kind: .keyCertified, key: keyA, attestation: Data("attestation A".utf8), existing: []),
            signature(keyA, record(arm, 1)),
            signature(keyA, record(incident, 1)),
            signature(keyA, export(of: other.id)),          // an earlier share's: its hash alone
            .init(kind: .keyLost, key: keyA, at: lostAt),
            .init(kind: .keyPending, key: keyC, statement: Data("statement C".utf8)),   // made, never certified
            .init(kind: .keyLost, key: keyC, at: lostAt),
            .init(kind: .keyPending, key: keyB, statement: Data("statement B".utf8)),
            .init(kind: .keyCertified, key: keyB, attestation: Data("attestation B".utf8)),
            signature(keyB, record(other, 1)),
            signature(keyB, retention(keyA)),
            signature(keyB, record(stall, 1)),
            signature(keyB, record(incident, 2)),
            signature(keyB, export(of: incident.id)),       // this export's
        ]
        let snapshot = EvidenceExportSnapshot(entries: entries, signedExport: true)
        let contents = try XCTUnwrap(EvidenceExporter.contents(of: incident, log: log, snapshot: snapshot, mediaDirectory: media))
        XCTAssertEqual(contents.record, incident.id)
        XCTAssertEqual(contents.keys, [EvidenceBundle.Key(id: keyA, statement: Data("statement A".utf8), attestation: Data("attestation A".utf8)),
                                       EvidenceBundle.Key(id: keyB, statement: Data("statement B".utf8), attestation: Data("attestation B".utf8))],
                       "the certified keys in the order certified; one never certified is not listed")
        XCTAssertEqual(contents.signatures.map(\.statement), entries.filter { $0.kind == .signature }.compactMap(\.statement), "every one, in order")
        XCTAssertEqual(contents.signatures.map(\.key), [keyA, keyA, keyA, keyB, keyB, keyB, keyB, keyB])
        XCTAssertEqual(contents.signatures.map(\.shown), [true, true, false, false, true, true, true, true])
        XCTAssertEqual(contents.notes, [.keyLost(key: keyA, at: 1_793_000_000_000), .keyLost(key: keyC, at: 1_793_000_000_000)])
        // Without this export's own statement, the last export statement in the file is shown as its hash alone.
        let withoutExport = EvidenceExportSnapshot(entries: Array(entries.dropLast()) + [signature(keyB, export(of: other.id))],
                                                   signedExport: false)
        let unsigned = try XCTUnwrap(EvidenceExporter.contents(of: incident, log: log, snapshot: withoutExport, mediaDirectory: media))
        XCTAssertEqual(unsigned.signatures.last?.shown, false)
        // A certification listed twice is one key.
        let twice = EvidenceExportSnapshot(entries: entries + [.init(kind: .keyCertified, key: keyA, attestation: Data("attestation A".utf8))],
                                           signedExport: true)
        XCTAssertEqual(EvidenceExporter.contents(of: incident, log: log, snapshot: twice, mediaDirectory: media)?.keys.map(\.id), [keyA, keyB])
        // A record with no signature in the file has no bundle.
        XCTAssertNil(EvidenceExporter.contents(of: disarm, log: log, snapshot: snapshot, mediaDirectory: media))
    }

    /// Every statement that signed records left the log other than by its limit (item 182) is shown in full, whichever
    /// record is shared.
    func testAnExportShowsEveryAbsenceStatementInFull() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let gone = trip(1), record = trip(2)
        await signer.logWritten(generation: 1, events: [record, gone])
        await signer.logWritten(generation: 2, events: [record])   // gone, not by the limit
        let made = try await exporter(signer).folder(of: record, log: [record], in: out)
        let report = try check(try XCTUnwrap(made), chain)
        XCTAssertEqual(report.absences.map { $0.records.map(\.id) }, [[gone.id]])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.export?.shown, try shownCounters(report), "the absence statement among them")
        XCTAssertEqual(report.unshown, [])
    }

    func testTheAttachmentsAreTheLatestRevisionsFromTheFilesOnThePhone() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        try photo.write(to: media.appendingPathComponent("clip.MOV"))
        var record = trip(1)
        record.mediaFilename = "clip.MOV"
        record.thumbnailData = thumbnail
        await signer.logWritten(generation: 1, events: [record])
        let made = try await exporter(signer).folder(of: record, log: [record], in: out.appendingPathComponent("whole"))
        let whole = try XCTUnwrap(made)
        XCTAssertEqual(try check(whole, chain).attachments,
                       [found("primary", .matches), found("thumbnail", .matches), found("motionTrace", .matches)])
        XCTAssertEqual(try Data(contentsOf: whole.appendingPathComponent("attachments/primary.MOV")), photo, "the clip's own extension")
        XCTAssertEqual(try Data(contentsOf: whole.appendingPathComponent("attachments/thumbnail.jpg")), thumbnail)
        XCTAssertEqual(try Data(contentsOf: whole.appendingPathComponent("attachments/motionTrace.bin")),
                       EvidenceForm.traceBytes(record.motionTrace))
        // A file named with no extension keeps the attachment's bare name.
        try photo.write(to: media.appendingPathComponent("still"))
        var bare = trip(2)
        bare.mediaFilename = "still"
        await signer.logWritten(generation: 2, events: [bare, record])
        let bareMade = try await exporter(signer).folder(of: bare, log: [bare, record], in: out.appendingPathComponent("bare"))
        let bareFolder = try XCTUnwrap(bareMade)
        XCTAssertEqual(try Data(contentsOf: bareFolder.appendingPathComponent("attachments/primary")), photo)
        XCTAssertEqual(try check(bareFolder, chain).attachments.first, found("primary", .matches))
        // The clip gone from the phone since (the storage cap), before the log's next write: no bundle, which the phone's
        // own check would read as missing the clip it signed (item 190's deepseek-2); once the record is signed without
        // it, the bundle checks out.
        try FileManager.default.removeItem(at: media.appendingPathComponent("clip.MOV"))
        let later = try await exporter(signer).folder(of: record, log: [record], in: out.appendingPathComponent("later"))
        XCTAssertNil(later)
        var without = record
        without.mediaFilename = nil
        await signer.logWritten(generation: 3, events: [bare, without])
        let signedWithout = try await exporter(signer).folder(of: without, log: [bare, without], in: out.appendingPathComponent("signed"))
        XCTAssertEqual(try check(try XCTUnwrap(signedWithout), chain).attachments,
                       [found("thumbnail", .matches), found("motionTrace", .matches)])
    }

    /// Item 190's deepseek-2 (the owner's "go on the fixes"): a bundle holds only the bytes its record's latest revision
    /// signed. The share's copy of the record changed since the signer's last pass (a thumbnail replaced, a photo
    /// attached): no bundle, so the phone's own check never reads its evidence as altered, nor leaves out a photo the
    /// screen shows; once the change is signed, the bundle checks out.
    func testABundleIsMadeOnlyFromTheBytesItsLatestRevisionSigned() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = trip(1)
        record.thumbnailData = thumbnail
        await signer.logWritten(generation: 1, events: [record])
        var replaced = record
        replaced.thumbnailData = Data("a later frame".utf8)
        let early = try await exporter(signer).folder(of: replaced, log: [replaced], in: out.appendingPathComponent("early"))
        XCTAssertNil(early, "a thumbnail the signature does not cover")
        try photo.write(to: media.appendingPathComponent("photo.jpg"))
        var attached = record
        attached.mediaFilename = "photo.jpg"
        let unsigned = try await exporter(signer).folder(of: attached, log: [attached], in: out.appendingPathComponent("photo"))
        XCTAssertNil(unsigned, "a photo no revision signed yet")
        await signer.logWritten(generation: 2, events: [attached])
        let made = try await exporter(signer).folder(of: attached, log: [attached], in: out.appendingPathComponent("signed"))
        XCTAssertEqual(try check(try XCTUnwrap(made), chain).attachments,
                       [found("primary", .matches), found("thumbnail", .matches), found("motionTrace", .matches)])
    }

    /// Item 234's A2 (Codex-2 of the third full review; the owner, 2026-11-11: "1"): a bundle shows only the facts its
    /// record's latest revision signed, as it holds only the bytes that revision signed. The record changed since the
    /// last signature (the owner's mark, set after the right PIN at the disarm): no bundle while no revision has signed
    /// it, and none after the signature of that revision failed, where the ZIP went out with the earlier facts and
    /// checked out; once the change is signed, the bundle has it.
    func testABundleIsMadeOnlyWithTheFactsItsLatestRevisionSigned() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        var marked = record
        marked.ownerAttributed = true
        let early = try await exporter(signer).folder(of: marked, log: [marked], in: out.appendingPathComponent("early"))
        XCTAssertNil(early, "a fact no revision has signed yet")
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [marked])
        let failed = try await exporter(signer).folder(of: marked, log: [marked], in: out.appendingPathComponent("failed"))
        XCTAssertNil(failed, "the revision's signature failed: the earlier facts are not sent as the event's")
        await signer.logWritten(generation: 3, events: [marked])
        let made = try await exporter(signer).folder(of: marked, log: [marked], in: out.appendingPathComponent("signed"))
        let report = try check(try XCTUnwrap(made, "no bundle once the change is signed"), chain)
        XCTAssertEqual(report.revisions.last?.facts, marked.evidenceFacts, "the bundle's latest revision has the mark")
        // The control: the record as its latest revision signed it still makes its bundle.
        let same = try await exporter(signer).folder(of: marked, log: [marked], in: out.appendingPathComponent("same"))
        XCTAssertNotNil(same)
    }

    func testTheBundleIsZippedInAFolderOfItsOwnForShare() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        let made = try await exporter(signer).bundle(of: record, log: [record])
        let zip = try XCTUnwrap(made)
        XCTAssertEqual(zip.lastPathComponent, EvidenceExporter.bundleName(for: record) + ".zip")
        let place = zip.deletingLastPathComponent()
        XCTAssertTrue(place.lastPathComponent.hasPrefix("MalinoisExport-"), place.lastPathComponent)
        XCTAssertEqual(place.deletingLastPathComponent().standardizedFileURL.path, out.standardizedFileURL.path,
                       "in the temporary folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: place.path), [zip.lastPathComponent],
                       "the folder it was made from is gone")
        let bytes = try Data(contentsOf: zip)
        XCTAssertEqual(bytes.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]), "a ZIP")
        for name in ["bundle.json", "signatures.jsonl", "notes.jsonl", "keys/", "statements/", "README.txt"] {
            XCTAssertNotNil(bytes.range(of: Data(name.utf8)), name)
        }
        // A record with no bundle leaves nothing behind.
        var mirrored = trip(2)
        mirrored.sourceDevice = "Owner's iPad"
        let none = try await exporter(signer).bundle(of: mirrored, log: [mirrored, record])
        XCTAssertNil(none)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 1, "only the first export's folder")
    }

    func testTheBundleIsNamedForTheRecordsTimeOnThePhonesClock() {
        let record = trip(13)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: record.startDate)
        let expected = String(format: "Malinois evidence %04d-%02d-%02d %02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                              parts.hour ?? 0, parts.minute ?? 0)
        XCTAssertEqual(EvidenceExporter.bundleName(for: record), expected)
    }

    // MARK: - Helpers

    /// A phone's log, signed: a trip long ago, retired since by the log's limit (a retention statement names its
    /// counter); the incident's watch (the arm, a trip, a stall, the incident with its photo, thumbnail and motion trace,
    /// another trip, the disarm); then a later watch. Each record signed once, the incident twice (the owner's "it was
    /// me"): counters 1 (the old trip), 2 to 9, 10 (the incident's second revision), 11 (the retention statement).
    private struct Scene {
        let arm: Event
        let stall: Event
        let incident: Event
        let disarm: Event
        let log: [Event]
    }

    private func signScene(_ signer: EvidenceSigner) async throws -> Scene {
        try photo.write(to: media.appendingPathComponent("photo.jpg"))
        let old = trip(1)
        let arm = status(10, "armed"), tripBefore = trip(11), stall = status(12, "motionStalled")
        var incident = trip(13)
        incident.mediaFilename = "photo.jpg"
        incident.thumbnailData = thumbnail
        let tripAfter = trip(14), disarm = status(15, "disarmed"), laterArm = status(20, "armed"), laterDisarm = status(21, "disarmed")
        await signer.certifyIfNeeded(records: [])
        await signer.logWritten(generation: 1, events: [old])
        var log = [laterDisarm, laterArm, disarm, tripAfter, incident, stall, tripBefore, arm, old]
        await signer.logWritten(generation: 2, events: log)
        incident.ownerAttributed = true
        log[4] = incident
        await signer.logWritten(generation: 3, events: log)
        log.removeLast()   // the log's limit retires the oldest
        await signer.logWritten(generation: 4, events: log, limitRemoved: [old.id: old.evidenceIdentity])
        return Scene(arm: arm, stall: stall, incident: incident, disarm: disarm, log: log)
    }

    /// The counters of the statements a bundle shows, but for its export statement's own, as its key's ranges.
    private func shownCounters(_ report: EvidenceBundle.Report) throws -> [EvidenceForm.KeyCounters] {
        let export = try XCTUnwrap(report.signatures.last?.entry)
        let shown = report.signatures.compactMap { line -> UInt32? in
            guard let entry = line.entry, entry.statement != nil, entry.counter != export.counter else { return nil }
            return entry.counter
        }
        return [EvidenceForm.KeyCounters(keyID: export.keyID, counters: EvidenceForm.counterRanges(shown))]
    }

    private func makeSigner() throws -> (EvidenceSigner, FakeKeyService, TestAttestationChain) {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let time = TestClock(signedAt)
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { time.now }, retryAfter: 0)
        return (signer, keys, chain)
    }

    private func exporter(_ signer: EvidenceSigner) -> EvidenceExporter {
        EvidenceExporter(signer: signer, mediaDirectory: media, temporaryDirectory: out)
    }

    private func check(_ bundle: URL, _ chain: TestAttestationChain) throws -> EvidenceBundle.Report {
        try EvidenceBundle.check(bundle, appID: TestApp.id, roots: [chain.rootDER])
    }

    private func trip(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }

    private func status(_ minute: Int, _ kind: String) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, minute)
        return Event(startDate: start, endDate: start, triggeredSensors: [], stateChange: kind)
    }

    private func interruption(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, minute)
        return Event(startDate: start, endDate: start, triggeredSensors: [], interrupted: true)
    }

    private func record(_ event: Event, _ revision: Int64) -> EvidenceForm.Statement {
        .record(event.evidenceRecord(revision: revision, signedAt: signedAt, app: "1.10 (81)", primary: nil, secondary: nil))
    }

    private func retention(_ key: Data) -> EvidenceForm.Statement {
        .retention(EvidenceForm.Retention(signedAt: 1, app: "1.10 (81)", retired: [EvidenceForm.Retired(keyID: key, counters: [1...1])]))
    }

    private func export(of record: UUID) -> EvidenceForm.Statement {
        .export(EvidenceForm.Export(record: record, revision: 1, signedAt: 1, app: "1.10 (81)"))
    }

    /// A signature line as the file keeps it; its assertion is not checked here.
    private func signature(_ key: Data, _ statement: EvidenceForm.Statement) -> EvidenceSignatureFile.Entry {
        var recordID: UUID?
        if case .record(let revision) = statement { recordID = revision.id }
        return .init(kind: .signature, key: key, statement: EvidenceForm.bytes(statement), assertion: Data([1]), record: recordID)
    }

    private func found(_ name: String, _ outcome: EvidenceBundle.AttachmentOutcome) -> EvidenceBundle.AttachmentCheck {
        EvidenceBundle.AttachmentCheck(name: name, outcome: outcome)
    }

    /// Every signature in `entries`, checked with the verifier's rules under the key the file certifies.
    private func verify(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> [EvidenceSignedEntry] {
        let keys = try entries.filter { $0.kind == .keyCertified }.map { certified in
            let pending = try XCTUnwrap(entries.last { $0.kind == .keyPending && $0.key == certified.key })
            return try EvidenceVerifier.certify(attestation: try XCTUnwrap(certified.attestation),
                                                statement: try XCTUnwrap(pending.statement), appID: TestApp.id, roots: [chain.rootDER])
        }
        return try entries.filter { $0.kind == .signature }.map { entry in
            let key = try XCTUnwrap(keys.first { $0.keyID == entry.key })
            let statement = try XCTUnwrap(entry.statement)
            return try EvidenceVerifier.check(assertion: try XCTUnwrap(entry.assertion), formHash: TestApp.sha256(statement),
                                              form: statement, under: key)
        }
    }

    private func recordID(_ entry: EvidenceSignedEntry) -> UUID? {
        if case .record(let form)? = entry.statement { return form.id }
        return nil
    }

    private func isExport(_ entry: EvidenceSignedEntry?) -> Bool {
        if case .export? = entry?.statement { return true }
        return false
    }

    /// The element at `index`, or nil: a list too short fails the assertion that reads it, not the whole class.
    private func at<Element>(_ list: [Element], _ index: Int) -> Element? { list.indices.contains(index) ? list[index] : nil }

    /// Waits, up to 5 seconds, until `condition` holds.
    private func waitUntil(_ condition: () async -> Bool) async throws {
        var waited = 0
        while !(await condition()), waited < 500 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        let held = await condition()
        XCTAssertTrue(held, "waited 5 seconds")
    }
}
