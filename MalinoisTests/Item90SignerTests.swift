//
//  Item90SignerTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 2: the signer. This install's key is made and certified once, with a statement Apple's
//  certificate covers; every record first written after that is signed at each revision, once the log that holds it is
//  on disk, and nothing else is: not the records the log held before, not another device's copies, not a revision whose
//  content did not change. A signature that fails is tried again at the next write and never touches the log; a key
//  App Attest lost is followed by a new one; records the log's limit retired are named in a signed retention statement
//  and leave the file, while those that left with a log the launch did not read (set aside as unreadable, at that
//  launch or at one that ended before writing a new log) are noted as set aside, and any other signed record that leaves
//  the log is named in a signed absence statement, its signatures kept, and the event log says so once (item 182: the
//  owner's "a" and "1 - a, 2 - a, 3 - wording approved"; the store keeps the limit's removals on disk before the log
//  that drops them). What the signer writes is checked
//  with the verifier's own rules (ADR 0065). App Attest does not run in the Simulator, so a stand-in made with
//  CryptoKit plays it, in Apple's formats. Written before the code, red at that commit (against compile-only stubs).
//

import CryptoKit
import DeviceCheck
import Synchronization
import SwiftUI
import Security
import XCTest
@testable import Malinois

@MainActor
final class Item90SignerTests: XCTestCase {

    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item90Signer-\(UUID().uuidString)")
    nonisolated private var media: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }
    private let signedAt = TestApp.date(2026, 10, 31, 2, 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - The key

    func testTheKeyIsMadeAndCertifiedOnceForAStatementThatVerifies() async throws {
        let (signer, keys, chain) = try makeSigner()
        let old = event(1)
        await signer.certifyIfNeeded(records: [old.id])
        await signer.certifyIfNeeded(records: [old.id])
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyCertified], "one key, certified once")
        let attests = await keys.attestRequests.count
        XCTAssertEqual(attests, 1)
        XCTAssertEqual(at(entries, 1)?.existing, [old.id], "the records the log held then")
        let key = try certifiedKey(entries, chain)
        XCTAssertEqual(key.keyID, at(entries, 0)?.key)
        XCTAssertEqual(key.statement.app, "1.10 (81)")
        XCTAssertEqual(key.statement.signedAt, 1_793_412_000_000)
        XCTAssertNil(key.statement.follows)
    }

    func testNothingHappensWhileTheLogIsNotRead() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: nil)
        XCTAssertEqual(file.read(), [])
        let made = await keys.keysMade
        XCTAssertEqual(made, 0)
    }

    func testADeviceWithoutAppAttestSignsNothingAndSaysSoOnce() async throws {
        let (signer, keys, _) = try makeSigner(supported: false)
        await signer.certifyIfNeeded(records: [])
        await signer.certifyIfNeeded(records: [])
        await signer.logWritten(generation: 1, events: [event(1)])
        await relaunch(keys).certifyIfNeeded(records: [])   // nor again after a relaunch
        XCTAssertEqual(file.read()?.map(\.kind), [.unsupported])
        let asked = await keys.keyRequests
        XCTAssertEqual(asked, 0, "App Attest not asked for a key")
    }

    func testACertificationApplesServiceDidNotAnswerIsTriedAgainWithTheSameKeyAndStatement() async throws {
        let (signer, keys, chain) = try makeSigner()
        await keys.failNextAttestations([DCError(.serverUnavailable), DCError(.serverUnavailable)])
        await signer.certifyIfNeeded(records: [])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending], "the statement kept for the next try")
        await signer.certifyIfNeeded(records: [])
        await relaunch(keys).certifyIfNeeded(records: [])   // and after a relaunch
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyCertified])
        let requests = await keys.attestRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map(\.key)).count, 1, "the same key")
        XCTAssertEqual(Set(requests.map(\.hash)).count, 1, "the same statement")
        XCTAssertNoThrow(try certifiedKey(entries, chain))
    }

    func testTwoCertificationsAtOnceAskAppleOnce() async throws {
        let (signer, keys, _) = try makeSigner()
        await keys.holdNextAttestation()
        let launch = Task { await signer.certifyIfNeeded(records: []) }
        try await waitForAttestRequests(keys, count: 1)
        await signer.certifyIfNeeded(records: [])   // the app came forward before Apple answered
        await keys.releaseHeldAttestation()
        await launch.value
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .keyCertified])
        let requests = await keys.attestRequests.count
        XCTAssertEqual(requests, 1)
    }

    /// Apple certified the key, but the file would not take the line saying so: the key is never used, App Attest will
    /// not certify it twice, and a new key follows.
    func testACertificationTheFileDidNotKeepIsNeverUsed() async throws {
        let (signer, keys, chain) = try makeSigner()
        await keys.holdNextAttestation()
        let launch = Task { await signer.certifyIfNeeded(records: []) }
        try await waitForAttestRequests(keys, count: 1)
        try setFileWritable(false)
        await keys.releaseHeldAttestation()
        await launch.value
        try setFileWritable(true)
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending])
        await signer.logWritten(generation: 1, events: [event(1)])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending], "nothing signed by a key the file does not show certified")
        await signer.certifyIfNeeded(records: [])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .keyLost], "App Attest certifies a key once")
        await relaunch(keys).certifyIfNeeded(records: [])   // a relaunch goes on from the file: a new key
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyLost, .keyPending, .keyCertified])
        XCTAssertNotEqual(at(entries, 2)?.key, at(entries, 0)?.key)
        XCTAssertNil(try certifiedKey(entries, chain).statement.follows, "no key was certified before it")
    }

    func testAKeyAppAttestWillNotCertifyIsFollowedByANewOneAtTheNextTry() async throws {
        let (signer, keys, chain) = try makeSigner()
        await keys.failNextAttestations([DCError(.invalidKey)])
        await signer.certifyIfNeeded(records: [])
        await signer.certifyIfNeeded(records: [])
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyLost, .keyPending, .keyCertified])
        XCTAssertNotEqual(at(entries, 2)?.key, at(entries, 0)?.key, "a new key, not the one App Attest refused")
        XCTAssertNoThrow(try certifiedKey(entries, chain))
    }

    func testAKeyAppleWillNotCertifyOnThisDeviceIsNotedAsUnsupported() async throws {
        let (signer, keys, _) = try makeSigner()
        await keys.failNextAttestations([DCError(.featureUnsupported)])
        await signer.certifyIfNeeded(records: [])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .unsupported])
    }

    func testASignatureFileThatCannotBeReadOrWrittenIsLeftAlone() async throws {
        let (signer, keys, _) = try makeSigner()
        XCTAssertTrue(FileManager.default.createFile(atPath: file.url.path, contents: Data()))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        await signer.certifyIfNeeded(records: [])
        await signer.logWritten(generation: 1, events: [event(1)])
        let made = await keys.keysMade
        XCTAssertEqual(made, 0, "nothing while the file cannot be read")
        // Readable, not writable: Apple is not asked to certify a statement the file did not keep.
        try setFileWritable(false)
        await signer.certifyIfNeeded(records: [])
        let asked = await keys.attestRequests.count
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(file.read(), [])
        try setFileWritable(true)
        await signer.certifyIfNeeded(records: [])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .keyCertified], "once it can")
    }

    func testAFailedCertificationWaitsBeforeTheNextTry() async throws {
        let clock = TestClock(signedAt)
        let (signer, keys, _) = try makeSigner(clock: clock, retryAfter: 60)
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await signer.certifyIfNeeded(records: [])
        await signer.certifyIfNeeded(records: [])
        var tries = await keys.attestRequests.count
        XCTAssertEqual(tries, 1, "not again within the wait")
        clock.advance(61)
        await signer.certifyIfNeeded(records: [])
        tries = await keys.attestRequests.count
        XCTAssertEqual(tries, 2)
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .keyCertified])
    }

    // MARK: - Signing

    func testARecordWrittenAfterCertificationIsSignedAtEachRevisionThatChangesIt() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = event(1)
        await signer.logWritten(generation: 1, events: [record])
        await signer.logWritten(generation: 2, events: [record])
        record.ownerAttributed = true
        await signer.logWritten(generation: 3, events: [record])
        let entries = try XCTUnwrap(file.read())
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2], "an unchanged revision is not signed again")
        let forms = checked.compactMap { entry -> EvidenceForm.Record? in
            if case .record(let form)? = entry.statement { return form }
            return nil
        }
        XCTAssertEqual(forms.map(\.revision), [1, 2])
        XCTAssertEqual(forms.map(\.id), [record.id, record.id])
        XCTAssertEqual(forms.last?.facts, record.evidenceFacts)
        XCTAssertEqual(forms.last?.app, "1.10 (81)")
        XCTAssertEqual(forms.last?.signedAt, 1_793_412_000_000)
    }

    func testRecordsTheLogHeldBeforeCertificationAndOtherDevicesCopiesAreNeverSigned() async throws {
        let (signer, _, chain) = try makeSigner()
        var before = event(1)
        await signer.logWritten(generation: 1, events: [before])
        XCTAssertEqual(file.read(), [], "nothing signs before the key is certified")
        await signer.certifyIfNeeded(records: [before.id])
        var mirrored = event(2)
        mirrored.sourceDevice = "Owner's iPad"
        let after = event(3)
        before.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [after, mirrored, before])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(recordID), [after.id], "only the record first written after certification")
    }

    func testAFailedSignatureIsTriedAgainAtTheNextWrite() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        let record = event(1)
        await signer.logWritten(generation: 1, events: [record])
        XCTAssertEqual(file.read()?.filter { $0.kind == .signature }, [])
        await signer.logWritten(generation: 2, events: [record])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(recordID), [record.id])
    }

    /// Regression: a signature was asked for while the file could not take it (as while the phone is locked), so App
    /// Attest's counter moved on with nothing in the file, and the gap read as a signature removed.
    func testNoSignatureIsAskedForWhileTheFileCannotTakeIt() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = event(1)
        try setFileWritable(false)
        await signer.logWritten(generation: 1, events: [record])
        try setFileWritable(true)
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 0, "no signature spent")
        await signer.logWritten(generation: 2, events: [record])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(recordID), [record.id])
        let report = EvidenceVerifier.sequence(of: checked, keyID: try XCTUnwrap(checked.first?.keyID), followers: [])
        XCTAssertEqual(report.missing, [], "no counter without its signature")
    }

    func testASignatureTheFileRefusedOnceItWasMadeIsMadeAgainAtTheNextWrite() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = event(1)
        await keys.holdNextAssertion()
        let write = Task { await signer.logWritten(generation: 1, events: [record]) }
        try await waitUntil { await keys.assertionRequests == 1 }
        try setFileWritable(false)   // the phone locked while the signature was being made
        await keys.releaseHeldAssertion()
        await write.value
        try setFileWritable(true)
        XCTAssertEqual(file.read()?.filter { $0.kind == .signature }, [])
        await signer.logWritten(generation: 2, events: [record])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(recordID), [record.id], "made again")
    }

    func testAWriteDuringAPassIsTakenWhenThePassEnds() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = event(1)
        await keys.holdNextAssertion()
        let firstWrite = Task { [record] in await signer.logWritten(generation: 1, events: [record]) }
        try await waitUntil { await keys.assertionRequests == 1 }
        record.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [record])   // a pass is running: queued for it
        await keys.releaseHeldAssertion()
        await firstWrite.value
        let forms = try verify(try XCTUnwrap(file.read()), chain).compactMap { entry -> EvidenceForm.Record? in
            if case .record(let form)? = entry.statement { return form }
            return nil
        }
        XCTAssertEqual(forms.map(\.revision), [1, 2], "one pass at a time: the write that came during it, signed after it")
        XCTAssertEqual(forms.last?.facts, record.evidenceFacts)
    }

    func testAnOlderWriteArrivingLateIsIgnored() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = event(1)
        record.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [record])
        record.ownerAttributed = nil
        await signer.logWritten(generation: 1, events: [record])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.count, 1, "the late, older write signs nothing")
        if case .record(let form)? = checked.first?.statement {
            XCTAssertEqual(form.facts.first { $0.key == "ownerAttributed" }?.value, .bool(true))
        } else {
            XCTFail("no record signed")
        }
    }

    func testAPhotoOrClipIsCoveredByItsFileWhenItIsThere() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let clip = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0) })
        try clip.write(to: media.appendingPathComponent("clip.mov"))
        var record = event(1)
        record.mediaFilename = "clip.mov"
        record.secondaryMediaFilename = "gone.jpg"   // named, but no longer on the phone: left out
        // A file that is there but cannot be read now (a folder stands in for a sealed file): the record waits.
        var waiting = event(2)
        waiting.mediaFilename = "sealed.mov"
        try FileManager.default.createDirectory(at: media.appendingPathComponent("sealed.mov"), withIntermediateDirectories: true)
        await signer.logWritten(generation: 1, events: [record, waiting])
        var checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(recordID), [record.id])
        if case .record(let form)? = checked.first?.statement {
            XCTAssertEqual(form.attachments.map(\.name), ["primary", "motionTrace"], "the clip and the trace; the missing photo left out")
            XCTAssertEqual(form.attachments.first?.digest, EvidenceForm.Digest(sha256: TestApp.sha256(clip), bytes: 3_000))
        }
        try FileManager.default.removeItem(at: media.appendingPathComponent("sealed.mov"))
        try Data([1, 2, 3]).write(to: media.appendingPathComponent("sealed.mov"))
        await signer.logWritten(generation: 2, events: [record, waiting])
        checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(recordID), [record.id, waiting.id], "signed once its file could be read")
    }

    func testOnlyAPlainReadableFileInTheMediaFolderIsHashed() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let outside = folder.appendingPathComponent("outside.jpg")
        try Data([9, 9, 9]).write(to: outside)
        // Names that are not a plain file name in the media folder: the attachment is left out.
        let named = ["../outside.jpg", ".", "..", ""].enumerated().map { index, name in
            var record = event(index + 1)
            record.mediaFilename = name
            return record
        }
        // A link out of the folder, and a file that cannot be read now: the record waits.
        try FileManager.default.createSymbolicLink(at: media.appendingPathComponent("link.jpg"), withDestinationURL: outside)
        var linked = event(5)
        linked.mediaFilename = "link.jpg"
        let locked = media.appendingPathComponent("locked.jpg")
        try Data([1]).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        var unreadable = event(6)
        unreadable.mediaFilename = "locked.jpg"
        await signer.logWritten(generation: 1, events: named + [linked, unreadable])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(Set(checked.compactMap(recordID)), Set(named.map(\.id)), "the four signed; the link and the locked file wait")
        for entry in checked {
            if case .record(let form)? = entry.statement { XCTAssertEqual(form.attachments.map(\.name), ["motionTrace"]) }
        }
    }

    func testAFileThatChangedIsHashedAgainAtTheNextRevision() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let photo = media.appendingPathComponent("photo.jpg")
        let stamp = TestApp.date(2026, 10, 31, 0, 0)   // whole seconds: the file system keeps them exactly
        let contents = [Data([1, 2, 3]), Data([1, 2, 3, 4]), Data([5, 6, 7, 8])]
        try contents[0].write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: photo.path)
        var record = event(1)
        record.mediaFilename = "photo.jpg"
        await signer.logWritten(generation: 1, events: [record])
        // Longer, with the same time: the size tells.
        try contents[1].write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: photo.path)
        record.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [record])
        // The same length, written later: the time tells.
        try contents[2].write(to: photo)
        try FileManager.default.setAttributes([.modificationDate: stamp.addingTimeInterval(10)], ofItemAtPath: photo.path)
        record.ownerAttributed = false
        await signer.logWritten(generation: 3, events: [record])
        let digests = try verify(try XCTUnwrap(file.read()), chain).compactMap { entry -> EvidenceForm.Digest? in
            if case .record(let form)? = entry.statement { return form.attachments.first { $0.name == "primary" }?.digest }
            return nil
        }
        XCTAssertEqual(digests, contents.map { EvidenceForm.Digest(sha256: TestApp.sha256($0), bytes: Int64($0.count)) })
    }

    // MARK: - A lost key, a relaunch

    func testAKeyAppAttestLostIsFollowedByANewOne() async throws {
        let (signer, keys, chain) = try makeSigner()
        let old = event(9)   // in the log before the first certification: signed by neither key
        await signer.certifyIfNeeded(records: [old.id])
        var record = event(1)
        await signer.logWritten(generation: 1, events: [record, old])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        record.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [record, old])
        await signer.logWritten(generation: 3, events: [record, old])
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyCertified, .signature, .keyLost, .keyPending, .keyCertified, .signature])
        XCTAssertEqual(at(entries, 3)?.key, first)
        XCTAssertEqual(at(entries, 1)?.existing, [old.id])
        XCTAssertEqual(at(entries, 5)?.kind, .keyCertified)
        XCTAssertNil(at(entries, 5)?.existing, "only the install's first certification notes the log")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.map(\.counter), [1, 1], "each key's counter starts at 1")
        XCTAssertNotEqual(at(checked, 0)?.keyID, at(checked, 1)?.keyID)
        let second = try certifiedKeys(entries, chain)
        XCTAssertEqual(second.last?.statement.follows, first, "the new key names the one it follows")
        if case .record(let form)? = checked.last?.statement { XCTAssertEqual(form.revision, 2) }
    }

    func testASignerReadingTheFileAfterARelaunchGoesOnFromIt() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = event(1)
        await signer.logWritten(generation: 1, events: [record])
        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { [signedAt] in signedAt },
                                        retryAfter: 0)
        await relaunched.certifyIfNeeded(records: [record.id])
        await relaunched.logWritten(generation: 1, events: [record])
        record.ownerAttributed = true
        await relaunched.logWritten(generation: 2, events: [record])
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.filter { $0.kind == .keyPending }.count, 1, "the certified key is reused")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2], "the unchanged record not signed again; the change is revision 2")
        if case .record(let form)? = checked.last?.statement { XCTAssertEqual(form.revision, 2) }
    }

    func testARelaunchAfterALostKeySignsNothingUntilTheNewKeyIsCertified() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var record = event(1)
        await signer.logWritten(generation: 1, events: [record])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        record.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [record])
        XCTAssertEqual(file.read()?.map(\.kind), [.keyPending, .keyCertified, .signature, .keyLost, .keyPending])
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [record])
        XCTAssertEqual(file.read()?.count, 5, "nothing signed with the lost key")
        await relaunched.certifyIfNeeded(records: nil)
        await relaunched.logWritten(generation: 2, events: [record])
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.map(\.kind), [.keyPending, .keyCertified, .signature, .keyLost, .keyPending, .keyCertified, .signature])
        XCTAssertEqual(try verify(entries, chain).map(\.counter), [1, 1])
    }

    // MARK: - Records leaving the log

    func testRecordsTheLimitRetiredAreNamedInASignedRetentionStatement() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2), c = event(3)
        await signer.logWritten(generation: 1, events: [c, b, a])
        await signer.logWritten(generation: 2, events: [c, a], limitRemoved: removed(b))
        let entries = try XCTUnwrap(file.read())
        XCTAssertFalse(entries.contains { $0.record == b.id }, "the retired record's signature left the file")
        let checked = try verify(entries, chain)
        let retention = checked.compactMap { entry -> EvidenceForm.Retention? in
            if case .retention(let statement)? = entry.statement { return statement }
            return nil
        }
        XCTAssertEqual(retention.count, 1)
        let report = EvidenceVerifier.sequence(of: checked, keyID: try XCTUnwrap(checked.first?.keyID), followers: [])
        XCTAssertEqual(report.counters.count, 3, "two records and the retention statement")
        XCTAssertEqual(report.retired.count, 1)
        XCTAssertEqual(report.missing, [], "every counter accounted for")
    }

    /// codex-2 on 5fa9ec18 (the owner's "a"): signed records that left with a log the launch could not read are named
    /// gone like any other, their signatures kept, never retired. One back in the log later, unchanged, is neither signed
    /// nor named again, and no later launch, reading its log or not, names them again.
    func testRecordsAnUnreadableLogTookAreNamedGoneNotRetired() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        // The next launch set the log aside: a fresh log, without them.
        let relaunched = relaunch(keys)
        let fresh = event(3)
        await relaunched.logWritten(generation: 1, events: [fresh])
        await relaunched.logWritten(generation: 2, events: [fresh])
        let entries = try XCTUnwrap(file.read())
        XCTAssertTrue(entries.contains { $0.record == a.id } && entries.contains { $0.record == b.id }, "their signatures kept")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(absence).map { Set($0.records.map(\.id)) }, [[a.id, b.id]], "named gone, once")
        XCTAssertFalse(checked.contains(where: isRetention))
        XCTAssertTrue(checked.contains { recordID($0) == fresh.id })
        // Later at that launch the limit retires the fresh record, and a is in the log again, unchanged: the one retired,
        // the other neither signed nor named again.
        await relaunched.logWritten(generation: 3, events: [a], limitRemoved: removed(fresh))
        let later = try XCTUnwrap(file.read())
        XCTAssertEqual(later.filter { $0.record == a.id }.count, 1, "a not signed again")
        XCTAssertEqual(try verify(later, chain).filter(isRetention).count, 1, "the fresh record retired")
        // A launch after that reads its log, and one after that does not: neither names nor retires them.
        await relaunch(keys).logWritten(generation: 1, events: [a])
        await relaunch(keys).logWritten(generation: 1, events: [])
        let next = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(next.compactMap(absence).count, 1, "named once")
        XCTAssertEqual(next.filter(isRetention).count, 1)
    }

    func testARecordTheLimitRetiredAsTheLogLoadedIsRetiredAtTheFirstWrite() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        // The next launch read the log, and the limit trimmed b as it loaded.
        await relaunch(keys).logWritten(generation: 1, events: [a], limitRemoved: removed(b))
        let entries = try XCTUnwrap(file.read())
        XCTAssertFalse(entries.contains { $0.record == b.id }, "its signature left with the statement")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.filter(isRetention).count, 1)
        XCTAssertEqual(checked.compactMap(absence).count, 0, "nothing named gone")
    }

    func testARetentionStatementThatCouldNotBeSignedKeepsTheSignaturesUntilItIs() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [a], limitRemoved: removed(b))
        XCTAssertTrue(file.read()?.contains { $0.record == b.id } == true, "kept while no statement names it")
        await signer.logWritten(generation: 3, events: [a], limitRemoved: removed(b))
        let entries = try XCTUnwrap(file.read())
        XCTAssertFalse(entries.contains { $0.record == b.id })
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.filter(isRetention).count, 1)
        let report = EvidenceVerifier.sequence(of: checked, keyID: try XCTUnwrap(checked.first?.keyID), followers: [])
        XCTAssertEqual(report.missing, [], "every counter accounted for")
    }

    func testAnUnreadLogsRecordsAreNamedGoneAtTheFirstWriteThatCanReadTheFile() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let relaunched = relaunch(keys)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
        await relaunched.logWritten(generation: 1, events: [])   // the file cannot be read yet
        try setFileWritable(true)
        await relaunched.logWritten(generation: 2, events: [])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[a.id]])
        XCTAssertFalse(checked.contains(where: isRetention))
    }

    /// Regression: when the file would not take what a launch's first write found of signed records gone with a log it
    /// did not read, the next write signed a retention statement for them, as if the limit had retired them. They are
    /// named gone at the next write (codex-2 on 5fa9ec18, the owner's "a").
    func testRecordsAnUnreadLogTookAreNamedGoneAtTheNextWriteWhenTheFileRefusedTheFirst() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let relaunched = relaunch(keys)
        let fresh = event(3)
        try setFileWritable(false)
        await relaunched.logWritten(generation: 1, events: [fresh])
        try setFileWritable(true)
        XCTAssertEqual(file.read()?.count, 4, "the file took nothing: the key's two lines and two signatures")
        await relaunched.logWritten(generation: 2, events: [fresh])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { Set($0.records.map(\.id)) }, [[a.id, b.id]], "named gone")
        XCTAssertFalse(checked.contains(where: isRetention), "not retired")
        XCTAssertEqual(checked.compactMap(recordID), [b.id, a.id, fresh.id], "the signature the file refused, made at the next write")
    }

    // MARK: - In the app

    func testTheEventLogTellsOfEachWriteOnDiskInOrder() throws {
        TestIsolation.setUp(folderPrefix: "Item90DurableWrite")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        var heard: [(Int, [UUID])] = []
        store.onDurableWrite = { generation, events in heard.append((generation, events.map(\.id))) }
        let first = event(1), second = event(2)
        store.add(first)
        store.add(second)
        store.drainIOForTesting()
        XCTAssertTrue(pump(until: { heard.count == 3 }, timeout: 5))
        let start = heard.first?.0 ?? 0
        XCTAssertEqual(heard.map(\.0), [start, start + 1, start + 2], "rising: the log as read at launch, then one a write")
        XCTAssertEqual(heard.first?.1, [], "a first launch: no log on disk")
        XCTAssertEqual(heard.last?.1, [second.id, first.id])
    }

    func testTheAppsSigningCertifiesAtLaunchAndSignsWhatTheLogWrites() throws {
        TestIsolation.setUp(folderPrefix: "Item90Signing")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let keys = FakeKeyService(chain: try TestAttestationChain())
        let signing = EvidenceSigning(store: store, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyCertified } == true }, timeout: 5), "certified at launch")
        store.add(event(1))
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .signature } == true }, timeout: 5), "signed after the write")
        withExtendedLifetime(signing) {}
    }

    func testComingForwardAsksForTheCertificationAgain() throws {
        TestIsolation.setUp(folderPrefix: "Item90SigningForward")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let keys = FakeKeyService(chain: try TestAttestationChain(), attestFailures: [DCError(.serverUnavailable)])
        let center = NotificationCenter()
        let signing = EvidenceSigning(store: store, keys: keys, center: center, retryAfter: 0)
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyPending } == true }, timeout: 5))
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyCertified } == true }, timeout: 5),
                      "certified when the app came forward")
        withExtendedLifetime(signing) {}
    }

    func testTheLaunchBuildsTheSigningBesideTheLog() {
        TestIsolation.setUp(folderPrefix: "Item90SigningLaunch")
        defer { TestIsolation.tearDown() }
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        XCTAssertNotNil(services.eventStore.onDurableWrite, "the signing hears the log's writes")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    // MARK: - The log's load, as the signing sees it

    func testTheLogTakesWritesOnlyOnceItsLoadIsSettled() throws {
        TestIsolation.setUp(folderPrefix: "Item90SigningLoad")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        XCTAssertTrue(EventStore().acceptsWrites, "a first launch: no log yet, and the records in memory are the log's")
        // A log that cannot be read while UIKit says the phone is locked: its load waits for the unlock.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events.json"), withIntermediateDirectories: true)
        XCTAssertFalse(EventStore(protectedDataAvailable: { false }).acceptsWrites, "waiting for the unlock")
        // Unreadable with the phone unlocked, in a folder that will not take the backup: the load failed (R-05).
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let failed = EventStore(protectedDataAvailable: { true })
        XCTAssertTrue(failed.loadFailed)
        XCTAssertFalse(failed.acceptsWrites, "the load failed")
    }

    /// A launch before the first unlock: the key waits for the log, so the first certification notes what it holds.
    func testALockedLogIsReadBeforeTheKeyIsCertified() throws {
        TestIsolation.setUp(folderPrefix: "Item90SigningLocked")
        defer { TestIsolation.tearDown() }
        let log = try logURL()
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let store = EventStore(protectedDataAvailable: { false })
        let center = NotificationCenter()
        let signing = EvidenceSigning(store: store, keys: FakeKeyService(chain: try TestAttestationChain()), center: center)
        // The phone unlocks, and the log, holding a record from before, is read.
        let earlier = event(1)
        try FileManager.default.removeItem(at: log)
        try JSONEncoder().encode([earlier]).write(to: log)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.acceptsWrites && store.events.map(\.id) == [earlier.id] }, timeout: 5), "read at the unlock")
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyCertified } == true }, timeout: 5))
        XCTAssertEqual(appFile.read()?.first { $0.kind == .keyCertified }?.existing, [earlier.id],
                       "certified once the log was read, noting the record it held, never to be signed")
        withExtendedLifetime(signing) {}
    }

    /// codex-2 on 5fa9ec18 (the owner's "a"), through the app's own log and signing: a signed record that left with a
    /// damaged log is named gone at the next write.
    func testRecordsADamagedLogTookAreNamedGoneAtTheNextWrite() throws {
        TestIsolation.setUp(folderPrefix: "Item90SigningDamaged")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let signed = try launchSigningOneRecord(keys)
        // The next launch finds the log damaged and sets it aside, the signed record in it; a write follows.
        try Data("damaged".utf8).write(to: logURL())
        let relaunched = EventStore()
        XCTAssertTrue(relaunched.logWasQuarantined)
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        relaunched.add(event(2))
        try assertNamedGoneNotRetired(signed, store: relaunched, chain)
        withExtendedLifetime(signing) {}
    }

    /// Regression: the log was set aside at one launch with no write after it, so the next launch found none. The
    /// signed records went with the log, not by the limit: no retention statement may say so. They are named gone
    /// (codex-2 on 5fa9ec18, the owner's "a").
    func testRecordsALogMissingAtLaunchTookAreNamedGoneNotRetired() throws {
        TestIsolation.setUp(folderPrefix: "Item90SigningMissing")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let signed = try launchSigningOneRecord(keys)
        try Data("damaged".utf8).write(to: logURL())
        let settingAside = EventStore()
        XCTAssertTrue(settingAside.logWasQuarantined)
        settingAside.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try logURL().path), "the app ended before writing a log")
        let relaunched = EventStore()
        XCTAssertFalse(relaunched.logWasQuarantined, "nothing to set aside at this launch")
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        relaunched.add(event(2))
        try assertNamedGoneNotRetired(signed, store: relaunched, chain)
        withExtendedLifetime(signing) {}
    }

    // MARK: - A signed record that leaves the log other than by its limit (item 182; the owner's "a", 2026-10-31)

    /// The limit's removals alone are retired. Any other signed record that leaves the log is named in a signed absence
    /// statement, its signatures kept (the owner's "1 - a"), and the event log is told, once.
    func testOnlyTheLimitsRemovalsAreRetiredAndAnyOtherLeavingIsDeclared() async throws {
        let (signer, _, chain) = try makeSigner()
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2), c = event(3)
        await signer.logWritten(generation: 1, events: [c, b, a])
        await signer.logWritten(generation: 2, events: [c], limitRemoved: removed(b))
        let entries = try XCTUnwrap(file.read())
        XCTAssertFalse(entries.contains { $0.record == b.id }, "the limit's removal: its signature left with the statement")
        XCTAssertTrue(entries.contains { $0.record == a.id }, "the other's signature kept")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(retention).count, 1)
        let absences = checked.compactMap(absence)
        XCTAssertEqual(absences.map(\.records), [[EvidenceForm.Absent(id: a.id, revision: 1,
                                                                    startDate: EvidenceForm.milliseconds(since1970: a.startDate))]])
        XCTAssertEqual(absences.first?.app, "1.10 (81)")
        XCTAssertEqual(absences.first?.signedAt, 1_793_412_000_000)
        XCTAssertEqual(lines.written, [Event.signedRecordsGoneKind(count: 1, first: a.startDate, last: a.startDate)])
        XCTAssertEqual(entries.filter { $0.kind == .absenceLogged }.count, 0, "noted only once the log on disk holds it")
        await signer.logWritten(generation: 3, events: lines.events + [c])
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]], "the line noted as written")
        let keyID = try XCTUnwrap(checked.first?.keyID)
        XCTAssertEqual(EvidenceVerifier.sequence(of: checked, keyID: keyID, followers: []).missing, [], "every counter accounted for")
    }

    /// A record deleted here whose iCloud copy came back before the signer's pass: a copy never stands for this phone's own
    /// record, so the record is no longer in the log.
    func testARecordHeldOnlyAsAnICloudCopyIsNoLongerInTheLog() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        var copy = a
        copy.sourceDevice = "iPhone Air"   // as the pull brings it back: another device's copy, by the record's ID
        await signer.logWritten(generation: 2, events: [b, copy])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).map { $0.records.map(\.id) }, [[a.id]])
    }

    func testARecordGoneIsDeclaredOnceAcrossWritesAndRelaunches() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await signer.logWritten(generation: 2, events: [b])
        var later = b
        later.ownerAttributed = true
        await signer.logWritten(generation: 3, events: [later])
        await relaunch(keys).logWritten(generation: 1, events: [later])
        let entries = try XCTUnwrap(file.read())
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(absence).count, 1)
        XCTAssertEqual(checked.compactMap(retention).count, 0, "never retired")
        XCTAssertEqual(entries.filter { $0.record == a.id }.count, 1, "its signature kept")
    }

    /// Records gone at one write: one statement, its records in ascending order, and one line with their count and their
    /// first and last times (the owner's "2 - a").
    func testRecordsGoneAtOnceAreOneStatementAndOneLine() async throws {
        let (signer, _, chain) = try makeSigner()
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2), c = event(3), d = event(4)
        await signer.logWritten(generation: 1, events: [d, c, b, a])
        await signer.logWritten(generation: 2, events: [d])
        let absences = try verify(try XCTUnwrap(file.read()), chain).compactMap(absence)
        XCTAssertEqual(absences.map { $0.records.map(\.id) }, [[a.id, b.id, c.id].sorted { $0.uuidString < $1.uuidString }])
        XCTAssertEqual(lines.written, [Event.signedRecordsGoneKind(count: 3, first: a.startDate, last: c.startDate)])
    }

    /// The line waits while no engine listens, or while the one listening cannot take it, after a relaunch too; it is
    /// written once.
    func testALineTheEngineCouldNotTakeYetIsWrittenOnceItCan() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await signer.logWritten(generation: 2, events: [b])   // no engine listening yet
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.count, 0)
        let relaunched = relaunch(keys)
        let lines = LineWriter(refusing: true)
        await relaunched.writeLines(with: lines.write)
        await relaunched.logWritten(generation: 1, events: [b])
        XCTAssertEqual(lines.written, [], "the engine could not take it")
        lines.refuse(false)
        await relaunched.logWritten(generation: 2, events: [b])
        XCTAssertEqual(lines.written, [Event.signedRecordsGoneKind(count: 1, first: a.startDate, last: a.startDate)])
        await relaunched.logWritten(generation: 3, events: lines.events + [b])   // on disk: noted
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: lines.events + [b])
        XCTAssertEqual(lines.written.count, 1)
        XCTAssertEqual(more.written, [], "noted as written: not again")
    }

    func testAnAbsenceThatCouldNotBeSignedIsSignedAtTheNextWrite() async throws {
        let (signer, keys, chain) = try makeSigner()
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [b])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).count, 0)
        XCTAssertEqual(lines.written, [], "no line before its statement")
        await signer.logWritten(generation: 3, events: [b])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).map { $0.records.map(\.id) }, [[a.id]])
        XCTAssertEqual(lines.written.count, 1)
    }

    /// The store forgets a removal once the signer has accounted for it: at once for a record this phone never signed,
    /// and for a signed one once its retention statement is signed.
    func testTheLimitsRemovalsAreAccountedForOnceRetiredOrNeverSigned() async throws {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let accounted = AccountedRemovals()
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { [signedAt] in signedAt },
                                    retryAfter: 0, removalsAccounted: accounted.handler)
        let before = event(1)   // held at the certification: never signed
        await signer.certifyIfNeeded(records: [before.id])
        let a = event(2), b = event(3)
        await signer.logWritten(generation: 1, events: [b, a, before])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a, before))
        XCTAssertEqual(accounted.all, [before.id], "the record never signed at once; the other waits for its statement")
        await signer.logWritten(generation: 3, events: [b], limitRemoved: removed(a))
        XCTAssertEqual(accounted.all, [before.id, a.id])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(retention).count, 1)
        XCTAssertEqual(checked.compactMap(absence).count, 0)
    }

    /// A record the limit removed before a launch set the log aside went by the limit: retired, not named gone.
    func testARecordTheLimitRemovedIsRetiredEvenWhenTheLogWasNotRead() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await relaunch(keys).logWritten(generation: 1, events: [], limitRemoved: removed(b))
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(retention).count, 1, "b retired")
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[a.id]], "only a, gone with the log, named gone")
    }

    /// The line's words (the owner, 2026-10-31: "wording approved"), its icon, and its copy in iCloud, which another
    /// device reads back; a malformed kind is never read as another line.
    func testTheLineSaysHowManySignedRecordsAndWhen() {
        let first = TestApp.date(2026, 10, 14, 21, 3), last = TestApp.date(2026, 10, 15, 8, 10)
        func when(_ date: Date) -> String {
            "\(date.formatted(.dateTime.month(.abbreviated).day())), \(date.formatted(date: .omitted, time: .shortened))"
        }
        let one = Event.signedRecordsGoneKind(count: 1, first: first, last: first)
        let three = Event.signedRecordsGoneKind(count: 3, first: first, last: last)
        XCTAssertEqual(stateEvent(one).sensorSummary, "A signed record from \(when(first)) is no longer in the log")
        XCTAssertEqual(stateEvent(three).sensorSummary,
                       "3 signed records, from \(when(first)) to \(when(last)), are no longer in the log")
        XCTAssertEqual(stateEvent(Event.signedRecordsGoneKind(count: 2, first: nil, last: nil)).sensorSummary,
                       "2 signed records are no longer in the log", "records whose times could not be written")
        XCTAssertEqual(stateEvent(Event.signedRecordsGoneKind(count: 1, first: nil, last: nil)).sensorSummary,
                       "A signed record is no longer in the log")
        XCTAssertEqual(Event.signedRecordsGone(kind: three)?.count, 3)
        XCTAssertEqual(Event.signedRecordsGone(kind: three)?.first, first)
        XCTAssertEqual(Event.signedRecordsGone(kind: three)?.last, last)
        for bad in [Event.signedRecordsGoneKind(count: 0, first: first, last: first), "signedRecordsGone.3.200.100",
                    "signedRecordsGone.1.100.200", "signedRecordsGone.03.100.200", "signedRecordsGone.3.0100.200",
                    "signedRecordsGone.x", "signedRecordsGone.2.100", "signedRecordsGone.-2", "signedRecordsGone.2.100.200.300"] {
            XCTAssertNil(Event.signedRecordsGone(kind: bad), bad)
            XCTAssertEqual(stateEvent(bad).sensorSummary, "Status entry this version of Malinois does not recognize", bad)
        }
        XCTAssertEqual(EventRow.placeholderIcon(for: three), "exclamationmark.triangle.fill")
        let record = CloudExfiltrator.makeStateRecord(stateEvent(three), kind: three, deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, three, "another device reads it back")
        let malformed = "signedRecordsGone.0.1.1"
        XCTAssertNil(CloudExfiltrator.stateEvent(from: CloudExfiltrator.makeStateRecord(stateEvent(malformed), kind: malformed,
                                                                                          deviceName: "iPhone Air")))
    }

    /// The line stands out in the event log (the owner, 2026-10-31: "could we make those 'no longer in the log' entries
    /// red or somehow otherwise highlight them? Easy to miss as they are"): a red warning sign and red words, in full.
    func testTheLineStandsOutInTheEventLog() {
        let gone = stateEvent(Event.signedRecordsGoneKind(count: 3, first: TestApp.date(2026, 10, 14, 21, 3),
                                                          last: TestApp.date(2026, 10, 15, 8, 10)))
        let other = stateEvent("settingsReset")
        XCTAssertTrue(EventRow.isAlarm(gone))
        XCTAssertFalse(EventRow.isAlarm(other))
        XCTAssertFalse(EventRow.isAlarm(event(1)), "an incident keeps its own look")
        XCTAssertFalse(EventRow.isAlarm(stateEvent("signedRecordsGone.0.1.1")), "a malformed kind is not the line")
        XCTAssertEqual(EventRow.summaryColor(for: gone), .red)
        XCTAssertNil(EventRow.summaryColor(for: other), "other rows keep the secondary style")
        XCTAssertNil(EventRow.summaryLineLimit(for: gone),
                     "the whole sentence at every text size: three lines cut it at the larger ones (item 190, claude-1)")
        XCTAssertEqual(EventRow.summaryLineLimit(for: other), 1)
        XCTAssertEqual(EventRow.placeholderIcon(for: gone.stateChange), "exclamationmark.triangle.fill")
    }

    // MARK: - The limit's removals, as the store keeps them (item 182)

    /// The limit's removals reach the disk before the log that drops them, so a kill between the two cannot make one look
    /// like a record that left another way (as the reports owed do, codex-22).
    func testTheLimitsRemovalsReachTheDiskBeforeTheLogThatDropsThem() throws {
        TestIsolation.setUp(folderPrefix: "Item182Removals")
        defer { TestIsolation.tearDown() }
        let removals = try removalsURL()
        let oldest = statusEvent(0)
        let seen = RemovalsSeenAtLogWrites()
        EventStore.checkpointObserverForTesting = { _, snapshot, _ in
            guard !snapshot.contains(where: { $0.id == oldest.id }) else { return }
            let listed = (try? Data(contentsOf: removals)).flatMap { data in
                EventStore.limitRemovalsKey(create: false).flatMap { EventStore.limitRemovals(in: data, key: $0) }
            } ?? [:]
            seen.note(listed[oldest.id] != nil)
        }
        defer { EventStore.checkpointObserverForTesting = nil }
        let store = EventStore()
        store.add(oldest)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == oldest.id }, "the limit removed the oldest status entry")
        XCTAssertEqual(store.limitRemovals, [oldest.id])
        XCTAssertEqual(seen.all, [true], "on disk before the one log written without it")
    }

    func testTheLimitsRemovalsAreReadBackAtLaunchButNotForRecordsTheLogStillHolds() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsLaunch")
        defer { TestIsolation.tearDown() }
        let held = event(1), removed = event(2), copied = event(3)
        var copy = copied
        copy.sourceDevice = "iPhone Air"
        try writeRemovals([held.id, removed.id, copied.id])
        try JSONEncoder().encode([copy, held]).write(to: try logURL())
        let store = EventStore()
        XCTAssertEqual(store.limitRemovals, [removed.id, copied.id],
                       "a record the log holds was not removed (a kill before the log's write); an iCloud copy is not this phone's own")
        store.drainIOForTesting()
        XCTAssertEqual(try readRemovals(), [removed.id, copied.id])
    }

    func testRemovalsTheSignerAccountedForLeaveTheFile() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsForget")
        defer { TestIsolation.tearDown() }
        let x = UUID(), y = UUID()
        try writeRemovals([x, y])
        let store = EventStore()
        XCTAssertEqual(store.limitRemovals, [x, y], "read back at launch")
        store.forgetLimitRemovals([x])
        store.drainIOForTesting()
        XCTAssertEqual(store.limitRemovals, [y])
        XCTAssertEqual(try readRemovals(), [y])
        store.forgetLimitRemovals([y])
        store.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try removalsURL().path), "none left: the file goes")
    }

    /// A file of removals that cannot be read is set aside, never taken for none and written over.
    func testARemovalsFileThatCannotBeReadIsSetAside() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsDamaged")
        defer { TestIsolation.tearDown() }
        try Data("damaged".utf8).write(to: try removalsURL())
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let store = EventStore()
        XCTAssertEqual(store.limitRemovals, [])
        store.drainIOForTesting()
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("limit-removals") && $0 != EventStore.limitRemovalsFileName }
        XCTAssertEqual(aside.count, 1, "set aside under another name")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(aside.first))), Data("damaged".utf8))
    }

    /// Through the app's own log and signing: the limit's removal is retired and the store forgets it; nothing is declared
    /// gone.
    func testTheAppsSigningRetiresWhatTheLimitRemoves() throws {
        TestIsolation.setUp(folderPrefix: "Item182Signing")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let store = EventStore()
        let signing = EvidenceSigning(store: store, keys: FakeKeyService(chain: chain), center: NotificationCenter())
        let lines = LoggedLines()
        signing.writeLines { kind, _, _ in
            lines.kinds.append(kind)
            return true
        }
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyCertified } == true }, timeout: 5), "certified")
        store.add(statusEvent(0))
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        XCTAssertTrue(pump(until: {
            store.limitRemovals.isEmpty && (try? self.verify(appFile.read() ?? [], chain).contains(where: self.isRetention)) == true
        }, timeout: 20), "the limit's removal retired, and the store told")
        XCTAssertEqual(try verify(try XCTUnwrap(appFile.read()), chain).compactMap(absence).count, 0, "nothing declared gone")
        XCTAssertEqual(lines.kinds, [])
        withExtendedLifetime(signing) {}
    }

    /// Through the app's own log and signing: a log brought back without a signed record (an edited backup, restored) is
    /// read at launch; the record is declared gone, not retired, and the engine writes the line once.
    func testTheAppsSigningDeclaresASignedRecordALogComesBackWithout() throws {
        TestIsolation.setUp(folderPrefix: "Item182SigningBackup")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let signed = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())
        let relaunched = EventStore()
        XCTAssertTrue(relaunched.hasReadTheLog)
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let lines = LoggedLines()
        signing.writeLines { kind, _, _ in
            lines.kinds.append(kind)
            return true
        }
        relaunched.add(event(2))
        XCTAssertTrue(pump(until: { lines.kinds.count == 1 }, timeout: 5), "the engine told")
        XCTAssertEqual(lines.kinds, [Event.signedRecordsGoneKind(count: 1, first: signed.startDate, last: signed.startDate)])
        let checked = try verify(try XCTUnwrap(EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL).read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[signed.id]])
        XCTAssertFalse(checked.contains(where: isRetention), "not retired")
        withExtendedLifetime(signing) {}
    }

    /// The statement names each record gone with the revision last signed.
    func testARecordGoneIsNamedWithItsLastSignedRevision() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var a = event(1)
        let b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        a.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [b, a])   // its revision 2
        await signer.logWritten(generation: 3, events: [b])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).first?.records.map(\.revision), [2])
    }

    /// A removal the store names while the write the signer hears still holds the record, not yet signed (the store's
    /// notices can run after later writes): not accounted, so the store keeps it for the write that drops it, where the
    /// record is retired, never named gone. The app's own test (`testTheAppsSigningRetiresWhatTheLimitRemoves`) found
    /// this when the condition was taken for one that could not decide.
    func testARemovalHeardBeforeTheWriteThatDropsItIsRetiredAtThatWrite() async throws {
        let (signer, accounted, chain) = try accountingSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a], limitRemoved: removed(a))   // a signed in this pass
        XCTAssertEqual(accounted.all, [], "still in this write's log")
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        XCTAssertEqual(accounted.all, [a.id])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(retention).count, 1)
        XCTAssertEqual(checked.compactMap(absence).count, 0)
    }

    /// A record named gone that came back to the log (a restore) and then went by the limit: the signer neither names nor
    /// retires it again, and the store forgets it.
    func testARecordNamedGoneThatCameBackAndWentByTheLimitIsAccountedFor() async throws {
        let (signer, accounted, chain) = try accountingSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await signer.logWritten(generation: 2, events: [b])
        await signer.logWritten(generation: 3, events: [b, a])
        await signer.logWritten(generation: 4, events: [b], limitRemoved: removed(a))
        XCTAssertEqual(accounted.all, [a.id])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).count, 1)
        XCTAssertEqual(checked.compactMap(retention).count, 0)
    }

    /// The line is written once even when the engine is slow to take it and a write comes meanwhile.
    func testALineIsWrittenOnceWhileTheEngineIsSlowToTakeIt() async throws {
        let (signer, _, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        await signer.logWritten(generation: 2, events: [b])   // no engine listening yet
        let lines = HeldLineWriter()
        let first = Task { await signer.writeLines(with: lines.write) }
        try await waitUntil { lines.holding }
        if !lines.holding { lines.release() }   // never asked: a later write must not hang the test on it
        await signer.logWritten(generation: 3, events: [b])
        lines.release()
        await first.value
        XCTAssertEqual(lines.written, [Event.signedRecordsGoneKind(count: 1, first: a.startDate, last: a.startDate)])
    }

    /// A line's note the file refused at the write that held the line is written at the next write, so a relaunch does
    /// not write the line again, even once the line has left the log.
    func testALinesNoteTheFileRefusedIsWrittenAtTheNextWrite() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.logWritten(generation: 2, events: [b])
        XCTAssertEqual(lines.written.count, 1)
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.count, 0, "not on disk yet")
        try setFileWritable(false)
        await signer.logWritten(generation: 3, events: lines.events + [b])
        try setFileWritable(true)
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.count, 0, "refused")
        await signer.logWritten(generation: 4, events: lines.events + [b])
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]])
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        // The line gone since, by the limit.
        await again.logWritten(generation: 1, events: [b], limitRemoved: removed(lines.events))
        XCTAssertEqual(lines.written.count, 1)
        XCTAssertEqual(more.written, [], "noted: not written again")
    }

    /// codex-5 on 73441cbe: a line the engine wrote, its note refused by the file and the app ending before the retry.
    /// The next launch finds the line in the log by the ID made from its statement, and notes it rather than writing it
    /// again.
    func testALineTheLogHoldsAfterARelaunchIsNotedNotWrittenAgain() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let lines = LineWriter()
        let url = file.url
        await signer.writeLines(with: { kind, id, at in
            let written = await lines.write(kind, id, at)
            try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)   // the file refuses the note
            return written
        })
        await signer.logWritten(generation: 2, events: [b])
        try setFileWritable(true)   // the next launch
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: lines.events + [b])   // the journal brought it back
        XCTAssertEqual(lines.written.count, 1)
        XCTAssertEqual(more.written, [], "not written again")
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]], "noted")
    }

    /// codex-5 on 73441cbe: a line the engine took that never reached the log on disk (its journal write failed and the
    /// app ended before the log's write): not noted, so the next launch writes it again, under the same ID.
    func testALineTheLogNeverHeldIsWrittenAgainUnderTheSameID() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.logWritten(generation: 2, events: [b])
        await signer.logWritten(generation: 3, events: [b])   // a later write, without the line
        XCTAssertEqual(lines.written.count, 1, "not written twice in one launch")
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.count, 0, "not noted: no write on disk held it")
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: [b])
        XCTAssertEqual(more.written, lines.written, "written again")
        XCTAssertEqual(more.ids, lines.ids, "under the same ID")
        await again.logWritten(generation: 2, events: more.events + [b])
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]], "noted once a write held it")
    }

    /// The limit removing an iCloud copy lists nothing: only this phone's own records are signed.
    func testTheLimitRemovingAnICloudCopyListsNothing() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsCopy")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        var copy = statusEvent(0)
        copy.sourceDevice = "iPhone Air"
        store.add(copy)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        XCTAssertFalse(store.events.contains { $0.id == copy.id }, "the copy went first")
        XCTAssertEqual(store.limitRemovals, [])
    }

    /// A launch before the first unlock leaves the removals' file alone (it cannot be read yet: taken for damaged, it would
    /// be set aside), and the unlock reads it.
    func testASealedLaunchLeavesTheRemovalsAloneAndTheUnlockReadsThem() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsSealed")
        defer { TestIsolation.tearDown() }
        let removed = UUID()
        let removals = try removalsURL()
        try writeRemovals([removed])
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: removals.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: removals.path) }
        let log = try logURL()
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
        let store = EventStore(protectedDataAvailable: { false })
        XCTAssertFalse(store.acceptsWrites, "waiting for the unlock")
        XCTAssertTrue(FileManager.default.fileExists(atPath: removals.path), "not set aside while the phone is sealed")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: removals.path)
        try FileManager.default.removeItem(at: log)
        try JSONEncoder().encode([Event]()).write(to: log)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.acceptsWrites }, timeout: 5), "read at the unlock")
        XCTAssertEqual(store.limitRemovals, [removed])
    }

    func testTheLaunchWritesTheSignersLinesThroughTheEngine() {
        TestIsolation.setUp(folderPrefix: "Item182SigningLaunch")
        defer { TestIsolation.tearDown() }
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        XCTAssertTrue(services.evidenceSigning.writesLines, "the engine writes the signer's lines in the event log")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    // MARK: - The keys this install certified, kept where a backup cannot change them (item 190's A3, the owner's "a")

    /// DeepSeek's deepseek-1 on aa71756: a backup edited to take the key's certification out of the signature file,
    /// restored to the same iPhone, made the phone certify a new key that followed none, with nothing said. The
    /// Keychain's list, which no edit of a backup reaches, still names the key: the next key follows it, so every later
    /// bundle says an earlier key's signatures are not there, and the event log says so, once, since the log holds
    /// records from before the restore.
    func testAKeyTheFileLostIsFollowedFromTheKeychainsListAndTheLogSaysSoOnce() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        XCTAssertEqual(list.current.certified, [first], "the list names the key once Apple has certified it")
        // The edited backup, restored: App Attest no longer has the key, and the file no longer names it.
        await keys.lose(first.base64EncodedString())
        try rewrite(try XCTUnwrap(file.read()).filter { $0.kind == .signature })
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(try keyStatements().last?.follows, first, "the new key follows the key the file lost")
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
        XCTAssertEqual(list.current.certified.count, 2, "and the list names the new key too")
        // The log holds the line: noted, and never said again, at this launch or the next.
        await restored.logWritten(generation: 2, events: lines.events + [a])
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.count, 1)
        let again = relaunch(keys, keyList: list)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: lines.events + [a])
        XCTAssertEqual(more.written, [], "said once")
    }

    /// The whole file gone with the log kept is the same edit: the next key follows the list's last, and the log says so.
    func testASignatureFileGoneWithTheLogKeptIsSaidAndFollowed() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(try keyStatements().last?.follows, first)
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// A reinstall takes the app's files, the log and the signature file with them, and leaves the Keychain: the next key
    /// follows the last the list names, so bundles still say an earlier key's signatures are not there, and the log,
    /// holding nothing from before the reinstall, says nothing, then or at a later launch.
    func testAReinstallsKeyFollowsTheListsLastAndItsEmptyLogSaysNothing() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        await signer.logWritten(generation: 1, events: [event(1)])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let reinstalled = relaunch(keys, keyList: list)
        await reinstalled.writeLines(with: lines.write)
        await reinstalled.heardTheLogRead([])
        await reinstalled.certifyIfNeeded(records: [])
        await reinstalled.logWritten(generation: 1, events: [])
        let after = signedAt.addingTimeInterval(600)
        let fresh = Event(startDate: after, endDate: after.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [1])
        await reinstalled.logWritten(generation: 2, events: [fresh])
        XCTAssertEqual(try keyStatements().last?.follows, first)
        XCTAssertEqual(lines.written, [])
        let next = relaunch(keys, keyList: list, at: after.addingTimeInterval(3_600))
        let later = LineWriter()
        await next.writeLines(with: later.write)
        await next.logWritten(generation: 1, events: [fresh])
        XCTAssertEqual(later.written, [], "a record of the reinstalled app's own is no lost history")
    }

    /// The line owed is kept in the file until written: a relaunch before any engine took it writes it then, once.
    func testAMissingSignaturesLineOwedIsWrittenAfterARelaunch() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try rewrite(try XCTUnwrap(file.read()).filter { $0.kind == .signature })
        let restored = relaunch(keys, keyList: list)   // no engine listening yet
        await restored.heardTheLogRead([a.id])
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(file.read()?.filter { $0.kind == .historyMissing }.count, 1, "owed, in the file")
        let lines = LineWriter()
        let next = relaunch(keys, keyList: list)
        await next.writeLines(with: lines.write)
        await next.logWritten(generation: 1, events: [a])
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The line takes its place in the log by its time when a copy of the log brings it, as the absence line does
    /// (`EventStore.merged`), never first as a new row does.
    func testTheMissingSignaturesLineTakesItsPlaceByItsTime() {
        let newer = statusEvent(3), older = statusEvent(1)
        let at = older.startDate.addingTimeInterval(30)
        let line = Event(id: UUID(), startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signaturesMissingKind)
        XCTAssertEqual(EventStore.merged(local: [newer, older], incoming: [line]).map(\.id), [newer.id, line.id, older.id])
    }

    /// A certification the app did not live to add to the list (stopped between the file and the Keychain) is added from
    /// the file at the next launch, so the list never lags the file.
    func testTheListTakesAKeyTheFileNamesAndItLacks() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        list.set(EvidenceKeyList())
        let lines = LineWriter()
        let relaunched = relaunch(keys, keyList: list)
        await relaunched.writeLines(with: lines.write)
        await relaunched.logWritten(generation: 1, events: [event(1)])
        XCTAssertEqual(list.current.certified, [first])
        XCTAssertEqual(lines.written, [], "nothing lost")
    }

    /// The list is the Keychain's, for this device only and readable after the first unlock, never synced: no backup
    /// restores it onto another iPhone, and none hands it to whoever edits the backup.
    func testTheKeychainKeepsTheListForThisDeviceOnly() throws {
        let store = KeychainEvidenceKeyList()
        KeychainService.deleteEvidenceKeyListForTesting()
        defer { KeychainService.deleteEvidenceKeyListForTesting() }
        XCTAssertEqual(store.read(), EvidenceKeyList(), "none yet")
        let list = EvidenceKeyList(certified: [Data(repeating: 0xA1, count: 32), Data(repeating: 0xB2, count: 32)],
                                   accounted: [Data(repeating: 0xA1, count: 32)])
        XCTAssertTrue(store.write(list))
        XCTAssertEqual(store.read(), list)
        let kept = try XCTUnwrap(KeychainService.evidenceKeyListKeptForTesting())
        XCTAssertEqual(kept.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(kept.synchronizable)
    }

    /// The app's signer keeps its list in the Keychain; a test's, in a stand-in of its own.
    func testTheAppsSignerKeepsItsListInTheKeychain() async {
        XCTAssertTrue(EvidenceSigning.defaultKeyList(forTesting: nil) is KeychainEvidenceKeyList)
        TestIsolation.setUp(folderPrefix: "Item190KeyList")
        defer { TestIsolation.tearDown() }
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        let kept = await services.evidenceSigning.signer.keyListForTesting
        XCTAssertNotNil(kept, "the signer has its list")
        XCTAssertFalse(kept is KeychainEvidenceKeyList, "a test's stand-in, never the Keychain the next test shares")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    // MARK: - Codex's change review of 73441cbe (item 182; the owner, 2026-10-31: "1 - a, 2 - a, go on the fixes")

    /// codex-1: a backup restored with a signed record taken out of the log and its ID added to the removals' file, as a
    /// list of IDs: the list does not vouch for itself, so the record is named gone, never retired.
    func testAnEditedBackupsRemovalsListDoesNotMakeARecordGoneLookRetired() throws {
        TestIsolation.setUp(folderPrefix: "Item182EditedRemovals")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let signed = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())
        try JSONEncoder().encode([signed.id]).write(to: try removalsURL())   // the edit
        let relaunched = EventStore()
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        relaunched.add(event(2))
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: {
            (try? self.verify(appFile.read() ?? [], chain).contains { self.absence($0) != nil || self.isRetention($0) }) == true
        }, timeout: 5), "accounted for")
        let checked = try verify(try XCTUnwrap(appFile.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[signed.id]], "named gone")
        XCTAssertFalse(checked.contains(where: isRetention), "never retired")
        withExtendedLifetime(signing) {}
    }

    /// codex-3: a removal on disk from an earlier launch, and a record the journal holds that the log does not (the app
    /// ended before the log's write). The journal's recovery writes the log at launch; the removals' file still names
    /// the removal after it, for this launch and the next.
    func testTheJournalsRecoveryAtLaunchKeepsTheRemovalsOnDisk() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsRecovery")
        defer { TestIsolation.tearDown() }
        let removed = try removeOneByTheLimitAndSettle()
        let later = event(1)
        try journal(later)
        let relaunched = EventStore()
        relaunched.drainIOForTesting()
        XCTAssertTrue(relaunched.events.contains { $0.id == later.id }, "recovered from the journal")
        XCTAssertEqual(relaunched.limitRemovals, [removed])
        XCTAssertEqual(EventStore().limitRemovals, [removed], "still on disk for the launch after")
    }

    /// codex-3, at the unlock: a launch before the first unlock, then the unlock's reload, whose recovery writes the log.
    func testTheJournalsRecoveryAtTheUnlockKeepsTheRemovalsOnDisk() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsRecoveryUnlock")
        defer { TestIsolation.tearDown() }
        let removed = try removeOneByTheLimitAndSettle()
        let later = event(1)
        try journal(later)
        let log = try logURL()
        let saved = try Data(contentsOf: log)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)   // unreadable, as when sealed
        let store = EventStore(protectedDataAvailable: { false })
        XCTAssertFalse(store.acceptsWrites, "waiting for the unlock")
        try FileManager.default.removeItem(at: log)
        try saved.write(to: log)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.acceptsWrites }, timeout: 5), "read at the unlock")
        store.drainIOForTesting()
        XCTAssertTrue(store.events.contains { $0.id == later.id }, "recovered from the journal")
        XCTAssertEqual(store.limitRemovals, [removed])
        XCTAssertEqual(EventStore().limitRemovals, [removed], "still on disk for the launch after")
    }

    /// codex-4: a retention statement kept while the file could not be written again without the retired signatures (a
    /// full disk). After a relaunch the record stays retired, never named gone, though the store has forgotten it, and
    /// its signature leaves the file at the relaunch's first write.
    func testARetiredRecordWhoseSignatureStayedInTheFileIsNotNamedGoneAfterARelaunch() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        try setFolderWritable(false)   // the file can be added to, not written again
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        try setFolderWritable(true)
        XCTAssertTrue(file.read()?.contains { $0.record == a.id } == true, "its signature stayed in the file")
        let relaunched = relaunch(keys)
        let lines = LineWriter()
        await relaunched.writeLines(with: lines.write)
        await relaunched.logWritten(generation: 1, events: [b])   // the store forgot it
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).count, 0, "not named gone")
        XCTAssertEqual(checked.compactMap(retention).count, 1, "retired once")
        XCTAssertEqual(lines.written, [])
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.record == a.id }, "its signature left the file")
    }

    /// codex-4, within one launch: the retired signatures the file kept leave it at the next write.
    func testRetiredSignaturesTheFileKeptLeaveItAtTheNextWrite() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        try setFolderWritable(false)
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        try setFolderWritable(true)
        await signer.logWritten(generation: 3, events: [b])
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.record == a.id }, "its signature left the file")
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).count, 0)
    }

    /// codex-5, through the app's own log and signing: the line, written into the log under its ID as the engine writes
    /// it (once the engine can take it), is noted once the log on disk holds it, and the next launch does not write it
    /// again.
    func testTheAppsLineIsNotedOnceTheLogOnDiskHoldsIt() throws {
        TestIsolation.setUp(folderPrefix: "Item182SigningLine")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        _ = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())
        let relaunched = EventStore()
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let asked = LoggedLines()
        signing.writeLines { kind, id, at in
            asked.kinds.append(kind)
            guard asked.kinds.count > 1 else { return false }   // the engine could not take the first
            relaunched.add(lineEvent(kind, id, at: at))   // as the engine's `logStateChange` writes it
            return true
        }
        // Asked at launch: the store hands the signer the log as read (item 182, codex-3 on 68bd96b3).
        XCTAssertTrue(pump(until: { asked.kinds.count == 1 }, timeout: 5), "asked once")
        relaunched.add(event(4))   // the next write asks again
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .absenceLogged } == true }, timeout: 5), "noted")
        XCTAssertEqual(relaunched.events.filter { Event.signedRecordsGone(kind: $0.stateChange ?? "") != nil }.count, 1)
        relaunched.drainIOForTesting()
        let third = EventStore()
        let again = EvidenceSigning(store: third, keys: keys, center: NotificationCenter())
        let more = LoggedLines()
        again.writeLines { kind, _, _ in
            more.kinds.append(kind)
            return true
        }
        let next = event(3)
        third.add(next)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.record == next.id } == true }, timeout: 5), "a write heard")
        XCTAssertEqual(more.kinds, [], "not written again")
        withExtendedLifetime((signing, again)) {}
    }

    /// codex-1: a removals' file whose check does not hold (an ID added to a file the store wrote, or a file made with
    /// another phone's key) is set aside, never read as removals.
    func testARemovalsFileWhoseCheckDoesNotHoldIsSetAside() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsUnchecked")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let kept = UUID(), added = UUID()
        try writeRemovals([kept])
        let written = try Data(contentsOf: try removalsURL())
        let edited = try XCTUnwrap(String(data: written, encoding: .utf8)).replacingOccurrences(
            of: "{\"id\":\"\(kept.uuidString)\"", with: "{\"id\":\"\(added.uuidString)\"},{\"id\":\"\(kept.uuidString)\"")
        XCTAssertNotEqual(edited, String(data: written, encoding: .utf8), "an ID added")
        let otherKey = try EventStore.limitRemovalsData([kept: RecordIdentity(start: nil, kind: nil)], key: SymmetricKey(size: .bits256))
        for file in [Data(edited.utf8), otherKey] {
            for name in try asideRemovals(in: root) { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
            try file.write(to: try removalsURL())
            XCTAssertEqual(EventStore().limitRemovals, [], "not read as removals")
            XCTAssertFalse(FileManager.default.fileExists(atPath: try removalsURL().path), "set aside")
            XCTAssertEqual(try asideRemovals(in: root).count, 1, "kept aside under another name")
        }
    }

    /// codex-1 on eaac8b96 (the owner's "a"): the removals' check covers what each removed row was: a file whose row's
    /// kind or start was changed (an edited backup) is set aside, never read as removals.
    func testTheRemovalsCheckCoversWhatEachRemovedRowWas() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsIdentityChecked")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let key = try XCTUnwrap(EventStore.limitRemovalsKey(create: true))
        let written = try XCTUnwrap(String(data: try EventStore.limitRemovalsData(
            [UUID(): RecordIdentity(start: 1_793_000_000_000, kind: "settingsReset", interrupted: true)], key: key),
                                           encoding: .utf8))
        for edit in [("settingsReset", "armed"), ("1793000000000", "1793000000001"),
                     ("\"interrupted\":true", "\"interrupted\":false")] {
            let edited = written.replacingOccurrences(of: edit.0, with: edit.1)
            XCTAssertNotEqual(edited, written, "\(edit.0) changed")
            try Data(edited.utf8).write(to: try removalsURL())
            for name in try asideRemovals(in: root) { try FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
            XCTAssertEqual(EventStore().limitRemovals, [], "\(edit.0) changed: not read as removals")
            XCTAssertEqual(try asideRemovals(in: root).count, 1, "\(edit.0) changed: set aside")
        }
    }

    /// The clock on 92bf0605 (the owner's "a"): a new row goes first and the limit keeps it, whatever its time: with the
    /// phone's clock set back before every status entry of a full log, the new entry (a disarm, say) is kept, first, and
    /// the limit takes the log's last entry.
    func testANewRowIsKeptWhateverItsTime() throws {
        TestIsolation.setUp(folderPrefix: "Item182ClockSetBack")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        for entry in entries { store.add(entry) }
        let early = TestApp.date(2026, 10, 30, 23, 0)   // the clock set back before every entry above
        let entry = Event(startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "settingsReset")
        store.add(entry)
        XCTAssertEqual(store.events.first?.id, entry.id, "kept, first")
        XCTAssertEqual(store.limitRemovals, [entries[0].id], "the log's last entry taken")
        store.drainIOForTesting()
    }

    /// The clock on 92bf0605 (the owner's "a"): the same for an incident in a full log of incidents, whose photo or clip
    /// would have been lost with it.
    func testANewIncidentIsKeptWhateverItsTime() throws {
        TestIsolation.setUp(folderPrefix: "Item182ClockIncident")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let incidents = (1...EventStore.maxIncidentEvents).map { minute -> Event in
            let start = TestApp.date(2026, 10, 31, 1, 0).addingTimeInterval(TimeInterval(minute * 60))
            return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion])
        }
        try JSONEncoder().encode(incidents.reversed()).write(to: try logURL())
        let store = EventStore()
        XCTAssertEqual(store.events.count, EventStore.maxIncidentEvents, "at the limit: nothing removed at launch")
        let early = TestApp.date(2026, 10, 30, 23, 0)   // the clock set back before every incident above
        let incident = Event(startDate: early, endDate: early.addingTimeInterval(5), triggeredSensors: [.motion])
        store.add(incident)
        XCTAssertEqual(store.events.first?.id, incident.id, "kept, first")
        XCTAssertEqual(store.limitRemovals, [incidents[0].id], "the log's last incident taken")
        store.drainIOForTesting()
    }

    /// codex-1 on 92bf0605 (the owner's "a"): the rows an add's limit removes have their journal lines retired with that
    /// add's write, as the journal's recovery and the load do: here the log's oldest entry, whose line the journal still
    /// held (a kill before the checkpoint that retires it).
    func testAnAddsLimitRetiresTheJournalLinesOfTheRowsItRemoves() throws {
        TestIsolation.setUp(folderPrefix: "Item182AddRetiresLines")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: entries[0])).write(to: journal)
        let store = EventStore()
        store.add(statusEvent(EventStore.maxAuditEvents + 1))
        XCTAssertEqual(store.limitRemovals, [entries[0].id], "the limit took the oldest")
        store.drainIOForTesting()
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == entries[0].id } } ?? false
        }
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "its journal line retired")
    }

    /// codex-1 on 92bf0605 (the owner's "a"): the row an add puts in is never the one its own limit takes: the signer's
    /// line at its statement's time, older than every status entry of a full log and not yet held, stays, and the limit
    /// takes no newer entry in its place.
    func testTheRowAnAddPutsInIsNeverTheOneItsLimitTakes() throws {
        TestIsolation.setUp(folderPrefix: "Item182AddSpares")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        for entry in entries { store.add(entry) }
        let early = TestApp.date(2026, 10, 30, 23, 0)
        let line = Event(id: UUID(), startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        store.add(line, placedByItsTime: true)   // not held yet
        XCTAssertTrue(store.events.contains { $0.id == line.id }, "kept by its own add")
        XCTAssertEqual(store.limitRemovals, [], "no newer entry taken in its place")
        store.drainIOForTesting()
    }

    /// codex-1: without this phone's key (a restore onto another iPhone), the removals' file cannot be checked: set aside.
    func testWithoutThePhonesKeyTheRemovalsFileIsSetAside() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsNoKey")
        defer { TestIsolation.tearDown() }
        try writeRemovals([UUID()])
        EventStore.limitRemovalsKeyForTesting = { _ in nil }
        defer { EventStore.limitRemovalsKeyForTesting = nil }
        XCTAssertEqual(EventStore().limitRemovals, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try removalsURL().path), "set aside")
    }

    /// codex-1: the store writes the removals checked with this phone's key, the next launch reads them, and the key is
    /// kept for this device only, readable after the first unlock, never synced.
    func testTheRemovalsAreWrittenCheckedWithAKeyKeptForThisDeviceOnly() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsKey")
        defer { TestIsolation.tearDown() }
        KeychainService.deleteLimitRemovalsKeyForTesting()   // made afresh by the store's first write
        let store = EventStore()
        let oldest = statusEvent(0)
        store.add(oldest)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        store.drainIOForTesting()
        XCTAssertEqual(try readRemovals(), [oldest.id], "checked with the phone's key")
        XCTAssertEqual(EventStore().limitRemovals, [oldest.id], "read back")
        let kept = try XCTUnwrap(KeychainService.limitRemovalsKeyKeptForTesting())
        XCTAssertEqual(kept.accessible, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        XCTAssertFalse(kept.synchronizable)
    }

    /// codex-3, at the unlock: a removal whose record the log holds (a kill before the log's write) is no removal, after
    /// the recovery as at launch.
    func testTheUnlockDropsRemovalsWhoseRecordsTheLogHolds() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsUnlockHeld")
        defer { TestIsolation.tearDown() }
        let held = event(1)
        let removed = UUID()
        try writeRemovals([held.id, removed])
        let log = try logURL()
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)   // unreadable, as when sealed
        let store = EventStore(protectedDataAvailable: { false })
        XCTAssertFalse(store.acceptsWrites, "waiting for the unlock")
        try FileManager.default.removeItem(at: log)
        try JSONEncoder().encode([held]).write(to: log)
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.acceptsWrites }, timeout: 5), "read at the unlock")
        XCTAssertEqual(store.limitRemovals, [removed])
        store.drainIOForTesting()
        XCTAssertEqual(try readRemovals(), [removed], "and on disk")
    }

    /// codex-1: without the phone's key the removals are not written (they could not be checked), and the log is
    /// written all the same.
    func testWithoutAKeyTheRemovalsAreNotWrittenAndTheLogIs() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsNoKeyWrite")
        defer { TestIsolation.tearDown() }
        EventStore.limitRemovalsKeyForTesting = { _ in nil }
        defer { EventStore.limitRemovalsKeyForTesting = nil }
        let store = EventStore()
        let oldest = statusEvent(0)
        store.add(oldest)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        store.drainIOForTesting()
        XCTAssertEqual(store.limitRemovals, [oldest.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try removalsURL().path), "not written")
        let logged = try JSONDecoder().decode([Event].self, from: Data(contentsOf: try logURL()))
        XCTAssertEqual(logged.count, EventStore.maxAuditEvents)
        XCTAssertFalse(logged.contains { $0.id == oldest.id }, "the log written without it")
    }

    /// codex-4: a record retired whose signature a failed rewrite kept, then back in the log and signed again: after a
    /// relaunch it is not taken for retired, so its leaving again is named.
    func testARecordSignedAgainAfterItsRetirementIsNotTakenForRetired() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        try setFolderWritable(false)   // the file can be added to, not written again
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        await signer.logWritten(generation: 3, events: [b, a])   // back, and signed again
        try setFolderWritable(true)
        XCTAssertEqual(file.read()?.filter { $0.record == a.id }.count, 2, "its retired signature and its new one")
        await relaunch(keys).logWritten(generation: 1, events: [b])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[a.id]], "named gone")
    }

    // MARK: - Codex's change review of 417158fe (item 182; the owner, 2026-11-01: "go on the fixes, codex-1 b")

    /// Claude's finding on 417158fe: a signature counts for the record its signed statement names, never for the entry's
    /// unsigned label, so relabelling a deleted incident's signatures as another record's hides nothing, and the limit
    /// removing that other record later does not retire them.
    func testASignatureRelabelledInTheFileStillCountsForTheRecordItSigned() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), x = event(2)
        await signer.logWritten(generation: 1, events: [x, a])
        // An edited backup: x taken out of the log, its signatures labelled as a's.
        let entries = try XCTUnwrap(file.read())
        try FileManager.default.removeItem(at: file.url)
        for var entry in entries {
            if entry.record == x.id { entry.record = a.id }
            XCTAssertTrue(file.append(entry))
        }
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [a])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).map { $0.records.map(\.id) }, [[x.id]],
                       "named gone")
        await relaunched.logWritten(generation: 2, events: [], limitRemoved: removed(a))   // the limit removes a
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        let retired = checked.compactMap(retention).flatMap { $0.retired.flatMap(\.counters) }
        let counters = checked.filter { recordID($0) == x.id }.map(\.counter)
        XCTAssertFalse(counters.isEmpty, "x's signatures kept")
        XCTAssertFalse(counters.contains { counter in retired.contains { $0.contains(counter) } }, "none retired with a's")
    }

    /// codex-3 on 417158fe: the cleanup after a retirement whose rewrite failed drops exactly the retired signatures:
    /// a record back in the log and signed again keeps its new signature, and no counter goes missing.
    func testTheCleanupAfterARetirementKeepsASignatureMadeSince() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        try setFolderWritable(false)   // the file can be added to, not written again
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        await signer.logWritten(generation: 3, events: [b, a])   // back, and signed again
        try setFolderWritable(true)
        await signer.logWritten(generation: 4, events: [b, a])   // the cleanup runs
        let c = event(3)
        await signer.logWritten(generation: 5, events: [c, b, a])   // a later signature, so a gap would show
        let entries = try XCTUnwrap(file.read())
        XCTAssertEqual(entries.filter { $0.record == a.id }.count, 1, "the new signature kept, the retired one gone")
        let checked = try verify(entries, chain)
        let keyID = try XCTUnwrap(checked.first?.keyID)
        XCTAssertEqual(EvidenceVerifier.sequence(of: checked, keyID: keyID, followers: []).missing, [], "no counter missing")
    }

    /// codex-4 on 417158fe: the signer's line written again after the line itself was lost here, its iCloud copy back in
    /// the log: this phone's own line takes the copy's place, a later pull from iCloud keeps it, and it is not written
    /// twice.
    func testALineWrittenAgainTakesThePlaceOfItsICloudCopy() throws {
        TestIsolation.setUp(folderPrefix: "Item182LineCopy")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }   // no account: nothing waits on CloudKit
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let id = UUID()
        let kind = Event.signedRecordsGoneKind(count: 1, first: nil, last: nil)
        var copy = lineEvent(kind, id)
        copy.sourceDevice = "iPhone Air"   // this phone's own line, lost here, back from iCloud as a copy
        store.mergeFromCloud([copy])
        engine.logSignerLine(kind, id: id, at: TestApp.date(2026, 10, 31, 3, 0))
        XCTAssertEqual(store.events.filter { $0.id == id }.map(\.isMirrored), [false], "one line, this phone's own")
        var other = lineEvent("settingsReset", UUID())
        other.sourceDevice = "iPhone Air"
        store.mergeFromCloud([other])
        XCTAssertEqual(store.events.filter { $0.id == id }.map(\.isMirrored), [false], "kept at the next pull")
        engine.logSignerLine(kind, id: id, at: TestApp.date(2026, 10, 31, 3, 0))
        XCTAssertEqual(store.events.filter { $0.id == id }.count, 1, "not written twice")
    }

    /// codex-5 on 417158fe: a line the log on disk held, its note refused until the limit removed the line: the limit's
    /// removal shows the log held it, so it is noted then, and the next launch does not write it again.
    func testALineTheLimitRemovedBeforeItsNoteIsNotedNotWrittenAgain() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.logWritten(generation: 2, events: [b])   // the line handed over
        try setFileWritable(false)
        await signer.logWritten(generation: 3, events: lines.events + [b])   // held; its note refused
        try setFileWritable(true)
        await signer.logWritten(generation: 4, events: [b], limitRemoved: removed(lines.events))
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]], "noted")
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: [b])
        XCTAssertEqual(more.written, [], "not written again")
    }

    /// codex-5 on 417158fe: while a line's note is owed, the store is not told it may forget the limit's removal of the
    /// line, so the next launch still has the proof and notes the line rather than writing it again.
    func testTheLimitsRemovalOfALineIsKeptUntilItsNoteIsWritten() async throws {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let accounted = AccountedRemovals()
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { [signedAt] in signedAt },
                                    retryAfter: 0, removalsAccounted: accounted.handler)
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.logWritten(generation: 2, events: [b])   // the line handed over
        try setFileWritable(false)
        await signer.logWritten(generation: 3, events: [b], limitRemoved: removed(lines.events))   // note refused
        try setFileWritable(true)
        XCTAssertEqual(accounted.all, [], "the removal kept while the note is owed")
        let again = relaunch(keys)
        let more = LineWriter()
        await again.writeLines(with: more.write)
        await again.logWritten(generation: 1, events: [b], limitRemoved: removed(lines.events))
        XCTAssertEqual(more.written, [], "not written again")
        XCTAssertEqual(file.read()?.filter { $0.kind == .absenceLogged }.map(\.records), [[a.id]], "noted")
    }

    // MARK: - Codex's change review of ba2e282e (item 182; the owner, 2026-11-01: "go on the fixes, codex-3 a")

    /// codex-1: a record's genuine statement put in another signature's entry, that signature kept (an edited backup):
    /// the phone checks each signature in its file against its key before acting on it, so the entry counts for no
    /// record, stays in the file, and the limit's later removal of that record does not retire its counter.
    func testAStatementPutInAnotherSignaturesEntryCountsForNothing() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), x = event(2), b = event(3)
        await signer.logWritten(generation: 1, events: [b, x, a])
        let entries = try XCTUnwrap(file.read())
        let xCounter = try XCTUnwrap(try verify(entries, chain).first { recordID($0) == x.id }?.counter)
        let aStatement = try XCTUnwrap(entries.first { $0.record == a.id }?.statement)
        let xAssertion = try XCTUnwrap(entries.first { $0.record == x.id }?.assertion)
        // An edited backup: x taken out of the log, its entry given a's statement and label, x's signature kept.
        try FileManager.default.removeItem(at: file.url)
        for var entry in entries {
            if entry.record == x.id {
                entry.statement = aStatement
                entry.record = a.id
            }
            XCTAssertTrue(file.append(entry))
        }
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, a])
        await relaunched.logWritten(generation: 2, events: [b], limitRemoved: removed(a))   // the limit removes a
        let after = try XCTUnwrap(file.read())
        XCTAssertTrue(after.contains { $0.assertion == xAssertion }, "the entry that does not hold stays in the file")
        let retired = try holding(after, chain).compactMap(retention).flatMap { $0.retired.flatMap(\.counters) }
        XCTAssertFalse(retired.isEmpty, "a's own signature retired")
        XCTAssertFalse(retired.contains { $0.contains(xCounter) }, "x's counter not retired with it")
    }

    /// codex-2: a record retired while the rewrite failed, then back and signed again, and the app relaunched before the
    /// cleanup: the relaunch queues the retired signature for cleanup and keeps the new one, so an export shows the
    /// record's one live revision.
    func testARetiredSignatureOfARecordSignedAgainIsCleanedUpAfterARelaunch() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        try setFolderWritable(false)   // the file can be added to, not written again
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(a))
        await signer.logWritten(generation: 3, events: [b, a])   // back, and signed again
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, a])   // the log compared, the cleanup failing again
        try setFolderWritable(true)
        let snapshot = await relaunched.export(of: a.id, showing: [a.id])
        XCTAssertEqual(snapshot?.entries.filter { $0.record == a.id }.count, 1, "the export holds the live signature only")
        XCTAssertEqual(file.read()?.filter { $0.record == a.id }.count, 1, "the retired one left the file")
    }

    /// codex-3 (the owner's "a"): a line the signer still owes its note is held from the limit, as a record whose upload
    /// is running is; let go, it goes by the limit like any other status entry.
    func testTheLimitTakesNoLineTheSignerStillOwes() throws {
        TestIsolation.setUp(folderPrefix: "Item182LineHeld")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let early = TestApp.date(2026, 10, 30, 23, 0)   // older than every status entry below
        let line = Event(id: UUID(), startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        store.holdLinesForTheSigner([line.id])
        store.add(line)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        XCTAssertTrue(store.events.contains { $0.id == line.id }, "held while its note is owed")
        store.holdLinesForTheSigner([])
        XCTAssertFalse(store.events.contains { $0.id == line.id }, "let go: the limit takes it")
        XCTAssertTrue(store.limitRemovals.contains(line.id))
    }

    /// codex-2 on c2202a26 (the owner's "a"): a line the signer writes at its statement's time, older than every status
    /// entry the log holds, takes its place by that time: held, it takes no newer entry's place in the limit; let go, it
    /// is the oldest, and the limit takes it.
    func testALateLineTakesNoNewerStatusEntrysPlace() throws {
        TestIsolation.setUp(folderPrefix: "Item182LateLine")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        for entry in entries { store.add(entry) }
        let early = TestApp.date(2026, 10, 30, 23, 0)   // older than every status entry above
        let line = Event(id: UUID(), startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        store.holdLinesForTheSigner([line.id])
        store.add(line, placedByItsTime: true)
        XCTAssertEqual(store.limitRemovals, [], "no newer status entry taken while the line is held")
        XCTAssertTrue(entries.allSatisfy { entry in store.events.contains { $0.id == entry.id } })
        store.holdLinesForTheSigner([])
        XCTAssertEqual(store.limitRemovals, [line.id], "let go: the oldest, the limit takes it")
        store.drainIOForTesting()
    }

    /// The clock on 92bf0605 (the owner's "a"): a new row goes first in the log whatever its time, as before the ninth
    /// round; only the signer's line, at its statement's time, takes its place by that time: below every row newer than
    /// it, though an older row stands first.
    func testANewRowGoesFirstAndOnlyTheSignersLineTakesItsPlaceByItsTime() throws {
        TestIsolation.setUp(folderPrefix: "Item182RowFirst")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let entries = (1...3).map { statusEvent($0) }
        for entry in entries { store.add(entry) }
        let earlier = entries[0].startDate.addingTimeInterval(20)
        let older = Event(startDate: earlier, endDate: earlier, triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "settingsReset")
        store.add(older)   // the clock set back
        let at = entries[0].startDate.addingTimeInterval(30)
        let line = Event(id: UUID(), startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        store.add(line, placedByItsTime: true)
        XCTAssertEqual(store.events.map(\.id), [older.id, entries[2].id, entries[1].id, line.id, entries[0].id])
        store.drainIOForTesting()
    }

    /// codex-3: the signer hands the store its owed lines to hold, after it reads its file and after each change, and
    /// lets each go once noted.
    func testTheSignerHandsTheStoreItsOwedLinesToHold() async throws {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let held = HeldLines()
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { [signedAt] in signedAt },
                                    retryAfter: 0, linesOwedChanged: held.handler)
        await signer.certifyIfNeeded(records: [])
        let a = event(1), b = event(2)
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        await signer.logWritten(generation: 1, events: [b, a])
        await signer.logWritten(generation: 2, events: [b])   // a named gone: its line owed
        XCTAssertEqual(held.last, Set(lines.ids), "the owed line held")
        let again = HeldLines()
        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)",
                                        now: { [signedAt] in signedAt }, retryAfter: 0, linesOwedChanged: again.handler)
        await relaunched.logWritten(generation: 1, events: [b])
        XCTAssertEqual(again.last, Set(lines.ids), "held again after a relaunch, once the file is read")
        await relaunched.logWritten(generation: 2, events: lines.events + [b])   // noted
        XCTAssertEqual(again.last, [], "let go once noted")
    }

    /// codex-3, through the app's own log and signing: an owed line is held in the store.
    func testTheAppsSigningHoldsAnOwedLineFromTheLimit() throws {
        TestIsolation.setUp(folderPrefix: "Item182SigningHold")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        _ = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())
        let relaunched = EventStore()
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        signing.writeLines { _, _, _ in false }   // an engine that cannot take the line: it stays owed
        relaunched.add(event(2))
        XCTAssertTrue(pump(until: { relaunched.linesHeldForTheSigner.count == 1 }, timeout: 5), "the owed line held")
        withExtendedLifetime(signing) {}
    }

    // MARK: - Codex's change review of 5fa9ec18 (item 182; the owner, 2026-11-01: "go on the fixes, codex-2 a")

    /// codex-1: a record's genuine signature moved before its key's certification (an edited backup), the record taken
    /// out of the log: the phone reads every key's certification before the signatures, so the record still counts as
    /// signed, is named gone, and the next bundle shows it.
    func testASignatureBeforeItsKeysCertificationStillCounts() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let entries = try XCTUnwrap(file.read())
        var edited = entries.filter { $0.record != x.id }
        let certified = try XCTUnwrap(edited.firstIndex { $0.kind == .keyCertified })
        edited.insert(contentsOf: entries.filter { $0.record == x.id }, at: certified)
        XCTAssertEqual(edited.map(\.kind), [.keyPending, .signature, .keyCertified, .signature], "x's signature first")
        try FileManager.default.removeItem(at: file.url)
        for entry in edited { XCTAssertTrue(file.append(entry)) }
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "named gone")
        let snapshot = await relaunched.export(of: b.id, showing: [b.id])
        XCTAssertTrue(try verify(try XCTUnwrap(snapshot).entries, chain).contains { absence($0) != nil }, "b's bundle shows it")
    }

    /// codex-2 (the owner's "a"): the note an earlier build wrote that records went with a log the phone could not read,
    /// put in the file while the log is readable (an edited backup), exempts nothing: the record taken out of the log is
    /// named gone.
    func testANoteOfRecordsSetAsideExemptsNothing() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"kind":"setAside","records":["\#(x.id.uuidString)"]}"# + "\n").utf8))
        try handle.close()
        await relaunch(keys).logWritten(generation: 1, events: [b])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "named gone")
    }

    /// codex-3: a record retired at revisions 1 and 2 while the rewrite failed, then back and signed again, and the app
    /// relaunched before the cleanup: the record's revision is its live signatures', so its export names revision 1 and
    /// its next change is revision 2.
    func testARecordSignedAgainAfterARetiredHistoryKeepsItsLiveRevisionAfterARelaunch() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var a = event(1)
        let b = event(2)
        await signer.logWritten(generation: 1, events: [b, a])
        a.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [b, a])   // revision 2
        try setFolderWritable(false)   // the file can be added to, not written again
        defer { try? setFolderWritable(true) }
        await signer.logWritten(generation: 3, events: [b], limitRemoved: removed(a))
        await signer.logWritten(generation: 4, events: [b, a])   // back, and signed again: revision 1
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, a])   // the log compared, the cleanup failing again
        try setFolderWritable(true)
        let snapshot = await relaunched.export(of: a.id, showing: [a.id])
        let exported = try verify(try XCTUnwrap(snapshot).entries, chain).compactMap { entry -> Int64? in
            if case .export(let statement)? = entry.statement { return statement.revision }
            return nil
        }
        XCTAssertEqual(exported, [1], "the export names the live revision")
        a.ownerAttributed = false
        await relaunched.logWritten(generation: 2, events: [b, a])
        XCTAssertEqual(try revisions(of: a.id, chain), [1, 2], "the live revision, and the next")
    }

    /// A record's revisions put out of order in its file (an edited backup): the record is what its highest revision
    /// signed, wherever the file puts it, so an unchanged record is not signed again.
    func testARecordIsWhatItsHighestRevisionSignedWhateverTheFilesOrder() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        a.ownerAttributed = true
        await signer.logWritten(generation: 2, events: [a])   // revision 2
        await relaunch(keys).logWritten(generation: 1, events: [a])
        XCTAssertEqual(try revisions(of: a.id, chain), [1, 2], "nothing signed: the record is revision 2")
        let entries = try XCTUnwrap(file.read())
        try FileManager.default.removeItem(at: file.url)
        for entry in entries.filter({ $0.record != a.id }) + entries.filter({ $0.record == a.id }).reversed() {
            XCTAssertTrue(file.append(entry))
        }
        await relaunch(keys).logWritten(generation: 1, events: [a])
        XCTAssertEqual(try revisions(of: a.id, chain), [2, 1], "nothing signed in the other order either")
    }

    /// Claude's self-review of the fourth round: a record statement in the file at the highest revision a count can hold
    /// (one that holds under a key whose certification is itself forged; here the test's own key signs it) is not signed
    /// past: the record's next change waits, where adding one to the revision stopped the app at every write of the log.
    func testARevisionNoCountCanPassIsNotSignedPast() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var x = event(1)
        let b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let key = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        let statement = EvidenceForm.bytes(.record(EvidenceForm.Record(id: x.id, revision: .max, signedAt: 0, app: "-",
                                                                     facts: x.evidenceFacts, attachments: [])))
        let assertion = try await keys.generateAssertion(key.base64EncodedString(), clientDataHash: EvidenceHash.sha256(statement))
        XCTAssertTrue(file.append(EvidenceSignatureFile.Entry(kind: .signature, key: key, statement: statement, assertion: assertion)))
        x.ownerAttributed = true
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, x])
        XCTAssertEqual(try revisions(of: x.id, chain), [1, .max], "not signed past the highest revision")
        let c = event(3)
        await relaunched.logWritten(generation: 2, events: [b, x, c])
        XCTAssertEqual(try revisions(of: c.id, chain), [1], "the signer goes on")
    }

    // MARK: - Codex's change review of 68bd96b3 (item 182; the owner, 2026-11-01: "go on the fixes, codex-1 a, codex-3 a")

    /// codex-1 (the owner's "a"): a key certified in the file without its key statement, which no bundle lists, is not
    /// acted on. An edited backup gives such a key, certified by a chain of its own, an absence naming incident x with a
    /// note that its line was written, and another record's statement at the same counter, and takes x out of the log:
    /// x is named gone, under the phone's own key.
    func testAKeyNoBundleListsIsNotActedOn() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), x = event(2), b = event(3)
        await signer.logWritten(generation: 1, events: [b, x, a])
        let entries = try XCTUnwrap(file.read())
        let aStatement = try XCTUnwrap(entries.first { $0.record == a.id }?.statement)
        let forged = try ForgedKey()
        try rewrite([try forged.certified(at: signedAt)] + entries + [
            try forged.signature(of: forged.absence(naming: x), counter: 1),
            EvidenceSignatureFile.Entry(kind: .absenceLogged, records: [x.id], at: signedAt),
            try forged.signature(of: aStatement, counter: 1),
        ])
        await relaunch(keys).logWritten(generation: 1, events: [b, a])
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named gone")
    }

    /// codex-1 (the owner's "a"): a cleanup drops only the record statements it retired. A forged key the bundles list
    /// (its key statement kept with it) signs an absence naming x and another record's statement at one counter; when
    /// the limit retires that record, the forged absence stays in the file, so every bundle lists the key, whose check
    /// fails.
    func testTheCleanupDropsOnlyTheRecordStatementsItRetired() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1), x = event(2), b = event(3)
        await signer.logWritten(generation: 1, events: [b, x, a])
        let entries = try XCTUnwrap(file.read())
        let aStatement = try XCTUnwrap(entries.first { $0.record == a.id }?.statement)
        let forged = try ForgedKey()
        let forgedAbsence = try forged.signature(of: forged.absence(naming: x), counter: 1)
        try rewrite([forged.pending, try forged.certified(at: signedAt)] + entries
                    + [forgedAbsence, try forged.signature(of: aStatement, counter: 1)])
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, a])
        await relaunched.logWritten(generation: 2, events: [b], limitRemoved: removed(a))   // the limit retires a
        let after = try XCTUnwrap(file.read())
        XCTAssertFalse(after.contains { $0.statement == aStatement }, "a's statements retired, its own and the forged one")
        XCTAssertTrue(after.contains { $0.assertion == forgedAbsence.assertion }, "the forged absence stays")
        let snapshot = EvidenceExportSnapshot(entries: after, signedExport: false)
        let listed = try XCTUnwrap(EvidenceExporter.contents(of: b, log: [b], snapshot: snapshot, mediaDirectory: media)).keys
        XCTAssertTrue(listed.contains { $0.id == forged.id }, "every bundle lists the forged key, whose check fails")
    }

    /// codex-2: the records held when the key was first certified are never signed, but an edited backup that adds a
    /// signed record to that list stops nothing: its next change is signed.
    func testAnEditedBaselineDoesNotStopASignedRecordsChanges() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        var x = event(1)
        await signer.logWritten(generation: 1, events: [x])
        try rewrite(try XCTUnwrap(file.read()).map { entry in
            var edited = entry
            if edited.kind == .keyCertified { edited.existing = [x.id] }
            return edited
        })
        x.ownerAttributed = true
        await relaunch(keys).logWritten(generation: 1, events: [x])
        XCTAssertEqual(try revisions(of: x.id, chain), [1, 2], "the change signed")
    }

    /// codex-3 (the owner's "a"): a signer that has not compared the log on disk in this launch offers no bundle and
    /// signs no export; once it has, it does.
    func testNoExportBeforeTheSignerHasComparedTheLogInThisLaunch() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let relaunched = relaunch(keys)
        let offered = await relaunched.canExport(a.id)
        XCTAssertFalse(offered, "not compared yet")
        let refused = await relaunched.export(of: a.id, showing: [a.id])
        XCTAssertNil(refused, "no export statement signed")
        await relaunched.logWritten(generation: 1, events: [a])
        let offeredOnceCompared = await relaunched.canExport(a.id)
        XCTAssertTrue(offeredOnceCompared)
        let exported = await relaunched.export(of: a.id, showing: [a.id])
        XCTAssertEqual(exported?.signedExport, true)
    }

    /// codex-3 (the owner's "a"), through the app's own log and signing: the store hands the signer the log it read at
    /// launch, so a signed record an edited restore took out of the log is named gone at launch, before any write.
    func testTheStoreHandsTheSignerTheLogItReadAtLaunch() throws {
        TestIsolation.setUp(folderPrefix: "Item182LogRead")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())   // x taken out of the log
        let relaunched = EventStore()
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { namesGone([x.id], in: appFile, chain) }, timeout: 5), "named gone at launch")
        withExtendedLifetime(signing) {}
    }

    /// codex-3: a log read only at the unlock is handed to the signer then: a signed record an edited restore took out of
    /// it is named gone at the unlock, before any write.
    func testTheStoreHandsTheSignerTheLogItReadAtTheUnlock() throws {
        TestIsolation.setUp(folderPrefix: "Item182LogReadAtUnlock")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        let log = try logURL()
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)   // unreadable while locked
        let store = EventStore(protectedDataAvailable: { false })
        XCTAssertFalse(store.acceptsWrites, "waiting for the unlock")
        let signing = EvidenceSigning(store: store, keys: keys, center: NotificationCenter())
        try FileManager.default.removeItem(at: log)
        try JSONEncoder().encode([Event]()).write(to: log)   // at the unlock, the log without x
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { namesGone([x.id], in: appFile, chain) }, timeout: 5), "named gone at the unlock")
        withExtendedLifetime(signing) {}
    }

    /// codex-3: what the store hands the signer at launch is the log on disk, and only when no write follows to tell it:
    /// a signed record only the journal held, which its recovery brings back and writes, is never named gone from the
    /// log as read.
    func testARecordTheJournalBringsBackIsNotNamedGoneAtLaunch() throws {
        TestIsolation.setUp(folderPrefix: "Item182JournalAtLaunch")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        try JSONEncoder().encode([Event]()).write(to: try logURL())   // the log without it
        try journal(x)   // the journal with it: a write the app did not finish
        let relaunched = EventStore()
        XCTAssertTrue(relaunched.events.contains { $0.id == x.id }, "the journal brought it back")
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        let next = event(2)
        relaunched.add(next)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.record == next.id } == true }, timeout: 5), "the next record signed")
        XCTAssertFalse(namesGone([x.id], in: appFile, chain), "x not named gone")
        withExtendedLifetime(signing) {}
    }

    /// codex-3: a launch that cannot read the log yet (sealed until the unlock) hands the signer nothing: a signed record
    /// still in the log, read at the unlock, is never named gone.
    func testASealedLaunchHandsTheSignerNothingBeforeTheUnlock() throws {
        TestIsolation.setUp(folderPrefix: "Item182SealedHandOver")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        let log = try logURL()
        let saved = try Data(contentsOf: log)
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)   // unreadable while locked
        let store = EventStore(protectedDataAvailable: { false })
        XCTAssertFalse(store.acceptsWrites, "waiting for the unlock")
        let signing = EvidenceSigning(store: store, keys: keys, center: NotificationCenter())
        try FileManager.default.removeItem(at: log)
        try saved.write(to: log)   // at the unlock, the log as it was, x in it
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertTrue(pump(until: { store.acceptsWrites }, timeout: 5), "read at the unlock")
        let next = event(2)
        store.add(next)
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.record == next.id } == true }, timeout: 5), "the next record signed")
        XCTAssertFalse(namesGone([x.id], in: appFile, chain), "x, in the log, never named gone")
        withExtendedLifetime(signing) {}
    }

    /// codex-3 (the owner's "a"): a log that failed to load (unreadable, and the folder will not take its backup) is
    /// never compared, so Share offers no bundle, not even of a signed record the journal brought back.
    func testShareOffersNoBundleWhileTheLogFailedToLoad() async throws {
        TestIsolation.setUp(folderPrefix: "Item182FailedLoad")
        defer { TestIsolation.tearDown() }
        let keys = FakeKeyService(chain: try TestAttestationChain())
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        // A launch that certifies the key and signs b, its write and the journal's checkpoint settled (an async test
        // waits by suspending: `launchSigningOneRecord` runs the run loop, which an async test cannot).
        let launch = EventStore()
        let launchSigning = EvidenceSigning(store: launch, keys: keys, center: NotificationCenter())
        let launchFile = EvidenceSignatureFile(url: launch.evidenceSignaturesURL)
        try await waitUntil { launchFile.read()?.contains { $0.kind == .keyCertified } == true }
        let b = event(1)
        launch.add(b)
        try await waitUntil { launchFile.read()?.contains { $0.record == b.id } == true }
        launch.drainIOForTesting()
        let journalURL = root.appendingPathComponent("events.journal")
        try await waitUntil { (try? Data(contentsOf: journalURL))?.isEmpty ?? true }
        withExtendedLifetime(launchSigning) {}
        try journal(b)   // the journal holds it, as one not yet checkpointed would
        let log = try logURL()
        try FileManager.default.removeItem(at: log)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)   // unreadable
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // no backup can be made
        let failed = EventStore(protectedDataAvailable: { true })
        XCTAssertTrue(failed.loadFailed)
        XCTAssertTrue(failed.events.contains { $0.id == b.id }, "the journal brought it back")
        let signing = EvidenceSigning(store: failed, keys: keys, center: NotificationCenter())
        let exporter = EvidenceExporter(signer: signing.signer, mediaDirectory: failed.mediaDirectory,
                                        temporaryDirectory: FileManager.default.temporaryDirectory)
        try await Task.sleep(for: .seconds(1))   // time for the store to hand the signer a log, were it to
        let offered = await EvidenceBundleItem.forShare(of: b, log: failed.events, exporter: exporter)
        XCTAssertNil(offered, "no bundle while the log failed to load")
        withExtendedLifetime(signing) {}
    }

    // MARK: - Codex's change review of 401fe979 (item 182; the owner, 2026-11-01: "1 a, wording approved")

    /// codex-1 (the owner's "a"): a comparison that finds a signed record gone and cannot sign its absence (the signing
    /// failed) keeps it owed: Share offers no bundle, and an export names it first.
    func testAnAbsenceThatCouldNotBeSignedIsOwedAndAnExportNamesItFirst() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [b])   // x gone; its absence not signed
        XCTAssertFalse(namesGone([x.id], in: file, chain))
        let offered = await signer.canExport(b.id)
        XCTAssertFalse(offered, "no bundle while x is owed its name")
        let snapshot = await signer.export(of: b.id, showing: [b.id])
        let checked = try verify(try XCTUnwrap(snapshot).entries, chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "named before the export")
        XCTAssertEqual(snapshot?.signedExport, true)
    }

    /// codex-1 (the owner's "a"): an unsigned note that the key was lost (an edited restore) has the phone certify a new
    /// key, and the comparison made while that certification is under way finds incident x gone with no key to name it:
    /// no bundle meanwhile, and x is named once the new key is certified, before any write of the log.
    func testWhatAComparisonCouldNotNameIsNamedOnceANewKeyIsCertified() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let key = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        XCTAssertTrue(file.append(EvidenceSignatureFile.Entry(kind: .keyLost, key: key, at: signedAt)))
        let relaunched = relaunch(keys)
        await keys.holdNextAttestation()
        let certifying = Task { await relaunched.certifyIfNeeded(records: nil) }
        try await waitForAttestRequests(keys, count: 2)   // the first key's, then the new one's, held
        await relaunched.logWritten(generation: 1, events: [b])   // the comparison: x gone, no key to name it
        let offeredWhileCertifying = await relaunched.canExport(b.id)
        XCTAssertFalse(offeredWhileCertifying, "no bundle while x is owed its name")
        await keys.releaseHeldAttestation()
        await certifying.value
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named once the new key is certified")
        let offered = await relaunched.canExport(b.id)
        XCTAssertTrue(offered)
    }

    /// codex-1 (the owner's "a"): the app coming forward with a key names what a comparison could not, and the event log
    /// is given its line at once.
    func testTheAppComingForwardNamesWhatIsOwedAndItsLineFollows() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [b])   // x gone; its absence not signed
        XCTAssertEqual(lines.ids, [], "no line yet")
        await signer.certifyIfNeeded(records: [b.id])   // as the app does when it comes forward
        XCTAssertTrue(namesGone([x.id], in: file, chain), "named")
        XCTAssertEqual(lines.ids.count, 1, "its line at once")
        let offered = await signer.canExport(b.id)
        XCTAssertTrue(offered)
    }

    // MARK: - Codex's change review of 21ea9a43 (item 182; the owner, 2026-11-01: "go on the fixes, codex-2 a")

    /// codex-1: a signing in a pass that finds the key lost has the pass certify a new one; once it is, what the pass
    /// found gone and could not name is named in that pass, the event log given its line at once, and Share offers the
    /// bundle.
    func testThePassesOwnCertificationNamesWhatIsOwed() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        let x = event(1)
        var b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        b.ownerAttributed = true   // a change to sign
        await keys.failNextAssertions([DCError(.unknownSystemFailure), DCError(.invalidKey)])   // x's absence, then b's
        await signer.logWritten(generation: 2, events: [b])
        XCTAssertEqual(file.read()?.filter { $0.kind == .keyCertified }.count, 2, "a new key certified")
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named in the same pass")
        XCTAssertEqual(lines.ids.count, 1, "its line at once")
        let offered = await signer.canExport(b.id)
        XCTAssertTrue(offered)
    }

    /// codex-2 (the owner's "a"): a record keeps its kind as signed. An edited log that puts a status entry under
    /// incident x's ID, at x's start, has not got x: x is named gone, and the row is never signed as x's revision.
    func testARowUnderASignedRecordsIDOfAnotherKindIsNotThatRecord() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let row = Event(id: x.id, startDate: x.startDate, endDate: x.startDate, triggeredSensors: [], cloudSyncState: .pending,
                        stateChange: "settingsReset")
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, row])
        await relaunched.logWritten(generation: 2, events: [b, row])
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named gone")
        XCTAssertEqual(try revisions(of: x.id, chain), [1], "the row never signed as x's revision")
    }

    /// codex-2 (the owner's "a"): a record keeps its start as signed. An edited log that puts another incident under x's
    /// ID, started at another time, has not got x: x is named gone, and the row is never signed as x's revision.
    func testARowUnderASignedRecordsIDWithAnotherStartIsNotThatRecord() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let other = x.startDate.addingTimeInterval(3_600)
        let row = Event(id: x.id, startDate: other, endDate: other.addingTimeInterval(5), triggeredSensors: [.motion],
                        motionTrace: [0.5, 1.5])
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, row])
        await relaunched.logWritten(generation: 2, events: [b, row])
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named gone")
        XCTAssertEqual(try revisions(of: x.id, chain), [1], "the row never signed as x's revision")
    }

    /// codex-2 (Codex's route; the owner's "a"): a record found gone and not yet named stays owed when its ID comes back
    /// as another record: it is named, and the row is not signed as it.
    func testARecordOwedItsNameStaysOwedWhenItsIDComesBackAsAnotherRecord() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        await keys.failNextAssertions([DCError(.unknownSystemFailure)])
        await signer.logWritten(generation: 2, events: [b])   // x gone; its absence not signed
        let row = Event(id: x.id, startDate: x.startDate, endDate: x.startDate, triggeredSensors: [], cloudSyncState: .pending,
                        stateChange: "settingsReset")
        await signer.logWritten(generation: 3, events: [b, row])
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named")
        XCTAssertEqual(try revisions(of: x.id, chain), [1], "the row not signed as x")
    }

    // MARK: - The counters' ranges (the core)

    func testCountersBecomeAscendingRangesWithGapsBetween() {
        XCTAssertEqual(EvidenceForm.counterRanges([5, 1, 2, 3, 9, 3, 6]), [1...3, 5...6, 9...9])
        XCTAssertEqual(EvidenceForm.counterRanges([]), [])
        XCTAssertEqual(EvidenceForm.counterRanges([UInt32.max, UInt32.max - 1]), [(UInt32.max - 1)...UInt32.max])
    }

    // MARK: - Helpers

    private func makeSigner(supported: Bool = true, clock: TestClock? = nil, retryAfter: TimeInterval = 0,
                            keyList: (any EvidenceKeyListStore)? = nil) throws
        -> (EvidenceSigner, FakeKeyService, TestAttestationChain) {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(supported: supported, chain: chain)
        let time = clock ?? TestClock(signedAt)
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { time.now },
                                    retryAfter: retryAfter, keyList: keyList)
        return (signer, keys, chain)
    }

    private func event(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }

    /// Every key the file certifies, checked with the verifier's rules against the test chain.
    private func certifiedKeys(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> [EvidenceCertifiedKey] {
        try entries.filter { $0.kind == .keyCertified }.map { certified in
            let pending = try XCTUnwrap(entries.last { $0.kind == .keyPending && $0.key == certified.key })
            return try EvidenceVerifier.certify(attestation: try XCTUnwrap(certified.attestation),
                                                statement: try XCTUnwrap(pending.statement), appID: TestApp.id, roots: [chain.rootDER])
        }
    }

    private func certifiedKey(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> EvidenceCertifiedKey {
        try XCTUnwrap(try certifiedKeys(entries, chain).first)
    }

    /// Every signature in the file, checked with the verifier's rules under the key it names, with its statement read.
    private func verify(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> [EvidenceSignedEntry] {
        let keys = try certifiedKeys(entries, chain)
        return try entries.filter { $0.kind == .signature }.map { entry in
            let key = try XCTUnwrap(keys.first { $0.keyID == entry.key })
            let statement = try XCTUnwrap(entry.statement)
            return try EvidenceVerifier.check(assertion: try XCTUnwrap(entry.assertion), formHash: TestApp.sha256(statement),
                                              form: statement, under: key)
        }
    }

    /// The signatures in the file that hold under the key they name, checked with the verifier's rules; one that does not
    /// is left out.
    private func holding(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> [EvidenceSignedEntry] {
        let keys = try certifiedKeys(entries, chain)
        return entries.filter { $0.kind == .signature }.compactMap { entry in
            guard let key = keys.first(where: { $0.keyID == entry.key }), let statement = entry.statement,
                  let assertion = entry.assertion else { return nil }
            return try? EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(statement), form: statement, under: key)
        }
    }

    /// The revisions of `record` the file's signatures sign, in the file's order.
    private func revisions(of record: UUID, _ chain: TestAttestationChain) throws -> [Int64] {
        try verify(try XCTUnwrap(file.read()), chain).compactMap { entry in
            if case .record(let form)? = entry.statement, form.id == record { return form.revision }
            return nil
        }
    }

    /// The limit's removals of `events`, with what each removed row was, as the store hands them to the signer.
    private func removed(_ events: Event...) -> [UUID: RecordIdentity] { removed(events) }

    private func removed(_ events: [Event]) -> [UUID: RecordIdentity] {
        Dictionary(events.map { ($0.id, $0.evidenceIdentity) }, uniquingKeysWith: { first, _ in first })
    }

    /// The signatures in `entries` under a key the test chain certifies, checked with the verifier's rules: a forged key's
    /// are left out.
    private func underCertifiedKeys(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) -> [EvidenceSignedEntry] {
        let keys = entries.filter { $0.kind == .keyCertified }.compactMap { certified -> EvidenceCertifiedKey? in
            guard let pending = entries.last(where: { $0.kind == .keyPending && $0.key == certified.key }),
                  let attestation = certified.attestation, let statement = pending.statement else { return nil }
            return try? EvidenceVerifier.certify(attestation: attestation, statement: statement, appID: TestApp.id, roots: [chain.rootDER])
        }
        return entries.filter { $0.kind == .signature }.compactMap { entry in
            guard let key = keys.first(where: { $0.keyID == entry.key }), let statement = entry.statement,
                  let assertion = entry.assertion else { return nil }
            return try? EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(statement), form: statement, under: key)
        }
    }

    /// Whether `file` holds an absence statement, under a key the test chain certifies, naming `ids`.
    private func namesGone(_ ids: [UUID], in file: EvidenceSignatureFile, _ chain: TestAttestationChain) -> Bool {
        guard let entries = file.read() else { return false }
        return underCertifiedKeys(entries, chain).contains { absence($0)?.records.map(\.id) == ids }
    }

    /// Writes the test's signature file anew with `entries`, as an edited backup restored would leave it.
    private func rewrite(_ entries: [EvidenceSignatureFile.Entry]) throws {
        try FileManager.default.removeItem(at: file.url)
        for entry in entries { XCTAssertTrue(file.append(entry)) }
    }

    private func recordID(_ entry: EvidenceSignedEntry) -> UUID? {
        if case .record(let form)? = entry.statement { return form.id }
        return nil
    }

    /// The element at `index`, or nil: a list too short fails the assertion that reads it, not the whole class.
    private func at<Element>(_ list: [Element], _ index: Int) -> Element? { list.indices.contains(index) ? list[index] : nil }

    private func isRetention(_ entry: EvidenceSignedEntry) -> Bool {
        if case .retention? = entry.statement { return true }
        return false
    }

    private func retention(_ entry: EvidenceSignedEntry) -> EvidenceForm.Retention? {
        if case .retention(let statement)? = entry.statement { return statement }
        return nil
    }

    private func absence(_ entry: EvidenceSignedEntry) -> EvidenceForm.Absence? {
        if case .absence(let statement)? = entry.statement { return statement }
        return nil
    }

    /// A signer that tells which of the limit's removals it accounted for.
    private func accountingSigner() throws -> (EvidenceSigner, AccountedRemovals, TestAttestationChain) {
        let chain = try TestAttestationChain()
        let accounted = AccountedRemovals()
        let signer = EvidenceSigner(file: file, keys: FakeKeyService(chain: chain), mediaDirectory: media, app: "1.10 (81)",
                                    now: { [signedAt] in signedAt }, retryAfter: 0, removalsAccounted: accounted.handler)
        return (signer, accounted, chain)
    }

    /// A status entry of this phone's, `minute` minutes into the hour.
    private func statusEvent(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, 0).addingTimeInterval(TimeInterval(minute * 60))
        return Event(startDate: start, endDate: start, triggeredSensors: [], cloudSyncState: .pending, stateChange: "settingsReset")
    }

    /// A status entry of `kind`, as the log holds one.
    private func stateEvent(_ kind: String) -> Event {
        Event(startDate: signedAt, endDate: signedAt, triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
    }

    /// The removals' file holding `removals`, checked with this phone's key, as the store writes it.
    private func writeRemovals(_ removals: Set<UUID>) throws {
        let key = try XCTUnwrap(EventStore.limitRemovalsKey(create: true))
        let unknown = Dictionary(uniqueKeysWithValues: removals.map { ($0, RecordIdentity(start: nil, kind: nil)) })
        try EventStore.limitRemovalsData(unknown, key: key).write(to: try removalsURL())
    }

    /// The removals' files set aside in `root`.
    private func asideRemovals(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("limit-removals.corrupt") }
    }

    /// The removals the file holds, its check holding with this phone's key.
    private func readRemovals() throws -> Set<UUID> {
        let key = try XCTUnwrap(EventStore.limitRemovalsKey(create: false))
        return Set(try XCTUnwrap(EventStore.limitRemovals(in: try Data(contentsOf: try removalsURL()), key: key), "checked").keys)
    }

    /// The test's file of the limit's removals, beside its log, in the test's folder (made when missing).
    private func removalsURL() throws -> URL {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(EventStore.limitRemovalsFileName)
    }

    /// The signer of the app's next launch, on the same file and keys.
    private func relaunch(_ keys: FakeKeyService, keyList: (any EvidenceKeyListStore)? = nil, at launched: Date? = nil) -> EvidenceSigner {
        let at = launched ?? signedAt
        return EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { at }, retryAfter: 0,
                              keyList: keyList)
    }

    /// The key statements the file holds, in order (item 190's A3).
    private func keyStatements() throws -> [EvidenceForm.KeyStatement] {
        try XCTUnwrap(file.read()).filter { $0.kind == .keyPending }.compactMap { entry -> EvidenceForm.KeyStatement? in
            guard let bytes = entry.statement, case .key(let statement)? = try? EvidenceForm.read(bytes) else { return nil }
            return statement
        }
    }

    /// Lets the signature file be written, or only read.
    private func setFileWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o644 : 0o444], ofItemAtPath: file.url.path)
    }

    /// Lets the test's folder take new files, or not, as a full disk refuses them: the signature file can still be added
    /// to, but not written again (a rewrite goes through a new file).
    private func setFolderWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    /// A launch whose limit removes its oldest status entry, with no signer to account for it, its writes and the
    /// journal's checkpoint settled: the removal, owed on disk.
    private func removeOneByTheLimitAndSettle() throws -> UUID {
        let store = EventStore()
        let oldest = statusEvent(0)
        store.add(oldest)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        store.drainIOForTesting()
        let journal = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.journal")
        XCTAssertTrue(pump(until: { (try? Data(contentsOf: journal))?.isEmpty ?? true }, timeout: 5), "the journal checkpointed")
        XCTAssertEqual(store.limitRemovals, [oldest.id], "the limit removed the oldest")
        return oldest.id
    }

    /// The test's journal holding `event` alone: written, the app ending before the log's write.
    private func journal(_ event: Event) throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try XCTUnwrap(EventStore.journalLine(for: event)).write(to: root.appendingPathComponent("events.journal"))
    }

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

    /// Waits, up to 5 seconds, until the stand-in has been asked for `count` certifications.
    private func waitForAttestRequests(_ keys: FakeKeyService, count: Int) async throws {
        var waited = 0
        while await keys.attestRequests.count < count, waited < 500 {
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        let asked = await keys.attestRequests.count
        XCTAssertEqual(asked, count)
    }

    /// The test's event log.
    private func logURL() throws -> URL {
        try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.json")
    }

    /// A launch of the app's signing that certifies the key and signs one record, its write and the journal's checkpoint
    /// settled: the record.
    private func launchSigningOneRecord(_ keys: FakeKeyService) throws -> Event {
        let store = EventStore()
        let signing = EvidenceSigning(store: store, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.kind == .keyCertified } == true }, timeout: 5), "certified")
        let record = event(1)
        store.add(record)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.record == record.id } == true }, timeout: 5), "signed")
        store.drainIOForTesting()
        let journal = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.journal")
        XCTAssertTrue(pump(until: { (try? Data(contentsOf: journal))?.isEmpty ?? true }, timeout: 5), "the journal checkpointed")
        withExtendedLifetime(signing) {}
        return record
    }

    /// The next launch's first write, after a log that held `signed` was set aside: the new record is signed, `signed`
    /// is named gone with its signature kept, and no retention statement is signed (codex-2 on 5fa9ec18).
    private func assertNamedGoneNotRetired(_ signed: Event, store: EventStore, _ chain: TestAttestationChain,
                                           line: UInt = #line) throws {
        let appFile = EvidenceSignatureFile(url: store.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { appFile.read()?.contains { $0.record != nil && $0.record != signed.id } == true }, timeout: 5),
                      "the new record signed", line: line)
        let entries = try XCTUnwrap(appFile.read())
        XCTAssertTrue(entries.contains { $0.record == signed.id }, "its signature kept", line: line)
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[signed.id]], "named gone", line: line)
        XCTAssertFalse(checked.contains(where: isRetention), "no retention statement", line: line)
    }

    /// Runs the main run loop until `condition` holds or `timeout` seconds of awake time pass: the system's uptime
    /// stands still while the Mac sleeps, so a sleep during a long unattended run does not use the time up.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}

