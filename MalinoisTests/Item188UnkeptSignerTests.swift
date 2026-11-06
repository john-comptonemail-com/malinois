//
//  Item188UnkeptSignerTests.swift
//  MalinoisTests
//
//  BACKLOG item 188 (item 192's step 1; ADR 0073, accepted with the format "A"): the phone names the signatures App
//  Attest made and its file did not keep. At a signature whose counter is more than one past the highest its key's file
//  accounts for, the counters between are named in a signed unkept statement in the same pass; a hole among the key in
//  use's counters at load (a build before this one) is named once; an earlier key's never. A line the file refused after
//  App Attest made its signature (a full disk) is held and written first at the next pass, before any new signature, so
//  only a stop of the app leaves a gap. An export whose own statement reveals a gap signs the unkept statement after it
//  and then a second export statement, which the bundle carries. App Attest is played by the test stand-in, which counts
//  a signature it makes whether or not the file keeps its line. Written before the code, red at that commit (against
//  compile-only stubs).
//

import CryptoKit
import DeviceCheck
import Synchronization
import XCTest
@testable import Malinois

/// What a signer hands the phone's log (item 206). A test cannot read the log itself.
final class WarningsLogged: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    var handler: @Sendable (String) -> Void { { [self] line in lines.withLock { $0.append(line) } } }
}