// The tests of Codex's later change reviews of items 182 and 190, beside the class so its body stays within the linter's
// length; an extension in this file reaches the class's private helpers.
@MainActor
extension Item90SignerTests {
    // MARK: - The keys this install certified (item 190's A3), continued beside the class

    /// The line says what is missing, stands out as the absence line does, is placed by its time, and another device
    /// reads it back.
    func testTheMissingSignaturesLineReadsStandsOutAndTravels() {
        let line = stateEvent(Event.signaturesMissingKind)
        XCTAssertEqual(line.sensorSummary,
                       "Signatures this iPhone made earlier are missing: its earlier events can no longer be shared signed")
        XCTAssertTrue(EventRow.isAlarm(line))
        XCTAssertNil(EventRow.summaryLineLimit(for: line))
        XCTAssertEqual(EventRow.placeholderIcon(for: line.stateChange), "exclamationmark.triangle.fill")
        XCTAssertTrue(Event.isSignerLine(line), "placed in the log by its time, as the absence line is")
        let record = CloudExfiltrator.makeStateRecord(line, kind: Event.signaturesMissingKind, deviceName: "iPhone Air")
        XCTAssertEqual(CloudExfiltrator.stateEvent(from: record)?.stateChange, Event.signaturesMissingKind)
    }

    // MARK: - The change reviews of 29d6501 (item 190, round 190B; the owner, 2026-11-02: "codex-1 a, codex-2 a, codex-3 a")

    /// codex-1: an edited signature file holding another install's key, with its statement and Apple's certification as
    /// any bundle that install shared holds them, put that key on the Keychain's list after the phone's own lost key, so
    /// the next key followed it and no later bundle named the key the phone lost. A key from the file joins the list only
    /// when its statement follows the list's last: the stranger's stays off it, the next key follows the phone's own, and
    /// the log says signatures are missing.
    func testAnotherInstallsKeyInAnEditedFileNeverLeadsTheNextKey() async throws {
        let list = TestKeyList()
        let (signer, keys, chain) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        let stranger = try await certifiedKeyEntries(FakeKeyService(chain: chain))
        let strangerKey = try XCTUnwrap(stranger.first?.key)
        // The edited backup, restored: the phone's key gone from App Attest and from the file, the stranger's put in.
        await keys.lose(first.base64EncodedString())
        try rewrite(stranger)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])   // App Attest refuses the stranger's key: a new key
        XCTAssertEqual(try keyStatements().last?.follows, first, "the new key follows the phone's own lost key")
        XCTAssertFalse(list.current.certified.contains(strangerKey), "the stranger's key never joins the list")
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The rule keeps the phone's own keys: keys certified after the list's last and not added to it (the app stopped
    /// between the file and the Keychain) join it at the next launch, each in turn, and nothing is said.
    func testKeysCertifiedAfterTheListsLastJoinItInTurnAfterAStop() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let log = [event(3), event(2), event(1)]
        await signer.logWritten(generation: 1, events: [log[2]])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        await signer.logWritten(generation: 2, events: Array(log.suffix(2)))   // refused: a second key
        let second = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        await keys.lose(second.base64EncodedString())
        await signer.logWritten(generation: 3, events: log)   // refused again: a third
        let third = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        XCTAssertEqual(try keyStatements().map(\.follows), [nil, first, second])
        list.set(EvidenceKeyList(certified: [first], made: [second, third]))   // as it was before the two were noted
        let lines = LineWriter()
        let relaunched = relaunch(keys, keyList: list)
        await relaunched.writeLines(with: lines.write)
        await relaunched.certifyIfNeeded(records: log.map(\.id))
        await relaunched.logWritten(generation: 1, events: log)
        XCTAssertEqual(list.current.certified, [first, second, third])
        XCTAssertEqual(list.current.made, [], "each certified, no longer only made")
        XCTAssertEqual(lines.written, [], "nothing lost")
    }

    /// Claude's self-review on round 190B: a key the Keychain did not take (its write failed) is still the last this
    /// install certified, so the next key follows it, and at the next launch the file brings both to the list in turn:
    /// no key of the phone's own is ever kept off it as another install's.
    func testAKeyTheKeychainDidNotTakeIsStillTheOneTheNextKeyFollows() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let log = [event(3), event(2), event(1)]
        await signer.logWritten(generation: 1, events: [log[2]])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        list.failNextCertifyingWrites(1)
        await keys.lose(first.base64EncodedString())
        await signer.logWritten(generation: 2, events: Array(log.suffix(2)))   // a second key, which the Keychain refuses
        let second = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        XCTAssertEqual(list.current.certified, [first], "the Keychain did not take it")
        await keys.lose(second.base64EncodedString())
        await signer.logWritten(generation: 3, events: log)
        XCTAssertEqual(try keyStatements().last?.follows, second, "the next key follows the last this install certified")
        let third = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        list.set(EvidenceKeyList(certified: [first], made: [second, third]))   // and had the Keychain refused that one too
        let relaunched = relaunch(keys, keyList: list)
        await relaunched.certifyIfNeeded(records: log.map(\.id))
        await relaunched.logWritten(generation: 1, events: log)
        XCTAssertEqual(list.current.certified, [first, second, third], "each joins the list in turn")
    }

    /// codex-2: a Keychain that could not be read when the file could (a missing file reads as empty even before the
    /// phone's first unlock) was taken as no list: the file counted as read, never again in that launch, and the next key
    /// followed none. The file is not taken as read until the list is: no key is made without it, and the one made once it
    /// can be read follows the key the file lost, the log saying so.
    func testAKeychainThatCannotBeReadYetHoldsEverythingUntilItCan() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        list.failNextReads(2)
        let restored = relaunch(keys, keyList: list)
        await restored.heardTheLogRead([a.id])   // the Keychain cannot be read yet: neither is the file
        await restored.certifyIfNeeded(records: [a.id])   // nor yet
        XCTAssertEqual(try keyStatements(), [], "no key is made without the list")
        let lines = LineWriter()
        await restored.writeLines(with: lines.write)
        await restored.certifyIfNeeded(records: [a.id])   // it can now
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(try keyStatements().last?.follows, first, "the new key follows the key the file lost")
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// codex-3: whether the log held records from before the launch was judged by their dates, so with the phone's clock
    /// set back before the first launch after an edit, every record looked newer than the launch, nothing was said, and
    /// the lost key counted dealt with for good. The log the launch read decides: the line is said once, and not again once
    /// the clock is put right.
    func testAClockSetBackDoesNotHideTheMissingSignaturesLine() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list, at: a.startDate.addingTimeInterval(-86_400))   // a day behind the log
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
        let later = relaunch(keys, keyList: list, at: signedAt.addingTimeInterval(3_600))   // the clock put right
        let more = LineWriter()
        await later.writeLines(with: more.write)
        await later.certifyIfNeeded(records: [a.id] + lines.ids)
        await later.logWritten(generation: 1, events: lines.events + [a])
        XCTAssertEqual(more.written, [], "said once")
    }

    /// codex-2 and deepseek-3 on b7702f5: at a launch while the phone was locked, the log read at the unlock reached the
    /// signer before the log the launch read, and nothing took the decision once that came: the line waited for another
    /// write of the log. It is taken as soon as both are known, and the line written then.
    func testTheMissingSignaturesDecisionWaitsForTheLogTheLaunchRead() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.writeLines(with: lines.write)
        await restored.logWritten(generation: 1, events: [a])   // the log read at the unlock, first
        await restored.heardTheLogRead([a.id])   // then the log the launch read, and no other write
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// After a reinstall, a record of the launch's own is no history from before it, though the app comes forward with it
    /// before any pass: the log the launch read held nothing, and nothing is said.
    func testARecordOfTheLaunchIsNoLostHistoryAfterAReinstall() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        await signer.logWritten(generation: 1, events: [event(1)])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let reinstalled = relaunch(keys, keyList: list)
        await reinstalled.writeLines(with: lines.write)
        await reinstalled.heardTheLogRead([])   // the log the launch read: empty
        await reinstalled.certifyIfNeeded(records: [])
        let after = signedAt.addingTimeInterval(600)
        let fresh = Event(startDate: after, endDate: after.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [1])
        await reinstalled.certifyIfNeeded(records: [fresh.id])   // the app comes forward
        await reinstalled.logWritten(generation: 1, events: [fresh])
        XCTAssertEqual(lines.written, [])
    }

    // MARK: - The change reviews of b7702f5 (item 190, round 190C; the owner, 2026-11-02: "codex-1 a, codex-2 a, codex-3 a",
    // then "deepseek-2 a, deepseek-3 a, deepseek-5 a")

    /// codex-1 on b7702f5: the list took a key from the file whenever its statement named the list's last as the key it
    /// follows. A second iPhone given this phone's signature file makes a key of its own that genuinely follows this
    /// phone's; put in an edited backup of this phone, it joined the list, and the next key followed it. A key from the
    /// file joins a list that is not empty only when this install made it: the other phone's never does, and the next
    /// key follows this phone's own.
    func testAKeyAnotherPhoneMadeFollowingThisPhonesKeyNeverJoinsTheList() async throws {
        let list = TestKeyList()
        let (signer, keys, chain) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        let other = try await certifiedKeyEntries(FakeKeyService(chain: chain), follows: first)
        let otherKey = try XCTUnwrap(other.first?.key)
        await keys.lose(first.base64EncodedString())
        try rewrite(try XCTUnwrap(file.read()) + other)   // the edited backup: this phone's file, the other key added
        let restored = relaunch(keys, keyList: list)
        await restored.heardTheLogRead([a.id])
        await restored.logWritten(generation: 1, events: [event(2), a])   // App Attest refuses the other key: a new key
        XCTAssertFalse(list.current.certified.contains(otherKey), "the other phone's key never joins the list")
        XCTAssertEqual(try keyStatements().last?.follows, first, "the new key follows this phone's own")
    }

    /// The same with a statement edited to name this phone's key (deepseek-1 on b7702f5), Apple's certification of the
    /// stranger's own statement left beside it: the key never joins the list.
    func testAnEditedKeyStatementNeverJoinsTheList() async throws {
        let list = TestKeyList()
        let (signer, keys, chain) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        let stranger = try await certifiedKeyEntries(FakeKeyService(chain: chain))
        let strangerKey = try XCTUnwrap(stranger.first?.key)
        let certification = try XCTUnwrap(stranger.last)
        let edited = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: strangerKey, signedAt: 1_793_000_000_000,
                                                                       app: "1.10 (81)", follows: first)))
        await keys.lose(first.base64EncodedString())
        try rewrite(try XCTUnwrap(file.read()) + [EvidenceSignatureFile.Entry(kind: .keyPending, key: strangerKey, statement: edited),
                                                  certification])
        let restored = relaunch(keys, keyList: list)
        await restored.heardTheLogRead([a.id])
        await restored.logWritten(generation: 1, events: [event(2), a])
        XCTAssertFalse(list.current.certified.contains(strangerKey), "an edited statement never joins the list")
        XCTAssertEqual(try keyStatements().last?.follows, first)
    }

    /// codex-1 (a): a key goes to Apple only once the list has noted that this install made it; while the Keychain will
    /// not take the note, no key is made.
    func testNoKeyGoesToAppleBeforeTheListNotesItWasMadeHere() async throws {
        let list = TestKeyList()
        let (signer, _, _) = try makeSigner(keyList: list)
        list.failNextWrites(1)
        await signer.certifyIfNeeded(records: [])
        XCTAssertEqual(try keyStatements(), [], "no key without its note")
        await signer.certifyIfNeeded(records: [])   // the Keychain takes it now
        let made = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        XCTAssertEqual(list.current.certified, [made])
        XCTAssertEqual(list.current.made, [], "once certified, a key is no longer only made")
    }

    /// deepseek-3 on b7702f5: the decision asked a record of the launch's log to be in the pass that decides, so a record
    /// the log's limit took out in between lost the line for good. The log the launch read decides alone.
    func testTheLineIsOwedThoughTheLaunchsRecordsLeftBeforeThePass() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        let after = signedAt.addingTimeInterval(600)
        let fresh = Event(startDate: after, endDate: after.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [1])
        await restored.logWritten(generation: 1, events: [fresh])   // `a` gone before the first pass (the log's limit)
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The log the launch read is the first the signer is handed: a later hand-over changes no decision still waiting for
    /// the file (codex-2 on b7702f5; the undo check's need).
    func testALaterHandOverDoesNotReplaceTheLogTheLaunchRead() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        list.failNextReads(1)
        let lines = LineWriter()
        let restored = relaunch(keys, keyList: list)
        await restored.heardTheLogRead([a.id])   // the Keychain cannot be read yet: the decision waits
        await restored.heardTheLogRead([])
        await restored.writeLines(with: lines.write)
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// deepseek-5 on b7702f5: a list the Keychain refused to write was written again only from the file, at the next
    /// launch. It is written again at the next pass.
    func testAListTheKeychainRefusedIsWrittenAgainAtTheNextPass() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let log = [event(3), event(2), event(1)]
        await signer.logWritten(generation: 1, events: [log[2]])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        list.failNextCertifyingWrites(1)
        await keys.lose(first.base64EncodedString())
        await signer.logWritten(generation: 2, events: Array(log.suffix(2)))   // a second key; the Keychain refuses the list
        let second = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        XCTAssertEqual(list.current.certified, [first])
        await signer.logWritten(generation: 3, events: log)
        XCTAssertEqual(list.current.certified, [first, second], "written again at the next pass")
    }

    /// codex-1 and deepseek-5 on b7702f5: the list as the builds before round 190C wrote it, with no key noted as made,
    /// still reads.
    func testAListAnEarlierBuildWroteStillReads() throws {
        let earlier = Data(#"{"certified":["oQ=="],"accounted":["sg=="]}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(EvidenceKeyList.self, from: earlier),
                       EvidenceKeyList(certified: [Data([0xA1])], accounted: [Data([0xB2])], made: []))
    }

    /// deepseek-3 on b7702f5: at a launch while the phone was locked, the signer asked for the log before the store had
    /// read it, and nothing told it the log the store read at the unlock. The store keeps the log it read at launch, this
    /// phone's own records only, and tells it at the unlock when the launch could not read it.
    func testTheStoreKeepsTheLogItReadAndTellsItAtTheUnlock() async throws {
        TestIsolation.setUp(folderPrefix: "Item190LogRead")
        defer { TestIsolation.tearDown() }
        let mine = event(1)
        try writeLog(mine: mine)
        let launched = EventStore()
        XCTAssertEqual(launched.logReadAtLaunch, [mine.id], "this phone's own records, at launch")
        launched.drainIOForTesting()
        let log = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)   // sealed: a locked launch
        let phone = LockState()
        let locked = EventStore(protectedDataAvailable: { phone.unlocked })
        XCTAssertNil(locked.logReadAtLaunch, "none while the log waits for the unlock")
        let told = HandedLog()
        locked.onLogRead = { told.ids = $0 }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await waitUntil { told.ids != nil }
        XCTAssertEqual(told.ids, [mine.id], "told at the unlock")
        locked.drainIOForTesting()
    }

    /// And the app's signing hands the signer the log the store read at launch (deepseek-3 on b7702f5).
    func testTheAppsSigningHandsTheSignerTheLogTheStoreRead() async throws {
        TestIsolation.setUp(folderPrefix: "Item190LogReadApp")
        defer { TestIsolation.tearDown() }
        let mine = event(1)
        try writeLog(mine: mine)
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        let signer = services.evidenceSigning.signer
        try await waitUntil { await signer.heldAtLaunchForTesting != nil }
        let held = await signer.heldAtLaunchForTesting
        XCTAssertEqual(held, [mine.id], "this phone's own records")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    /// And at a launch while the phone was locked, the app's signing hands the signer the log the store read at the unlock
    /// (deepseek-3 on b7702f5).
    func testTheAppsSigningHandsTheSignerTheLogTheStoreReadAtTheUnlock() async throws {
        TestIsolation.setUp(folderPrefix: "Item190LogReadUnlock")
        defer { TestIsolation.tearDown() }
        let mine = event(1)
        try writeLog(mine: mine)
        let log = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)   // sealed: a locked launch
        let phone = LockState()
        let store = EventStore(protectedDataAvailable: { phone.unlocked })
        let signing = EvidenceSigning(store: store, keys: FakeKeyService(chain: try TestAttestationChain()),
                                      center: NotificationCenter())
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await waitUntil { await signing.signer.heldAtLaunchForTesting != nil }
        let held = await signing.signer.heldAtLaunchForTesting
        XCTAssertEqual(held, [mine.id], "handed over at the unlock")
        store.drainIOForTesting()
        withExtendedLifetime(signing) {}
    }

    /// The test's log on disk: `mine`, a record of this phone's, and another device's copy beside it.
    private func writeLog(mine: Event) throws {
        let writer = EventStore()
        var theirs = event(2)
        theirs.sourceDevice = "Owner's iPad"
        writer.add(mine)
        writer.merge([theirs])
        writer.drainIOForTesting()
    }

    /// Another install's key as a bundle it shared holds it (item 190's codex-1 on 29d6501): its statement, following
    /// `follows` (none by default), and Apple's certification of it, as the two lines a signature file keeps for a key.
    private func certifiedKeyEntries(_ other: FakeKeyService, follows: Data? = nil) async throws -> [EvidenceSignatureFile.Entry] {
        let id = try await other.generateKey()
        let key = try XCTUnwrap(Data(base64Encoded: id))
        let statement = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: key, signedAt: 1_793_000_000_000, app: "1.10 (81)",
                                                                         follows: follows)))
        let attestation = try await other.attestKey(id, clientDataHash: TestApp.sha256(statement))
        return [EvidenceSignatureFile.Entry(kind: .keyPending, key: key, statement: statement),
                EvidenceSignatureFile.Entry(kind: .keyCertified, key: key, attestation: attestation, existing: [])]
    }

    // MARK: - The change reviews of 424d8ce (item 190, round 190D; the owner, 2026-11-02: "codex-1 a, codex-2 a, codex-3 a",
    // then "deepseek-1 a, deepseek-2 a")

    /// codex-1 on 424d8ce: a key an earlier build left waiting for Apple (1.10 (81), or an 82 build before the list noted
    /// the keys made) went to Apple unnoted, so with the Keychain refusing the list's next write, the next launch kept that
    /// key, the phone's own, off the list, and the key after it followed the one before. A waiting key the list did not
    /// note as made here is never sent: a fresh key is made and noted first, and the list keeps it.
    func testAKeyAnEarlierBuildLeftWaitingIsNeverSentToAppleUnnoted() async throws {
        let (earlier, keys, _) = try makeSigner()   // a build before the list
        await earlier.certifyIfNeeded(records: [])
        let log = [event(2), event(1)]
        await earlier.logWritten(generation: 1, events: [log[1]])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await earlier.logWritten(generation: 2, events: log)   // refused: a new key, which Apple does not answer
        let waiting = try XCTUnwrap(file.read()?.last { $0.kind == .keyPending }?.key)
        XCTAssertNotEqual(waiting, first, "a key waiting for Apple")
        // The upgrade: the list as the first launch over that build wrote it, the Keychain refusing its next key.
        let list = TestKeyList()
        list.set(EvidenceKeyList(certified: [first]))
        list.failNextCertifyingWrites(1)
        await relaunch(keys, keyList: list).certifyIfNeeded(records: log.map(\.id))
        let replacement = try XCTUnwrap(file.read()?.last { $0.kind == .keyCertified }?.key)
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.kind == .keyCertified && $0.key == waiting },
                       "the waiting key never goes to Apple")
        XCTAssertEqual(list.current.certified, [first], "the Keychain refused the list")
        let relaunched = relaunch(keys, keyList: list)   // before another pass
        await relaunched.certifyIfNeeded(records: log.map(\.id))
        XCTAssertEqual(list.current.certified, [first, replacement], "the phone's own key joins the list")
        await keys.lose(replacement.base64EncodedString())
        await relaunched.logWritten(generation: 1, events: log)
        XCTAssertEqual(try keyStatements().last?.follows, replacement, "the next key follows it")
    }

    /// deepseek-1 on 424d8ce: with a list holding a key this install made and none it certified (its first key waiting
    /// for Apple, as at a first launch offline), a new key followed the file's last certified key, another install's put
    /// there by an edited backup among them, though the list kept that key off. With a list, a new key follows the
    /// list's last certified key, or none.
    func testAListWithAKeyMadeAndNoneCertifiedLetsNoFileKeyLeadTheNextKey() async throws {
        let list = TestKeyList()
        let (signer, keys, chain) = try makeSigner(keyList: list)
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await signer.certifyIfNeeded(records: [])   // the first key, made and noted, and Apple not answering
        XCTAssertEqual(list.current.certified, [])
        XCTAssertEqual(list.current.made.count, 1)
        // The edited backup, restored: the phone's waiting key taken out of the file, another install's key put in.
        let stranger = try await certifiedKeyEntries(FakeKeyService(chain: chain))
        let strangerKey = try XCTUnwrap(stranger.first?.key)
        try rewrite(stranger)
        let restored = relaunch(keys, keyList: list)
        await restored.logWritten(generation: 1, events: [event(1)])   // App Attest refuses the stranger's key: a new key
        let next = try XCTUnwrap(try keyStatements().last)
        XCTAssertNotEqual(next.keyID, strangerKey, "a new key")
        XCTAssertNil(next.follows, "no key the file lists leads this phone's next key")
        XCTAssertEqual(list.current.certified, [next.keyID], "the stranger's key never joins the list")
    }

    /// codex-2 on 424d8ce: a pass that could not read the file and the list (the Keychain not readable yet) kept nothing of
    /// the log it was given, so when they could be read, at the app coming forward, nothing compared it: the line saying
    /// signatures are missing, and Share, waited for another write of the log. The write a pass could not compare is
    /// compared as soon as they can be read.
    func testAWriteAPassCouldNotCompareIsComparedWhenTheAppComesForward() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        list.failNextReads(4)
        let lines = LineWriter()
        await restored.heardTheLogRead([a.id])
        await restored.writeLines(with: lines.write)
        await restored.certifyIfNeeded(records: [a.id])
        await restored.logWritten(generation: 1, events: [a])   // each of the four: the Keychain cannot be read yet
        XCTAssertEqual(lines.written, [])
        await restored.certifyIfNeeded(records: [a.id])   // the app comes forward, the Keychain readable, no other write
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The same when the log the launch read is what comes once they can be read (codex-2 on 424d8ce).
    func testAWriteAPassCouldNotCompareIsComparedWhenTheLaunchsLogComes() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        list.failNextReads(2)
        let lines = LineWriter()
        await restored.writeLines(with: lines.write)
        await restored.logWritten(generation: 1, events: [a])
        await restored.heardTheLogRead([a.id])
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The same when the engine's writer of lines is what comes once they can be read (codex-2 on 424d8ce).
    func testAWriteAPassCouldNotCompareIsComparedWhenTheWriterOfLinesComes() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        list.failNextReads(2)
        let lines = LineWriter()
        await restored.heardTheLogRead([a.id])
        await restored.logWritten(generation: 1, events: [a])
        await restored.writeLines(with: lines.write)
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// The same when Share's question is what comes once they can be read (codex-2 on 424d8ce).
    func testAWriteAPassCouldNotCompareIsComparedWhenShareAsks() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        list.failNextReads(3)
        let lines = LineWriter()
        await restored.heardTheLogRead([a.id])
        await restored.writeLines(with: lines.write)
        await restored.logWritten(generation: 1, events: [a])
        _ = await restored.canExport(a.id)
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// codex-2 on 424d8ce (a): the keys the file lost are dealt with at the first read of the file and the list, though
    /// no write of the log has come: the file says signatures are missing, and the line waits only for a write.
    func testTheKeysTheFileLostAreDealtWithAtTheFirstRead() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        let lost = try XCTUnwrap(list.current.certified.first)
        list.failNextReads(1)
        await restored.heardTheLogRead([a.id])   // the Keychain cannot be read yet: the decision waits for the file
        await restored.certifyIfNeeded(records: [a.id])   // the app comes forward: read now, and no write of the log yet
        XCTAssertTrue(try XCTUnwrap(file.read()).contains { $0.kind == .historyMissing }, "dealt with at the read")
        XCTAssertEqual(list.current.accounted, [lost])
    }

    /// A write a pass kept is never compared after a newer one, which replaces it: a record signed since is never named
    /// gone by the older log (codex-2 on 424d8ce; the undo check's need).
    func testAKeptWriteIsNeverComparedAfterANewerOne() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        list.failNextReads(1)
        let relaunched = relaunch(keys, keyList: list)
        await relaunched.logWritten(generation: 1, events: [a])   // the Keychain cannot be read yet: kept
        let b = event(2)
        await relaunched.logWritten(generation: 2, events: [b, a])   // read now: `b` signed
        await relaunched.certifyIfNeeded(records: [b.id, a.id])   // the app comes forward
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { entry in
            guard let bytes = entry.statement, case .absence? = try? EvidenceForm.read(bytes) else { return false }
            return true
        }, "no record named gone by the older log")
    }

    /// The keys the file lost, the file refusing their line at its read (a full disk), are dealt with at the next pass
    /// (codex-2 on 424d8ce; the undo check's need).
    func testTheKeysTheFileLostAreDealtWithAtTheNextPassWhenTheReadCouldNot() async throws {
        let list = TestKeyList()
        let (restored, a) = try await relaunchAfterTheFileWasLost(list)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.url.path, contents: Data()))
        try setFileWritable(false)   // read, but taking no line
        let lines = LineWriter()
        await restored.writeLines(with: lines.write)
        await restored.heardTheLogRead([a.id])
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.kind == .historyMissing }, "the file took no line")
        try setFileWritable(true)
        await restored.logWritten(generation: 1, events: [a])
        XCTAssertEqual(lines.written, [Event.signaturesMissingKind])
    }

    /// With the list, a key this install made and noted, which Apple did not answer, is tried again with the same
    /// statement after a relaunch, as without it (codex-1 on 424d8ce).
    func testAKeyThisInstallMadeIsTriedAgainWithItsStatement() async throws {
        let list = TestKeyList()
        let (signer, keys, _) = try makeSigner(keyList: list)
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await signer.certifyIfNeeded(records: [])
        await relaunch(keys, keyList: list).certifyIfNeeded(records: [])
        let requests = await keys.attestRequests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Set(requests.map(\.key)).count, 1, "the same key")
        XCTAssertEqual(Set(requests.map(\.hash)).count, 1, "the same statement")
        XCTAssertEqual(list.current.certified.count, 1)
    }

    /// A launch after an edited backup lost the signature file, its one record signed and its key named on the list.
    private func relaunchAfterTheFileWasLost(_ list: TestKeyList) async throws -> (EvidenceSigner, Event) {
        let (signer, keys, _) = try makeSigner(keyList: list)
        await signer.certifyIfNeeded(records: [])
        let a = event(1)
        await signer.logWritten(generation: 1, events: [a])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        try FileManager.default.removeItem(at: file.url)
        return (relaunch(keys, keyList: list), a)
    }

    // MARK: - Codex's change review of 63e77b0 (item 190, round 190E; the owner, 2026-11-03: "codex-1 a, codex-2 a")

    /// codex-1 on 63e77b0: a waiting key the list noted as made here went to Apple with the statement it was saved with,
    /// so one a round 190C build saved following another install's key (put in an edited backup's file while the list
    /// held a key made and none certified, deepseek-1's path) was certified as saved, and the chain ran through that
    /// key. A waiting key goes to Apple as saved only when its statement names it and follows the list's last certified
    /// key, or none; otherwise a fresh key, noted first, takes its place.
    func testAWaitingKeyWhoseStatementFollowsAKeyTheListDoesNotNameIsNeverCertified() async throws {
        let list = TestKeyList()
        let (_, keys, chain) = try makeSigner(keyList: list)
        let stranger = try await certifiedKeyEntries(FakeKeyService(chain: chain))
        let strangerKey = try XCTUnwrap(stranger.first?.key)
        // That build's state: the stranger's key, lost here, and the key the build made after it, noted and waiting.
        let made = try await keys.generateKey()
        let waiting = try XCTUnwrap(Data(base64Encoded: made))
        let statement = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: waiting, signedAt: 1_793_000_000_000,
                                                                          app: "1.10 (82)", follows: strangerKey)))
        for entry in stranger + [EvidenceSignatureFile.Entry(kind: .keyLost, key: strangerKey, at: signedAt),
                                 EvidenceSignatureFile.Entry(kind: .keyPending, key: waiting, statement: statement)] {
            XCTAssertTrue(file.append(entry))
        }
        list.set(EvidenceKeyList(certified: [], made: [Data(repeating: 7, count: 32), waiting]))
        await relaunch(keys, keyList: list).certifyIfNeeded(records: [])
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.kind == .keyCertified && $0.key == waiting },
                       "never certified as saved")
        let next = try XCTUnwrap(try keyStatements().last)
        XCTAssertNotEqual(next.keyID, waiting, "a fresh key")
        XCTAssertNil(next.follows, "following no key the list does not name")
        XCTAssertEqual(list.current.certified, [next.keyID])
    }

    /// The same for a waiting key whose statement names another key (codex-1 on 63e77b0): never sent as saved.
    func testAWaitingKeyWhoseStatementNamesAnotherKeyIsNeverCertified() async throws {
        let list = TestKeyList()
        let (_, keys, _) = try makeSigner(keyList: list)
        let made = try await keys.generateKey()
        let waiting = try XCTUnwrap(Data(base64Encoded: made))
        let statement = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: Data(repeating: 9, count: 32),
                                                                          signedAt: 1_793_000_000_000, app: "1.10 (82)",
                                                                          follows: nil)))
        XCTAssertTrue(file.append(EvidenceSignatureFile.Entry(kind: .keyPending, key: waiting, statement: statement)))
        list.set(EvidenceKeyList(certified: [], made: [waiting]))
        await relaunch(keys, keyList: list).certifyIfNeeded(records: [])
        XCTAssertFalse(try XCTUnwrap(file.read()).contains { $0.kind == .keyCertified && $0.key == waiting },
                       "never certified as saved")
        XCTAssertEqual(try keyStatements().last?.keyID, list.current.certified.first, "a fresh key, certified")
    }

    // MARK: - Codex's change review of eaac8b96 (item 182; the owner, 2026-11-01: "go on the fixes, codex-1 a, codex-2 a")

    /// codex-1 (the owner's "a"): the limit's removal of a row under incident x's ID that was not x (a status entry, as
    /// when an edited log makes x one) does not retire x: x is named gone, its signatures kept.
    func testTheLimitsRemovalOfAnotherRowUnderARecordsIDDoesNotRetireIt() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let row = Event(id: x.id, startDate: x.startDate, endDate: x.startDate, triggeredSensors: [], cloudSyncState: .pending,
                        stateChange: "settingsReset")
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(row))
        let entries = try XCTUnwrap(file.read())
        XCTAssertTrue(entries.contains { $0.record == x.id }, "x's signatures kept")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "x named gone")
        XCTAssertEqual(checked.compactMap(retention).count, 0, "x not retired")
    }

    /// codex-1 (the owner's "a"): the same for a row under x's ID with x's kind and another start.
    func testTheLimitsRemovalOfARowWithAnotherStartUnderARecordsIDDoesNotRetireIt() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        let start = x.startDate.addingTimeInterval(1)
        let row = Event(id: x.id, startDate: start, endDate: start, triggeredSensors: [.motion], cloudSyncState: .pending,
                        stateChange: x.stateChange)
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(row))
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "x named gone")
        XCTAssertEqual(checked.compactMap(retention).count, 0, "x not retired")
    }

    /// codex-1 (the owner's "a"), through the app's own log and signing: an edited log that makes signed incident x a
    /// status entry (its ID and start kept), the status entries at their limit, has the limit remove that row at
    /// launch; x is named gone, not retired, its signatures kept.
    func testTheLimitRemovingARowThatReplacedARecordAtLaunchNamesTheRecordGone() throws {
        TestIsolation.setUp(folderPrefix: "Item182ReplacedEvicted")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        let row = Event(id: x.id, startDate: x.startDate, endDate: x.startDate, triggeredSensors: [], cloudSyncState: .pending,
                        stateChange: "settingsReset")
        let pool = (2...(EventStore.maxAuditEvents + 1)).map { statusEvent($0) }   // each newer than x: its row the oldest
        try JSONEncoder().encode(pool.reversed() + [row]).write(to: try logURL())
        let relaunched = EventStore()
        XCTAssertFalse(relaunched.events.contains { $0.id == x.id }, "the limit removed the row")
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { namesGone([x.id], in: appFile, chain) }, timeout: 5), "x named gone")
        XCTAssertTrue(appFile.read()?.contains { $0.record == x.id } == true, "x's signatures kept")
        XCTAssertFalse(underCertifiedKeys(appFile.read() ?? [], chain).contains(where: isRetention), "x not retired")
        withExtendedLifetime(signing) {}
    }

    /// codex-1 (the owner's "a"): the limit keeps what each row it removed was (its start and kind), on disk with the
    /// removals, and the next launch reads it back.
    func testTheLimitsRemovalsKeepWhatEachRemovedRowWas() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalIdentity")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let oldest = statusEvent(0)
        store.add(oldest)
        for minute in 1...EventStore.maxAuditEvents { store.add(statusEvent(minute)) }
        store.drainIOForTesting()
        XCTAssertEqual(store.limitRemovalsAsRemoved, [oldest.id: oldest.evidenceIdentity])
        XCTAssertEqual(EventStore().limitRemovalsAsRemoved, [oldest.id: oldest.evidenceIdentity], "read back at launch")
    }

    /// codex-1 (the owner's "a"): a launch reads back from the removals' file what each removed row was, with neither the
    /// log nor the journal holding the row (the test above meets its row again through the journal's recovery).
    func testTheRemovalsFileReadsBackWhatEachRemovedRowWas() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalsReadBack")
        defer { TestIsolation.tearDown() }
        let key = try XCTUnwrap(EventStore.limitRemovalsKey(create: true))
        let removed = [UUID(): RecordIdentity(start: 1_793_000_000_000, kind: "settingsReset"),
                       UUID(): RecordIdentity(start: 1_793_000_060_000, kind: nil),
                       UUID(): RecordIdentity(start: 1_793_000_120_000, kind: nil, interrupted: true)]
        try EventStore.limitRemovalsData(removed, key: key).write(to: try removalsURL())
        XCTAssertEqual(EventStore().limitRemovalsAsRemoved, removed)
    }

    /// codex-2 (the owner's "a"): the line is written at its absence statement's time, so a line written again after an
    /// edited restore lost it and its note is the line as signed: the log holds it, and its note is written.
    func testALineWrittenAgainIsTheLineAsSigned() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        await signer.logWritten(generation: 2, events: [b])   // x gone: its line handed over
        let line = try XCTUnwrap(lines.ids.first)
        let statementTime = try XCTUnwrap(try verify(try XCTUnwrap(file.read()), chain).compactMap(absence).first?.signedAt)
        XCTAssertEqual(lines.at(of: line).flatMap(EvidenceForm.milliseconds(since1970:)), statementTime, "at its statement's time")
        await signer.logWritten(generation: 3, events: lines.events + [b])   // the line in the log: noted, and signed
        try rewrite(try XCTUnwrap(file.read()).filter { $0.kind != .absenceLogged })   // an edited restore: the note lost
        let later = TestClock(signedAt.addingTimeInterval(3_600))
        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.10 (81)", now: { later.now },
                                        retryAfter: 0)
        let again = LineWriter()
        await relaunched.writeLines(with: again.write)
        await relaunched.logWritten(generation: 1, events: [b])   // the line, lost with its row, owed again
        XCTAssertEqual(again.at(of: line), lines.at(of: line), "written again at its statement's time")
        await relaunched.logWritten(generation: 2, events: again.events + [b])
        XCTAssertTrue(file.read()?.contains { $0.kind == .absenceLogged && $0.records == [x.id] } == true, "its note written")
    }

    /// codex-2 (the owner's "a"): the line's text comes from its absence statement too (its records' count and starts as
    /// the statement names them), so the line written again is the line as signed even when an edited restore lost its
    /// record's own signatures with its note.
    func testALineWrittenAgainKeepsItsTextWithoutItsRecordsSignatures() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let lines = LineWriter()
        await signer.writeLines(with: lines.write)
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        await signer.logWritten(generation: 2, events: [b])   // x gone: its line handed over
        let line = try XCTUnwrap(lines.ids.first)
        await signer.logWritten(generation: 3, events: lines.events + [b])   // the line in the log: noted, and signed
        try rewrite(try XCTUnwrap(file.read()).filter { $0.kind != .absenceLogged && $0.record != x.id })   // the restore
        let relaunched = relaunch(keys)
        let again = LineWriter()
        await relaunched.writeLines(with: again.write)
        await relaunched.logWritten(generation: 1, events: [b])   // the line, lost with its row, owed again
        XCTAssertEqual(again.kind(of: line), lines.kind(of: line), "written again as signed")
        await relaunched.logWritten(generation: 2, events: again.events + [b])
        XCTAssertTrue(file.read()?.contains { $0.kind == .absenceLogged && $0.records == [x.id] } == true, "its note written")
    }

    /// codex-1 on c2202a26 (the owner's "a"): the limit's removal of a row under incident x's ID marked as an
    /// interruption record (which the limit counts with the status entries) is not x's: x is named gone, its signatures
    /// kept.
    func testTheLimitsRemovalOfARowMarkedInterruptedUnderARecordsIDDoesNotRetireIt() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        var row = x
        row.interrupted = true
        await signer.logWritten(generation: 2, events: [b], limitRemoved: removed(row))
        let entries = try XCTUnwrap(file.read())
        XCTAssertTrue(entries.contains { $0.record == x.id }, "x's signatures kept")
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[x.id]], "x named gone")
        XCTAssertEqual(checked.compactMap(retention).count, 0, "x not retired")
    }

    /// codex-1 on c2202a26 (the owner's "a"): an interruption record signed as one is that record while the log holds
    /// it, and the limit's removal of it retires it, never naming it gone.
    func testAnInterruptionRecordSignedAsOneIsItselfAndTheLimitRetiresIt() async throws {
        let (signer, _, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let start = TestApp.date(2026, 10, 31, 1, 3)
        let r = Event(startDate: start, endDate: start, triggeredSensors: [], cloudSyncState: .pending, interrupted: true)
        let b = event(2)
        await signer.logWritten(generation: 1, events: [r, b])
        await signer.logWritten(generation: 2, events: [r, b])
        XCTAssertFalse(namesGone([r.id], in: file, chain), "itself while the log holds it")
        await signer.logWritten(generation: 3, events: [b], limitRemoved: removed(r))
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.compactMap(absence).count, 0, "never named gone")
        XCTAssertEqual(checked.compactMap(retention).count, 1, "retired")
    }

    /// codex-1 on c2202a26 (the owner's "a"), through the app's own log and signing: an edited log that marks signed
    /// incident x as an interruption record (its ID, start and kind kept), the status entries at their limit, has the
    /// limit remove that row at launch; x is named gone, not retired, its signatures kept.
    func testAnEditMarkingARecordInterruptedHasTheLimitNameItGoneAtLaunch() throws {
        TestIsolation.setUp(folderPrefix: "Item182InterruptedEvicted")
        defer { TestIsolation.tearDown() }
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let x = try launchSigningOneRecord(keys)
        var row = x
        row.interrupted = true
        let pool = (2...(EventStore.maxAuditEvents + 1)).map { statusEvent($0) }   // each newer than x: its row the oldest
        try JSONEncoder().encode(pool.reversed() + [row]).write(to: try logURL())
        let relaunched = EventStore()
        XCTAssertFalse(relaunched.events.contains { $0.id == x.id }, "the limit removed the row")
        let signing = EvidenceSigning(store: relaunched, keys: keys, center: NotificationCenter())
        let appFile = EvidenceSignatureFile(url: relaunched.evidenceSignaturesURL)
        XCTAssertTrue(pump(until: { namesGone([x.id], in: appFile, chain) }, timeout: 5), "x named gone")
        XCTAssertTrue(appFile.read()?.contains { $0.record == x.id } == true, "x's signatures kept")
        XCTAssertFalse(underCertifiedKeys(appFile.read() ?? [], chain).contains(where: isRetention), "x not retired")
        withExtendedLifetime(signing) {}
    }

    /// codex-1 on c2202a26 (the owner's "a"): a record keeps whether it is an interruption record as signed: an edited log
    /// that marks incident x as one has not got x; x is named gone, and the row is never signed as x's revision.
    func testARowUnderASignedRecordsIDMarkedInterruptedIsNotThatRecord() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let x = event(1), b = event(2)
        await signer.logWritten(generation: 1, events: [b, x])
        var row = x
        row.interrupted = true
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [b, row])
        await relaunched.logWritten(generation: 2, events: [b, row])
        XCTAssertTrue(namesGone([x.id], in: file, chain), "x named gone")
        XCTAssertEqual(try revisions(of: x.id, chain), [1], "the row never signed as x's revision")
    }

    /// codex-2 (the owner's "a"): the engine writes the signer's line at the time the signer gives, its absence
    /// statement's, not the time of writing.
    func testTheEngineWritesTheSignersLineAtTheTimeGiven() throws {
        TestIsolation.setUp(folderPrefix: "Item182LineTime")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let cloud = CloudExfiltrator()
        cloud.accountIdentityForTesting = { nil }   // no account: nothing waits on CloudKit
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: EngineCharacterizationTests.fastTiming))
        let id = UUID(), at = TestApp.date(2026, 10, 31, 3, 0)
        let newer = Event(startDate: at.addingTimeInterval(60), endDate: at.addingTimeInterval(60), triggeredSensors: [],
                          cloudSyncState: .pending, stateChange: "settingsReset")
        store.add(newer)
        engine.logSignerLine(Event.signedRecordsGoneKind(count: 1, first: nil, last: nil), id: id, at: at)
        XCTAssertEqual(store.events.first { $0.id == id }?.startDate, at)
        XCTAssertEqual(store.events.prefix(2).map(\.id), [newer.id, id], "by its time, below the newer row (the clock, on 92bf0605)")
    }

    /// codex-1 on 995f7d98 (the owner's "a"): the journal's recovery puts the rows of this phone's it brings back first,
    /// as they came: a disarm made with the clock set back, its log write lost to a kill, is kept by the next launch, and
    /// the limit takes the log's last entry.
    func testTheJournalsRecoveryPutsWhatItBringsBackFirst() throws {
        TestIsolation.setUp(folderPrefix: "Item182RecoveryFirst")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let early = TestApp.date(2026, 10, 30, 23, 0)   // the clock set back before every entry above
        let disarm = Event(startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                           stateChange: "settingsReset")
        try XCTUnwrap(EventStore.journalLine(for: disarm)).write(to: root.appendingPathComponent("events.journal"))
        let store = EventStore()
        XCTAssertEqual(store.events.first?.id, disarm.id, "brought back first")
        XCTAssertEqual(store.limitRemovals, [entries[0].id], "the log's last entry taken")
        store.drainIOForTesting()
    }

    /// codex-1 on 995f7d98 (the owner's "a"): a row the limit removed after its write landed, its journal line not yet
    /// retired at a kill, is not a write that never landed: the next launch does not bring it back, keeps its removal for
    /// the signer, and retires its line.
    func testTheJournalsRecoveryDoesNotBringBackARowTheLimitRemoved() throws {
        TestIsolation.setUp(folderPrefix: "Item182RecoverySkipsRemoved")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        let removed = entries[0], newest = statusEvent(EventStore.maxAuditEvents + 1)
        try JSONEncoder().encode([newest] + entries.dropFirst().reversed()).write(to: try logURL())   // the limit's write landed
        try writeRemovals([removed.id])                                                                 // before it, its removal
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: removed)).write(to: journal)                          // its line not yet retired
        let store = EventStore()
        XCTAssertFalse(store.events.contains { $0.id == removed.id }, "not brought back")
        XCTAssertEqual(store.limitRemovals, [removed.id], "its removal kept for the signer")
        store.drainIOForTesting()
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == removed.id } } ?? false
        }
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "its line retired")
    }

    /// codex-1 on 995f7d98 (the owner's "a"): a removal stays while its journal line is owed retirement, though the
    /// signer has accounted for it, so a kill before the checkpoint cannot leave the line to bring the row back; it goes
    /// once its line is retired, the signer's account kept.
    func testARemovalStaysWhileItsJournalLineIsOwedRetirement() throws {
        TestIsolation.setUp(folderPrefix: "Item182RemovalWhileLineOwed")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: entries[0])).write(to: journal)
        let store = EventStore()
        store.add(statusEvent(EventStore.maxAuditEvents + 1))   // the limit removes entries[0], its line owed retirement
        store.forgetLimitRemovals([entries[0].id])               // the signer's account, before the checkpoint
        XCTAssertEqual(store.limitRemovals, [entries[0].id], "kept while its line is owed")
        store.drainIOForTesting()
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == entries[0].id } } ?? false
        }
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "its line retired")
        XCTAssertEqual(store.limitRemovals, [], "forgotten once its line is retired")
        store.drainIOForTesting()
    }

    /// codex-1 on 995f7d98 (the owner's "a"): rows the recovery brings back keep the order they came in, the last first,
    /// whatever their times: the clock moved back between them.
    func testTheJournalsRecoveryKeepsTheOrderRowsCameIn() throws {
        TestIsolation.setUp(folderPrefix: "Item182RecoveryOrder")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode([statusEvent(1)]).write(to: try logURL())
        let first = statusEvent(10), second = statusEvent(5)   // the clock moved back between them
        var journal = Data()
        for event in [first, second] { journal.append(try XCTUnwrap(EventStore.journalLine(for: event))) }
        try journal.write(to: root.appendingPathComponent("events.journal"))
        let store = EventStore()
        XCTAssertEqual(store.events.prefix(2).map(\.id), [second.id, first.id], "the last to come in first")
        store.drainIOForTesting()
    }

    /// codex-1 on 995f7d98 (the owner's "a"): a merge with iCloud that changes nothing leaves the log as it was: a row
    /// made with the clock set back stays first, and the next row's limit takes the log's last entry, not it.
    func testAMergeThatChangesNothingLeavesTheLogsOrder() throws {
        TestIsolation.setUp(folderPrefix: "Item182MergeKeepsOrder")
        defer { TestIsolation.tearDown() }
        let store = EventStore()
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        for entry in entries { store.add(entry) }
        let early = TestApp.date(2026, 10, 30, 23, 0)
        let entry = Event(startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                          stateChange: "settingsReset")
        store.add(entry)   // the clock set back: first, the log's last entry taken
        XCTAssertEqual(store.merge([]), 0, "nothing changed")
        XCTAssertEqual(store.events.first?.id, entry.id, "still first")
        store.add(statusEvent(EventStore.maxAuditEvents + 1))
        XCTAssertTrue(store.events.contains { $0.id == entry.id }, "kept")
        XCTAssertEqual(store.limitRemovals, [entries[0].id, entries[1].id], "the log's last entries taken")
        store.drainIOForTesting()
    }

    /// codex-1 on 995f7d98 (the owner's "a"): the unlock keeps what was written while the phone was locked first, as it
    /// came, whatever its time.
    func testTheUnlockKeepsWhatWasWrittenWhileLockedFirst() {
        let disk = (2...4).map { statusEvent($0) }.reversed()
        let queued = Event(startDate: TestApp.date(2026, 10, 30, 23, 0), endDate: TestApp.date(2026, 10, 30, 23, 0),
                           triggeredSensors: [], cloudSyncState: .pending, stateChange: "settingsReset")
        let out = EventStore.reconciledAfterUnlock(disk: Array(disk), queued: [queued])
        XCTAssertEqual(out.map(\.id), [queued.id] + disk.map(\.id))
    }

    /// codex-1 on 995f7d98 (the owner's "a"): an iCloud copy takes its place by its time, below every row newer than it,
    /// and never moves this phone's rows: one made with the clock set back stays first.
    func testAnICloudCopyTakesItsPlaceByItsTimeAndMovesNoRowOfThisPhones() {
        let entries = (1...3).map { statusEvent($0) }
        let early = TestApp.date(2026, 10, 30, 23, 0)
        let backdated = Event(startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                              stateChange: "settingsReset")
        let at = entries[0].startDate.addingTimeInterval(30)
        var copy = Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending, stateChange: "settingsReset")
        copy.sourceDevice = "Another iPhone"
        let out = EventStore.merged(local: [backdated] + entries.reversed(), incoming: [copy])
        XCTAssertEqual(out.map(\.id), [backdated.id, entries[2].id, entries[1].id, copy.id, entries[0].id])
    }

    /// codex-2 on 995f7d98 (the owner's "a"): the journal lines an add's limit owes retirement outlive a write that fails,
    /// and the next write that lands retires them.
    func testJournalLinesOwedRetirementOutliveAFailedWrite() throws {
        TestIsolation.setUp(folderPrefix: "Item182RetireAfterFailedWrite")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: entries[0])).write(to: journal)
        let store = EventStore()
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // the log cannot be replaced
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path) }
        store.add(statusEvent(EventStore.maxAuditEvents + 1))
        XCTAssertEqual(store.limitRemovals, [entries[0].id], "the limit took the oldest")
        store.drainIOForTesting()
        XCTAssertTrue(pump(until: { store.persistDegraded }, timeout: 5), "the write failed")
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: root.path)
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == entries[0].id } } ?? false
        }
        XCTAssertTrue(lineKept(), "kept while the write failed")
        store.flush()
        store.drainIOForTesting()
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "retired once a write lands")
    }

    /// codex-2 on 995f7d98 (the owner's "a"): the same across a checkpoint whose full sync fails.
    func testJournalLinesOwedRetirementOutliveAFailedSync() throws {
        TestIsolation.setUp(folderPrefix: "Item182RetireAfterFailedSync")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: entries[0])).write(to: journal)
        let store = EventStore()
        EventStore.fullSyncFailsForTesting = true
        defer { EventStore.fullSyncFailsForTesting = false }
        store.add(statusEvent(EventStore.maxAuditEvents + 1))
        store.drainIOForTesting()
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == entries[0].id } } ?? false
        }
        let synced = expectation(description: "the checkpoint ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { synced.fulfill() }   // past the checkpoint's 50 ms wait
        wait(for: [synced], timeout: 5)
        store.drainIOForTesting()
        XCTAssertTrue(lineKept(), "kept while the sync failed")
        EventStore.fullSyncFailsForTesting = false
        store.flush()
        store.drainIOForTesting()
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "retired once a checkpoint's sync lands")
    }

    /// codex-1 on 2bbc3574 (the owner's "a"): the journal's recovery places the signer's line by its time, as `add` did,
    /// not first: a line older than a full log's every status entry, its log write lost to a kill, takes no newer entry's
    /// place in the limit.
    func testTheJournalsRecoveryPlacesTheSignersLineByItsTime() throws {
        TestIsolation.setUp(folderPrefix: "Item182RecoveryLineByTime")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let early = TestApp.date(2026, 10, 30, 23, 0)
        let line = Event(id: UUID(), startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        try XCTUnwrap(EventStore.journalLine(for: line)).write(to: root.appendingPathComponent("events.journal"))
        let store = EventStore()
        XCTAssertTrue(store.limitRemovals.isDisjoint(with: entries.map(\.id)), "no newer entry taken in its place")
        XCTAssertNotEqual(store.events.first?.id, line.id, "not first")
        store.drainIOForTesting()
    }

    /// codex-1 on 2bbc3574 (the owner's "a"): the unlock places a signer's line written while the phone was locked by its
    /// time, not first.
    func testTheUnlockPlacesTheSignersLineByItsTime() {
        let disk = Array((2...4).map { statusEvent($0) }.reversed())
        let early = TestApp.date(2026, 10, 30, 23, 0)
        let line = Event(id: UUID(), startDate: early, endDate: early, triggeredSensors: [], cloudSyncState: .pending,
                         stateChange: Event.signedRecordsGoneKind(count: 1, first: nil, last: nil))
        let out = EventStore.reconciledAfterUnlock(disk: disk, queued: [line])
        XCTAssertEqual(out.map(\.id), disk.map(\.id) + [line.id])
    }

    /// codex-2 on 2bbc3574 (the owner's "a"): the rows the limit removes in a pass that waited (an upload ending) owe their
    /// journal lines' retirement too: kept owed across a failed sync, their removal kept while owed though the signer has
    /// accounted for it, both gone once the line is retired, and the next launch does not bring the row back.
    func testADeferredLimitPassOwesItsRowsJournalLines() throws {
        TestIsolation.setUp(folderPrefix: "Item182DeferredRetires")
        defer { TestIsolation.tearDown() }
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = (1...EventStore.maxAuditEvents).map { statusEvent($0) }
        let x = entries[0]
        try JSONEncoder().encode(entries.reversed()).write(to: try logURL())
        let journal = root.appendingPathComponent("events.journal")
        try XCTUnwrap(EventStore.journalLine(for: x)).write(to: journal)
        let store = EventStore()
        func lineKept() -> Bool {
            (try? Data(contentsOf: journal)).map { EventStore.journaledEvents(in: $0).contains { $0.id == x.id } } ?? false
        }
        store.beginUpload(x.id)
        EventStore.fullSyncFailsForTesting = true
        defer { EventStore.fullSyncFailsForTesting = false }
        store.add(statusEvent(EventStore.maxAuditEvents + 1))   // over by one, x's upload running: nothing taken
        XCTAssertEqual(store.limitRemovals, [], "nothing taken while x uploads")
        store.drainIOForTesting()
        let checkpointed = expectation(description: "the checkpoint ran, its sync failing")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { checkpointed.fulfill() }   // past the checkpoint's 50 ms wait
        wait(for: [checkpointed], timeout: 5)
        store.drainIOForTesting()
        XCTAssertTrue(lineKept(), "kept while the sync failed")
        EventStore.fullSyncFailsForTesting = false
        store.endUpload(x.id)   // the limit applies again: x goes
        XCTAssertEqual(store.limitRemovals, [x.id], "the waiting pass took x")
        store.forgetLimitRemovals([x.id])   // the signer's account, before the checkpoint
        XCTAssertEqual(store.limitRemovals, [x.id], "kept while its line is owed")
        store.drainIOForTesting()
        XCTAssertTrue(pump(until: { !lineKept() }, timeout: 5), "its line retired")
        XCTAssertEqual(store.limitRemovals, [], "forgotten once its line is retired")
        store.drainIOForTesting()
        let next = EventStore()
        XCTAssertFalse(next.events.contains { $0.id == x.id }, "the next launch does not bring it back")
        next.drainIOForTesting()
    }
}