@MainActor
final class Item188UnkeptSignerTests: XCTestCase {

    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item188Signer-\(UUID().uuidString)")
    nonisolated private var media: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    nonisolated private var out: URL { folder.appendingPathComponent("Out", isDirectory: true) }
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }
    private let signedAt = TestApp.date(2026, 11, 4, 2, 0)

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // The folder and the file writable again, so a test that stopped with them read-only is cleaned up too.
        let manager = FileManager.default
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        try? manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.appendingPathComponent(EvidenceSignatureFile.name).path)
        try? manager.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - A signature made and not kept

    /// ADR 0073's tests: a stop between an assertion and its line (the stand-in counting the assertion). The key's next
    /// signature shows the gap, and the same pass names it.
    func testAStopBetweenASignatureAndItsLineIsNamedAtTheKeysNextSignature() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])                                         // 1
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second, first]) }   // 2: not kept
        // The app stops before its next pass: what it held of the line goes with it.
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [third, second, first])   // third at 3, the statement at 4, second at 5
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4, 5])
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2]], "one statement naming the counter not kept")
        XCTAssertEqual(unkeptStatements(checked).first?.app, "1.11 (83)")
        XCTAssertEqual(at(checked, 2).map(isUnkept), true, "right after the signature that showed the gap")
        let sequence = try keySequence(checked)
        XCTAssertEqual(sequence.unkept, [2...2])
        XCTAssertEqual(sequence.missing, [])
        XCTAssertEqual(try revisions(of: second.id, chain), [1], "the record signed again, once")
        // Named once: later passes and launches name it no more.
        await relaunched.logWritten(generation: 2, events: [third, second, first])
        await relaunch(keys).logWritten(generation: 1, events: [third, second, first])
        XCTAssertEqual(unkeptStatements(try verify(try XCTUnwrap(file.read()), chain)).count, 1)
    }

    /// ADR 0073's consequences: a bundle made once the gap is named checks out, the gap accounted for as made and not
    /// kept, and the bundle names the second format.
    func testABundleMadeAfterTheGapIsNamedChecksOut() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second, first]) }
        let relaunched = relaunch(keys)
        let log = [third, second, first]
        await relaunched.logWritten(generation: 1, events: log)
        let made = try await exporter(relaunched).folder(of: first, log: log, in: out)
        let bundle = try XCTUnwrap(made)
        let report = try check(bundle, chain)
        XCTAssertEqual(report.signatures.compactMap(\.problem), [])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.sequences.first?.unkept, [2...2])
        XCTAssertEqual(report.export?.record, first.id)
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.unnamed, [], "the export names the unkept statement, shown in full")
        XCTAssertTrue(report.signatures.contains { $0.entry.map(isUnkept) == true }, "the unkept statement in full")
        XCTAssertEqual(report.problems, [])
        XCTAssertTrue(try indexText(bundle).hasPrefix(#"{"format":"malinois-evidence-bundle/2","#))
        // A bundle with no unkept statement stays in the first format: another phone's, in a folder of its own.
        let (plainSigner, _, _) = try makeSigner(in: "plain")
        await plainSigner.certifyIfNeeded(records: [])
        await plainSigner.logWritten(generation: 1, events: [first])
        let plainOut = folder.appendingPathComponent("OutPlain", isDirectory: true)
        try FileManager.default.createDirectory(at: plainOut, withIntermediateDirectories: true)
        let madePlain = try await exporter(plainSigner).folder(of: first, log: [first], in: plainOut)
        let plain = try XCTUnwrap(madePlain)
        XCTAssertTrue(try indexText(plain).hasPrefix(#"{"format":"malinois-evidence-bundle/1","#))
    }

    // MARK: - A count that went back (item 205)

    /// TestFlight 84: a forced restart took App Attest's count back by two, and it gave those counters out again for other
    /// statements, so the file held two signatures on each and every later bundle of the key ended in "counters repeated". One it
    /// gives out again is thrown away and asked for again: no counter is kept twice, and none goes missing.
    func testACounterAppAttestGivesOutAgainIsThrownAway() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3), fourth = trip(4)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        let key = try keyID(try XCTUnwrap(file.read()))
        await keys.rollBackCount(of: key.base64EncodedString(), by: 2)
        let logged = WarningsLogged()
        let relaunched = relaunch(keys, logging: logged)
        let asked = await keys.assertionRequests
        await relaunched.logWritten(generation: 1, events: [fourth, third, second, first])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2, 3, 4], "the fourth record kept past the others")
        let requests = await keys.assertionRequests
        XCTAssertEqual(requests - asked, 3, "counters 2 and 3 thrown away, 4 kept")
        XCTAssertEqual(logged.all, [thrownAwayLine(2)], "the phone's log says how many")
        let sequence = try keySequence(checked)
        XCTAssertEqual(sequence.repeated, [])
        XCTAssertEqual(sequence.missing, [])
        XCTAssertEqual(unkeptStatements(checked).count, 0, "every counter is accounted for: nothing to name")
    }

    /// The export is the first signature after the count went back: its counter must pass every other, or the bundle would hold
    /// a repeat, and signatures after its export.
    func testAnExportRightAfterTheCountWentBackChecksOut() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        let key = try keyID(try XCTUnwrap(file.read()))
        await keys.rollBackCount(of: key.base64EncodedString(), by: 1)
        let relaunched = relaunch(keys)
        let log = [second, first]
        await relaunched.logWritten(generation: 1, events: log)
        let made = try await exporter(relaunched).folder(of: first, log: log, in: out)
        let report = try check(try XCTUnwrap(made, "a bundle"), chain)
        XCTAssertEqual(report.sequences.first?.repeated, [])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.problems, [])
    }

    /// Guard: on the normal path App Attest is asked once for each signature, and none is thrown away.
    func testAnOrdinarySignatureAsksAppAttestOnce() async throws {
        let logged = WarningsLogged()
        let (signer, keys, chain) = try makeSigner(logging: logged)
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        let asked = await keys.assertionRequests
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        let requests = await keys.assertionRequests
        XCTAssertEqual(requests - asked, 2)
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1, 2])
        XCTAssertEqual(logged.all, [], "nothing thrown away, so no line")
    }

    /// Guard: an assertion no counter can be read from says nothing about the count, so it is not asked for again: it goes to the
    /// file as it always did, and a check finds it.
    func testAnAssertionWithNoCounterIsNotAskedForAgain() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        await keys.giveUnreadableAssertions()
        let asked = await keys.assertionRequests
        await signer.logWritten(generation: 2, events: [second, first])
        let requests = await keys.assertionRequests
        XCTAssertEqual(requests - asked, 1)
    }

    /// A count that does not rise cannot be waited out: the asking stops at 64, nothing is kept, and the record waits for a later
    /// write, which signs it once the count moves. The phone's log says what was thrown away when the asking stops, not only when a
    /// signature is kept after it (item 206's Codex-3).
    func testACountThatDoesNotRiseStopsTheAskingAndTheRecordWaits() async throws {
        let logged = WarningsLogged()
        let (signer, keys, chain) = try makeSigner(logging: logged)
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        let key = try keyID(try XCTUnwrap(file.read()))
        await keys.rollBackCount(of: key.base64EncodedString(), by: 1)
        await keys.holdCount(true)
        let asked = await keys.assertionRequests
        await signer.logWritten(generation: 2, events: [second, first])
        let requests = await keys.assertionRequests
        XCTAssertEqual(requests - asked, 64, "it asked again, and stopped at the limit")
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1], "nothing kept on a counter already given")
        XCTAssertEqual(logged.all, [thrownAwayLine(64)], "the asking ran out, and the log says so")
        await keys.holdCount(false)
        await signer.logWritten(generation: 3, events: [second, first])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1, 2], "the next write signs it, past the last")
        XCTAssertEqual(logged.all, [thrownAwayLine(64), thrownAwayLine(1)], "that pass threw away one more")
    }

    /// Item 206's Codex-3: App Attest failing after a signature was thrown away leaves the same way as the asking running out. The
    /// phone's log still says what was thrown away.
    func testAnErrorAfterAThrowAwayIsStillInThePhonesLog() async throws {
        let logged = WarningsLogged()
        let (signer, keys, chain) = try makeSigner(logging: logged)
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        let key = try keyID(try XCTUnwrap(file.read()))
        await keys.rollBackCount(of: key.base64EncodedString(), by: 1)
        await keys.failNextAssertions([DCError(.serverUnavailable)], after: 1)
        await signer.logWritten(generation: 2, events: [second, first])
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1], "nothing kept")
        XCTAssertEqual(logged.all, [thrownAwayLine(1)])
    }

    /// Item 206's Codex-2, the limit SECURITY.md states: the phone stops after App Attest made a signature, and the count goes back
    /// over it. The next signature takes that counter again, above all the file holds, so nothing is thrown away, no gap shows, and
    /// nothing ever names the signature lost. The phone cannot know: a bundle accounts for the counter, not for the signature.
    func testACountThatGoesBackOverALostSignatureLeavesNoGapAndNoLine() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])                                                  // 1
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second, first]) }    // 2: held, then the stop
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1])
        let key = try keyID(try XCTUnwrap(file.read()))
        await keys.rollBackCount(of: key.base64EncodedString(), by: 1)
        let logged = WarningsLogged()
        let relaunched = relaunch(keys, logging: logged)
        await relaunched.logWritten(generation: 1, events: [second, first])                                      // 2 again
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2])
        XCTAssertEqual(checked.map(recordID), [first.id, second.id])
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 3, "the one lost, and made again")
        XCTAssertEqual(unkeptStatements(checked).count, 0, "no gap, so nothing to name")
        XCTAssertEqual(try keySequence(checked).missing, [])
        XCTAssertEqual(logged.all, [], "nothing thrown away, so no line, though the count went back")
    }

    // MARK: - A line the file refused

    /// ADR 0073's tests: a full disk at the append. The line is held and written first at the next pass, so no counter
    /// is lost, and nothing is signed again.
    func testALineTheFileRefusedIsWrittenFirstAtTheNextPassLeavingNoGap() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])                                         // 1
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second, first]) }   // 2: held
        XCTAssertEqual(try verify(try XCTUnwrap(file.read()), chain).map(\.counter), [1])
        await signer.logWritten(generation: 3, events: [third, second, first])       // the held line first, then third at 3
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2, 3], "in App Attest's order")
        XCTAssertEqual(checked.map(recordID), [first.id, second.id, third.id])
        XCTAssertEqual(unkeptStatements(checked).count, 0, "no gap to name")
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 3, "the held signature not made again")
        XCTAssertEqual(try keySequence(checked).missing, [])
    }

    /// The record changed before the next pass: the held revision is written first, then the new one after it.
    func testAHeldRevisionComesBeforeTheRecordsNextRevision() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), unchanged = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [unchanged, first]) }
        var second = unchanged
        second.ownerAttributed = true
        await signer.logWritten(generation: 3, events: [second, first])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2, 3])
        XCTAssertEqual(try revisions(of: second.id, chain), [1, 2])
        XCTAssertEqual(unkeptStatements(checked).count, 0)
    }

    /// A retention statement's line held: written at the next pass with what it retires, the records' signatures leaving
    /// the file and the store told, and no second statement signed.
    func testAHeldRetentionStatementRetiresItsRecordsWhenWritten() async throws {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let accounted = AccountedRemovals()
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.11 (83)", now: { [signedAt] in signedAt },
                                    retryAfter: 0, removalsAccounted: accounted.handler)
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])                       // 1
        await signer.logWritten(generation: 2, events: [second, first])               // 2
        let removal = [first.id: first.evidenceIdentity]
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 3, events: [second], limitRemoved: removal) }  // 3
        XCTAssertFalse(accounted.all.contains(first.id), "not accounted for while its statement's line is held")
        await signer.logWritten(generation: 4, events: [second], limitRemoved: removal)
        let entries = try XCTUnwrap(file.read())
        let checked = try verify(entries, chain)
        XCTAssertEqual(checked.map(\.counter), [2, 3], "first's signature retired and gone from the file")
        XCTAssertEqual(checked.compactMap(retention).map(\.retired), [[EvidenceForm.Retired(keyID: try keyID(entries), counters: [1...1])]])
        XCTAssertTrue(accounted.all.contains(first.id), "the store told")
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 3, "no second retention statement")
        XCTAssertEqual(unkeptStatements(checked).count, 0)
    }

    /// An absence statement's line held: written at the next pass, its record named gone once, and the store told the
    /// event log's line is owed, so its limit keeps the line until it is noted.
    func testAHeldAbsenceStatementNamesItsRecordOnce() async throws {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let owed = AccountedRemovals()   // collects every set of lines the store is told are owed
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.11 (83)", now: { [signedAt] in signedAt },
                                    retryAfter: 0, linesOwedChanged: owed.handler)
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [second, first])
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second]) }   // first gone: 3, held
        await signer.logWritten(generation: 3, events: [second])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2, 3])
        XCTAssertEqual(checked.compactMap(absence).map { $0.records.map(\.id) }, [[first.id]])
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 3, "no second absence statement")
        let statement = try XCTUnwrap(checked.compactMap(absence).first)
        XCTAssertTrue(owed.all.contains(EvidenceSigner.lineID(for: EvidenceForm.bytes(.absence(statement)))), "the store told its line is owed")
    }

    // MARK: - An export that reveals a gap

    /// ADR 0073, decision 4: the export statement's own counter shows a gap; the unkept statement follows it, then a second
    /// export statement, which the bundle carries; the first stays in the file, shown as its hash.
    func testAnExportThatRevealsAGapNamesItAndTheBundleCarriesASecondExport() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1)
        await signer.logWritten(generation: 1, events: [first])                                         // 1
        // A share whose export statement's line the file refused, then a stop: counter 2 made and not kept.
        try await refuseTheNextLine(keys) { _ = await signer.export(of: first.id, showing: [first.id]) }
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [first])                  // nothing to sign
        let before = await keys.assertionRequests
        XCTAssertEqual(before, 2)
        let made = try await exporter(relaunched).folder(of: first, log: [first], in: out)
        let bundle = try XCTUnwrap(made)
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4, 5], "the export at 3, the statement at 4, the second export at 5")
        XCTAssertEqual(checked.map(isExport), [false, true, false, true])
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2]])
        let report = try check(bundle, chain)
        XCTAssertEqual(report.signatures.compactMap(\.problem), [])
        XCTAssertEqual(report.signatures.last?.entry?.counter, 5, "the bundle's last signature: the second export")
        XCTAssertNotNil(report.export)
        XCTAssertNil(at(report.signatures, 1)?.entry?.statement, "the first export shown as its hash")
        XCTAssertEqual(report.sequences.first?.unkept, [2...2])
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.afterExport, [])
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.unnamed, [])
        XCTAssertEqual(report.problems, [])
    }

    /// Item 193's codex-1 (the owner's "a"): the export statement's own counter shows a gap, and App Attest refuses the
    /// statement naming it: no bundle, as no bundle goes out that would end its check in a problem the phone knows of; the
    /// next share names the gap before its export statement.
    func testAnExportWhoseGapCannotBeNamedMakesNoBundleAndTheNextShareNamesItFirst() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1)
        await signer.logWritten(generation: 1, events: [first])                                         // 1
        try await refuseTheNextLine(keys) { _ = await signer.export(of: first.id, showing: [first.id]) }   // 2: not kept
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [first])
        await keys.failNextAssertions([DCError(.serverUnavailable)], after: 1)   // the export's signature made, the statement's refused
        let refused = try await exporter(relaunched).folder(of: first, log: [first], in: out)
        XCTAssertNil(refused, "no bundle while the gap the export showed is not named")
        let made = try await exporter(relaunched).folder(of: first, log: [first], in: out)
        let bundle = try XCTUnwrap(made, "the next share has its bundle")
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4, 5], "the first export at 3, the statement at 4, the next export at 5")
        XCTAssertEqual(checked.map(isExport), [false, true, false, true])
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2]])
        let report = try check(bundle, chain)
        XCTAssertEqual(report.signatures.last?.entry?.counter, 5)
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.unshown, [])
        XCTAssertEqual(report.unnamed, [])
        XCTAssertEqual(report.problems, [])
    }

    /// Item 193's codex-1: the statement naming the gap made, its line refused (as on a full disk): no bundle while it is
    /// held; the next share writes it first, then its export statement.
    func testAnExportWhoseGapsStatementIsHeldMakesNoBundleAndTheNextShareWritesItFirst() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1)
        await signer.logWritten(generation: 1, events: [first])                                         // 1
        try await refuseTheNextLine(keys) { _ = await signer.export(of: first.id, showing: [first.id]) }   // 2: not kept
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [first])
        let place = out
        try await refuseTheNextLine(keys, after: 1) {                    // the export's line kept (3), the statement's held (4)
            _ = try? await self.exporter(relaunched).folder(of: first, log: [first], in: place)
        }
        let name = EvidenceExporter.bundleName(for: first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent(name).path), "no bundle while it is held")
        let made = try await exporter(relaunched).folder(of: first, log: [first], in: out)
        let bundle = try XCTUnwrap(made, "the next share has its bundle")
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4, 5], "the held statement written first, then the next export")
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2]])
        let report = try check(bundle, chain)
        XCTAssertEqual(report.signatures.last?.entry?.counter, 5)
        XCTAssertEqual(report.sequences.first?.missing, [])
        XCTAssertEqual(report.problems, [])
    }

    /// A gap already known when the share comes (a hole found at load) is named before the export statement: one export.
    func testAGapKnownBeforeAnExportIsNamedBeforeItsStatement() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)
        let relaunched = relaunch(keys)
        let made = try await exporterAfterAPassThatCannotSign(relaunched, log: [third, first], first: first)
        let bundle = try XCTUnwrap(made)
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4, 5])
        XCTAssertEqual(checked.map(isExport), [false, false, false, true], "one export, after the statement")
        XCTAssertEqual(try check(bundle, chain).sequences.first?.missing, [])
    }

    // MARK: - Which key, and when

    /// ADR 0073, decision 2: an earlier key's holes stay missing: its entries came through a backup someone could have
    /// edited. The key that follows it names nothing of it.
    func testAnEarlierKeysGapIsNeverNamed() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3), fourth = trip(4)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)                                               // a hole under the first key
        let earlier = try keyID(try XCTUnwrap(file.read()))
        await keys.lose(earlier.base64EncodedString())                                 // a restore from a backup
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [fourth, third, first])     // the key lost: a new one
        await relaunched.logWritten(generation: 2, events: [fourth, third, first])     // fourth signed with it
        await relaunched.logWritten(generation: 3, events: [fourth, third, first])
        let entries = try XCTUnwrap(file.read())
        let certified = entries.filter { $0.kind == .keyCertified }.compactMap(\.key)
        XCTAssertEqual(certified.count, 2, "a new key")
        let checked = try verify(entries, chain)
        XCTAssertTrue(checked.contains { $0.keyID == certified[1] && recordID($0) == fourth.id }, "the new key signs")
        XCTAssertEqual(unkeptStatements(checked).count, 0, "neither key names the first key's hole")
        let followers = Set([certified[1]])
        XCTAssertEqual(EvidenceVerifier.sequence(of: checked, keyID: earlier, followers: followers).missing, [2...2], "missing, as before")
    }

    /// ADR 0073's tests: a hole at load, among the key in use's counters (left by a build before this one), is named
    /// once, at the first pass with the key, though the pass signs nothing else.
    func testAHoleAtLoadIsNamedOnce() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)                                               // the file holds 1 and 3
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [third, first])
        await relaunched.logWritten(generation: 2, events: [third, first])
        await relaunch(keys).logWritten(generation: 1, events: [third, first])
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 4])
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2]])
        XCTAssertEqual(try keySequence(checked).missing, [])
    }

    /// ADR 0073, decision 2: an unkept statement that is itself not kept leaves a gap the next signature names with the
    /// rest, in one statement.
    func testAnUnkeptStatementNotKeptIsNamedWithTheRestAtTheNextSignature() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3), fourth = trip(4)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)
        let relaunched = relaunch(keys)
        try await refuseTheNextLine(keys) { await relaunched.logWritten(generation: 1, events: [third, first]) }   // its statement, 4
        // A stop before the next pass.
        await relaunch(keys).logWritten(generation: 1, events: [fourth, third, first])  // fourth at 5, then one statement at 6
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 3, 5, 6])
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2, 4...4]])
        XCTAssertEqual(try keySequence(checked).missing, [])
    }

    // MARK: - What names nothing

    /// A key the file does not list (its statement lost) has none of its signatures checked when the file is read, so it
    /// names none of its counters: they would all look unkept.
    func testAKeyTheFileDoesNotListNamesNothing() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        let entries = try XCTUnwrap(file.read())
        try FileManager.default.removeItem(at: file.url)
        for entry in entries where entry.kind != .keyPending { XCTAssertTrue(file.append(entry)) }
        await relaunch(keys).logWritten(generation: 1, events: [second, first])
        let statements = try XCTUnwrap(file.read()).compactMap { $0.statement.flatMap { try? EvidenceForm.read($0) } }
        XCTAssertFalse(statements.contains { if case .unkept = $0 { return true } else { return false } },
                       "no counter named of a key whose signatures the file cannot check")
    }

    /// A line under the key in use whose signature does not hold (another key's, claiming a counter far ahead) accounts
    /// for nothing: the counters below it are not named as made and not kept.
    func testALineWhoseSignatureDoesNotHoldAccountsForNothing() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2)
        await signer.logWritten(generation: 1, events: [first])
        let key = try keyID(try XCTUnwrap(file.read()))
        let statement = EvidenceForm.bytes(.export(EvidenceForm.Export(record: first.id, revision: 1, signedAt: 1, app: "1.11 (83)")))
        let assertion = try TestAttestation.assertion(by: P256.Signing.PrivateKey(), formHash: TestApp.sha256(statement), counter: 1_000)
        XCTAssertTrue(file.append(EvidenceSignatureFile.Entry(kind: .signature, key: key, statement: statement, assertion: assertion)))
        await relaunch(keys).logWritten(generation: 1, events: [second, first])   // second at 2
        let checked = try holding(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(checked.map(\.counter), [1, 2])
        XCTAssertEqual(unkeptStatements(checked).count, 0, "nothing below the forged counter named")
    }

    /// While a line the file refused is held, no signature is made: App Attest would count it, and the file could not
    /// keep it either (the file gone and its folder full, where the check of the file's lock still passes).
    func testNoSignatureIsMadeWhileARefusedLineIsHeld() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 2, events: [second, first]) }   // 2: held
        try FileManager.default.removeItem(at: file.url)
        try setFolderWritable(false)
        await signer.logWritten(generation: 3, events: [third, second, first])
        try setFolderWritable(true)
        let asked = await keys.assertionRequests
        XCTAssertEqual(asked, 2, "no signature made while the refused line is held")
    }

    /// An unkept statement's own signature names nothing more: a gap it shows (the build before this one stopped after
    /// its last signature) waits for the next signing, so no statement follows another in a chain.
    func testAnUnkeptStatementsOwnSignatureNamesNothingMore() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3), fourth = trip(4)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try await refuseTheNextLine(keys) { await signer.logWritten(generation: 4, events: [fourth, third, second, first]) }   // 4
        try dropTheSignature(of: second)                                               // the file holds 1 and 3
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [third, first])             // the statement for 2, at 5
        XCTAssertEqual(unkeptStatements(try verify(try XCTUnwrap(file.read()), chain)).map(\.counters), [[2...2]])
        await relaunched.logWritten(generation: 2, events: [third, first])             // then 4, at 6
        let checked = try verify(try XCTUnwrap(file.read()), chain)
        XCTAssertEqual(unkeptStatements(checked).map(\.counters), [[2...2], [4...4]])
        XCTAssertEqual(try keySequence(checked).missing, [])
    }

    // MARK: - A key App Attest lost

    /// Item 190's A5 kept (a share after a restore has its bundle): the key's gap, known before the share, is named with
    /// the key first; App Attest has lost it, so a new key is certified and the export statement signed with it.
    func testAShareAfterARestoreHasItsBundleThoughAGapWasKnown() async throws {
        let (signer, keys, chain) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)
        let earlier = try keyID(try XCTUnwrap(file.read()))
        await keys.lose(earlier.base64EncodedString())
        let made = try await exporterAfterAPassThatCannotSign(relaunch(keys), log: [third, first], first: first)
        let bundle = try XCTUnwrap(made, "the share has its bundle")
        let report = try check(bundle, chain)
        let renewed = try XCTUnwrap(try XCTUnwrap(file.read()).filter { $0.kind == .keyCertified }.last?.key)
        XCTAssertNotEqual(renewed, earlier, "a new key")
        XCTAssertNotNil(report.export)
        XCTAssertEqual(report.signatures.last?.entry?.keyID, renewed, "the export statement signed with it")
        XCTAssertEqual(unkeptStatements(try verify(try XCTUnwrap(file.read()), chain)).count, 0, "the earlier key's gap stays missing")
    }

    /// A pass whose naming of a gap finds the key lost has a new key certified, as a record's signature would: a share
    /// then has its bundle at once.
    func testAPassWhoseNamingFindsTheKeyLostCertifiesANewOne() async throws {
        let (signer, keys, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = trip(1), second = trip(2), third = trip(3)
        await signer.logWritten(generation: 1, events: [first])
        await signer.logWritten(generation: 2, events: [second, first])
        await signer.logWritten(generation: 3, events: [third, second, first])
        try dropTheSignature(of: second)
        let earlier = try keyID(try XCTUnwrap(file.read()))
        await keys.lose(earlier.base64EncodedString())
        let relaunched = relaunch(keys)
        await relaunched.logWritten(generation: 1, events: [third, first])            // nothing to sign but the gap's statement
        let certified = try XCTUnwrap(file.read()).filter { $0.kind == .keyCertified }.compactMap(\.key)
        XCTAssertEqual(certified.count, 2, "a new key certified in the same pass")
        let offered = await relaunched.canExport(first.id)
        XCTAssertTrue(offered, "Share offers the bundle")
    }

    // MARK: - Helpers

    private func makeSigner(in place: String = "", logging logged: WarningsLogged = WarningsLogged()) throws
        -> (EvidenceSigner, FakeKeyService, TestAttestationChain) {
        let chain = try TestAttestationChain()
        let keys = FakeKeyService(chain: chain)
        let time = TestClock(signedAt)
        let signer = EvidenceSigner(file: signatureFile(in: place), keys: keys, mediaDirectory: media, app: "1.11 (83)",
                                    now: { time.now }, retryAfter: 0, logWarning: logged.handler)
        return (signer, keys, chain)
    }

    /// The line the phone's log gets when signatures are thrown away, as `store/DEVICE_TEST_CHECKLIST.md` names it (item 206).
    private func thrownAwayLine(_ count: Int) -> String {
        "Evidence signing: the count went back: \(count) signature(s) thrown away"
    }

    /// The signature file, or another phone's beside it.
    private func signatureFile(in place: String) -> EvidenceSignatureFile {
        place.isEmpty ? file : EvidenceSignatureFile(url: folder.appendingPathComponent("\(place)-\(EvidenceSignatureFile.name)"))
    }

    /// The signer of the app's next launch, on the same file and keys.
    private func relaunch(_ keys: FakeKeyService, logging logged: WarningsLogged = WarningsLogged()) -> EvidenceSigner {
        EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.11 (83)", now: { [signedAt] in signedAt }, retryAfter: 0,
                       logWarning: logged.handler)
    }

    private func exporter(_ signer: EvidenceSigner) -> EvidenceExporter {
        EvidenceExporter(signer: signer, mediaDirectory: media, temporaryDirectory: out)
    }

    /// The relaunched signer's first pass, made while the file cannot take a line, so that it signs nothing (the hole it
    /// finds at load stays to name), then the bundle of `first`.
    private func exporterAfterAPassThatCannotSign(_ signer: EvidenceSigner, log: [Event], first: Event) async throws -> URL? {
        try setFileWritable(false)
        await signer.logWritten(generation: 1, events: log)
        try setFileWritable(true)
        return try await exporter(signer).folder(of: first, log: log, in: out)
    }

    /// Runs `work` with the next signature the stand-in makes refused by the file (once `after` more are made): the
    /// signature made and counted, its line not written, as on a full disk. The file takes lines again afterwards.
    private func refuseTheNextLine(_ keys: FakeKeyService, after: Int = 0,
                                   during work: @escaping @MainActor @Sendable () async -> Void) async throws {
        let asked = await keys.assertionRequests
        await keys.holdNextAssertion(after: after)
        let running = Task { @MainActor in await work() }
        try await waitUntil { await keys.assertionRequests > asked + after }
        try setFileWritable(false)
        await keys.releaseHeldAssertion()
        await running.value
        try setFileWritable(true)
    }

    /// The file without the signature of `event`, as a build before this one left it when it stopped between that
    /// signature and its line (and signed the record again under a later counter, or never).
    private func dropTheSignature(of event: Event) throws {
        let entries = try XCTUnwrap(file.read())
        try FileManager.default.removeItem(at: file.url)
        for entry in entries where !(entry.kind == .signature && entry.record == event.id) { XCTAssertTrue(file.append(entry)) }
    }

    /// Lets the test's folder take new files, or not, as a full disk refuses them.
    private func setFolderWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o755 : 0o555], ofItemAtPath: folder.path)
    }

    private func setFileWritable(_ writable: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o644 : 0o444], ofItemAtPath: file.url.path)
    }

    private func trip(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 11, 4, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }

    private func check(_ bundle: URL, _ chain: TestAttestationChain) throws -> EvidenceBundle.Report {
        try EvidenceBundle.check(bundle, appID: TestApp.id, roots: [chain.rootDER])
    }

    private func indexText(_ bundle: URL) throws -> String {
        try String(contentsOf: bundle.appendingPathComponent(EvidenceBundle.indexName), encoding: .utf8)
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

    /// The signatures in `entries` that hold under the key they name, checked with the verifier's rules; one that does not
    /// is left out.
    private func holding(_ entries: [EvidenceSignatureFile.Entry], _ chain: TestAttestationChain) throws -> [EvidenceSignedEntry] {
        let keys = try entries.filter { $0.kind == .keyCertified }.map { certified in
            let pending = try XCTUnwrap(entries.last { $0.kind == .keyPending && $0.key == certified.key })
            return try EvidenceVerifier.certify(attestation: try XCTUnwrap(certified.attestation),
                                                statement: try XCTUnwrap(pending.statement), appID: TestApp.id, roots: [chain.rootDER])
        }
        return entries.filter { $0.kind == .signature }.compactMap { entry in
            guard let key = keys.first(where: { $0.keyID == entry.key }), let statement = entry.statement,
                  let assertion = entry.assertion else { return nil }
            return try? EvidenceVerifier.check(assertion: assertion, formHash: TestApp.sha256(statement), form: statement, under: key)
        }
    }

    /// What the counters of the file's one key say, by the verifier's rules.
    private func keySequence(_ checked: [EvidenceSignedEntry]) throws -> EvidenceSequence {
        EvidenceVerifier.sequence(of: checked, keyID: try XCTUnwrap(checked.first?.keyID), followers: [])
    }

    /// The revisions of `record` the file's signatures sign, in the file's order.
    private func revisions(of record: UUID, _ chain: TestAttestationChain) throws -> [Int64] {
        try verify(try XCTUnwrap(file.read()), chain).compactMap { entry in
            if case .record(let form)? = entry.statement, form.id == record { return form.revision }
            return nil
        }
    }

    /// The first key the file certifies.
    private func keyID(_ entries: [EvidenceSignatureFile.Entry]) throws -> Data {
        try XCTUnwrap(entries.first { $0.kind == .keyCertified }?.key)
    }

    private func unkeptStatements(_ checked: [EvidenceSignedEntry]) -> [EvidenceForm.Unkept] {
        checked.compactMap { entry in
            if case .unkept(let statement)? = entry.statement { return statement }
            return nil
        }
    }

    private func isUnkept(_ entry: EvidenceSignedEntry) -> Bool {
        if case .unkept? = entry.statement { return true }
        return false
    }

    private func isExport(_ entry: EvidenceSignedEntry) -> Bool {
        if case .export? = entry.statement { return true }
        return false
    }

    private func recordID(_ entry: EvidenceSignedEntry) -> UUID? {
        if case .record(let form)? = entry.statement { return form.id }
        return nil
    }

    private func retention(_ entry: EvidenceSignedEntry) -> EvidenceForm.Retention? {
        if case .retention(let statement)? = entry.statement { return statement }
        return nil
    }

    private func absence(_ entry: EvidenceSignedEntry) -> EvidenceForm.Absence? {
        if case .absence(let statement)? = entry.statement { return statement }
        return nil
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