/// A key someone editing a backup made, certified by a chain of their own rather than the root a check trusts: it holds for
/// the phone's check at load, which judges no chain, fails a bundle's, and signs whatever it is given at any counter.
private struct ForgedKey {
    let key: P256.Signing.PrivateKey
    let chain: TestAttestationChain
    let statement: Data

    init() throws {
        let key = P256.Signing.PrivateKey()
        self.key = key
        chain = try TestAttestationChain()
        statement = EvidenceForm.bytes(.key(EvidenceForm.KeyStatement(keyID: TestApp.sha256(key.publicKey.x963Representation),
                                                                      signedAt: 0, app: "-", follows: nil)))
    }

    var id: Data { TestApp.sha256(key.publicKey.x963Representation) }

    /// Its key statement as the phone keeps one: with it, every bundle lists the key.
    var pending: EvidenceSignatureFile.Entry { EvidenceSignatureFile.Entry(kind: .keyPending, key: id, statement: statement) }

    /// Its certification, by its own chain.
    func certified(at date: Date) throws -> EvidenceSignatureFile.Entry {
        EvidenceSignatureFile.Entry(kind: .keyCertified, key: id,
                                    attestation: try chain.attestation(for: key, clientDataHash: TestApp.sha256(statement), certifiedAt: date),
                                    existing: [])
    }

    /// An absence statement naming `event`.
    func absence(naming event: Event) -> Data {
        EvidenceForm.bytes(.absence(EvidenceForm.Absence(signedAt: 0, app: "-",
                                                         records: [EvidenceForm.Absent(id: event.id, revision: 1, startDate: nil)])))
    }

    /// A signature of `statement` at `counter`.
    func signature(of statement: Data, counter: UInt32) throws -> EvidenceSignatureFile.Entry {
        EvidenceSignatureFile.Entry(kind: .signature, key: id, statement: statement,
                                    assertion: try TestAttestation.assertion(by: key, formHash: TestApp.sha256(statement), counter: counter))
    }
}

/// A line of the signer's as the engine's `logStateChange` writes it in the event log: a status entry under the ID the
/// signer gives it.
func lineEvent(_ kind: String, _ id: UUID, at: Date = TestApp.date(2026, 10, 31, 3, 0)) -> Event {
    Event(id: id, startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .pending, stateChange: kind)
}

/// The Keychain's list of the keys this install certified, stood in for a test (item 190's A3): held in memory, read and
/// written as the Keychain item is, and never shared with another test.
final class TestKeyList: EvidenceKeyListStore, Sendable {
    private let list = Mutex(EvidenceKeyList())
    private let failing = Mutex((reads: 0, writes: 0, certifying: 0))
    var current: EvidenceKeyList { list.withLock { $0 } }
    func set(_ new: EvidenceKeyList) { list.withLock { $0 = new } }
    /// The next `count` reads answer that the list cannot be read now, as the Keychain does before the phone's first
    /// unlock (item 190's codex-2 on 29d6501).
    func failNextReads(_ count: Int) { failing.withLock { $0.reads = count } }
    /// The next `count` writes fail, the list left as it was (Claude's self-review on round 190B).
    func failNextWrites(_ count: Int) { failing.withLock { $0.writes = count } }
    /// The next `count` writes that add a key to `certified` fail, the list left as it was; others pass (item 190's
    /// deepseek-5 on b7702f5).
    func failNextCertifyingWrites(_ count: Int) { failing.withLock { $0.certifying = count } }
    func read() -> EvidenceKeyList? {
        let fails = failing.withLock { state -> Bool in
            guard state.reads > 0 else { return false }
            state.reads -= 1
            return true
        }
        return fails ? nil : list.withLock { $0 }
    }
    func write(_ new: EvidenceKeyList) -> Bool {
        let certifies = new.certified.count > current.certified.count
        let fails = failing.withLock { state -> Bool in
            if state.writes > 0 {
                state.writes -= 1
                return true
            }
            guard certifies, state.certifying > 0 else { return false }
            state.certifying -= 1
            return true
        }
        guard !fails else { return false }
        list.withLock { $0 = new }
        return true
    }
}

/// What a store told its listener of the log it read (item 190's deepseek-3 on b7702f5).
@MainActor
final class HandedLog {
    var ids: Set<UUID>?
}

/// The event log's lines as the signer hands them to the engine (`logStateChange` in the app), in order, each with the
/// ID the signer gives it; a writer that refuses plays an engine that could not take one.
final class LineWriter: Sendable {
    private let lines = Mutex<[(kind: String, id: UUID, at: Date)]>([])
    private let refusing: Mutex<Bool>
    init(refusing: Bool = false) { self.refusing = Mutex(refusing) }
    var written: [String] { lines.withLock { $0.map(\.kind) } }
    var ids: [UUID] { lines.withLock { $0.map(\.id) } }
    /// The time the line with `id` was written at, as the signer gave it.
    func at(of id: UUID) -> Date? { lines.withLock { $0.first { $0.id == id }?.at } }
    /// The kind of the line with `id`, as written.
    func kind(of id: UUID) -> String? { lines.withLock { $0.first { $0.id == id }?.kind } }
    /// The lines as the event log holds them once written, each at the time the signer gave.
    var events: [Event] { lines.withLock { $0.map { lineEvent($0.kind, $0.id, at: $0.at) } } }
    func refuse(_ refuse: Bool) { refusing.withLock { $0 = refuse } }
    var write: @Sendable (String, UUID, Date) async -> Bool {
        { [self] kind, id, at in
            guard !refusing.withLock({ $0 }) else { return false }
            lines.withLock { $0.append((kind, id, at)) }
            return true
        }
    }
}

/// A writer of lines that holds the first line until released, as an engine slow to take it.
final class HeldLineWriter: Sendable {
    private let kinds = Mutex<[String]>([])
    private let held = Mutex<CheckedContinuation<Void, Never>?>(nil)
    private let first = Mutex(true)
    var written: [String] { kinds.withLock { $0 } }
    /// Whether the first line is being held.
    var holding: Bool { held.withLock { $0 != nil } }
    /// Lets the held line through, and any first line not yet asked for pass without being held.
    func release() {
        first.withLock { $0 = false }
        held.withLock { $0?.resume(); $0 = nil }
    }
    var write: @Sendable (String, UUID, Date) async -> Bool {
        { [self] kind, _, _ in
            if first.withLock({ isFirst in defer { isFirst = false }; return isFirst }) {
                await withCheckedContinuation { continuation in held.withLock { $0 = continuation } }
            }
            kinds.withLock { $0.append(kind) }
            return true
        }
    }
}

/// The owed lines the signer told the store to hold, each time.
final class HeldLines: Sendable {
    private let sets = Mutex<[Set<UUID>]>([])
    var last: Set<UUID>? { sets.withLock { $0.last } }
    var handler: @Sendable (Set<UUID>) -> Void { { [self] ids in sets.withLock { $0.append(ids) } } }
}

/// The limit's removals the signer told the store it accounted for.
final class AccountedRemovals: Sendable {
    private let ids = Mutex<Set<UUID>>([])
    var all: Set<UUID> { ids.withLock { $0 } }
    var handler: @Sendable (Set<UUID>) -> Void { { [self] new in ids.withLock { $0.formUnion(new) } } }
}

/// Whether the removals' file named a removal when each log without it was written (read on the store's file queue).
final class RemovalsSeenAtLogWrites: Sendable {
    private let seen = Mutex<[Bool]>([])
    var all: [Bool] { seen.withLock { $0 } }
    func note(_ listed: Bool) { seen.withLock { $0.append(listed) } }
}

/// The lines the app's signing hands the engine, on the main actor.
@MainActor
final class LoggedLines {
    var kinds: [String] = []
}

/// A clock a test moves by hand, read from the signer's executor.
final class TestClock: Sendable {
    private let value: Mutex<Date>
    init(_ start: Date) { value = Mutex(start) }
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}
