//
//  Item190DownloadCheckTests.swift
//  MalinoisTests
//
//  BACKLOG item 190's A4, its download half (item 192's step 2; the owner, 2026-11-04: "a, approved"). A photo or clip
//  downloaded from iCloud into a record this phone signed is checked, before it joins the record, against the digest the
//  latest revision naming it signed: one that differs is not added, iCloud's copy is left as it is, and the event's
//  screen says so, in the owner's words. A capture no signature of this phone's covers (a record the log held before the
//  key was certified, as for a copy from another device or a record from before 1.10) joins as before; while the phone
//  cannot read what it signed, the capture waits for another try. The launch hands the engine the signer that signs the
//  log. Each case through the engine's own download, with the signer's own file. Written before the code, red at that
//  commit (against compile-only stubs). Item 194 (the owner, 2026-11-04: "1 a 2 a"): the download compares and
//  attaches in one turn of the signer's, so a signature in progress or held counts; a stored file that does not join
//  its record is removed at once.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item190DownloadCheckTests: XCTestCase {

    /// The line the owner approved (2026-11-04: "a, approved").
    private static let refusedNote =
        "A capture in iCloud differs from the one this iPhone recorded, so it wasn't added - iCloud's copy is unchanged."
    private static let nothingNote = "Nothing came back - the full capture may not be in iCloud, or iCloud isn't reachable."
    private static let download = "Download full evidence from iCloud"

    private let signedAt = TestApp.date(2026, 11, 4, 20, 0)
    private var generation = 0

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem190Download")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The check

    /// A photo saved in iCloud under the name of this iPhone's own photo, with other bytes than the photo it signed: the
    /// download does not add it, says so, and nothing signs it.
    func testACaptureThatDiffersFromThePhotoThisIPhoneSignedIsNotAdded() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        try iCloudHands(rig, photo(2))
        let outcome = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(outcome.refused, "refused")
        XCTAssertFalse(outcome.landed, "nothing added")
        XCTAssertTrue(outcome.complete, "every capture iCloud has was compared: nothing to try again")
        XCTAssertNil(held(record.id, rig)?.mediaFilename, "the record has no photo")
        await pass(rig)
        XCTAssertFalse(try signedDigests(of: record.id, "primary", rig).contains(EvidenceHash.digest(of: photo(2))),
                       "no revision signs iCloud's photo")
    }

    /// Guard: the photo this iPhone signed joins its record as before, and the record is signed again with it.
    func testThePhotoThisIPhoneSignedIsAddedAsBefore() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        try iCloudHands(rig, photo(1))
        let outcome = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertEqual(outcome, MonitoringEngine.EvidenceDownload(landed: true, complete: true))
        let name = try XCTUnwrap(held(record.id, rig)?.mediaFilename, "the photo is on the record")
        XCTAssertEqual(try Data(contentsOf: rig.store.mediaDirectory.appendingPathComponent(name)), photo(1))
        await pass(rig)
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig).last, EvidenceHash.digest(of: photo(1)),
                       "signed again with it")
    }

    /// The next launch's signer reads what it signed from its file: the check holds as in the launch that signed it.
    func testAfterARelaunchTheCaptureIsCheckedAgainstWhatTheFileSigned() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        rig.engine.downloadSigner = launchSigner(for: rig.store, keys: rig.keys)
        try iCloudHands(rig, photo(2))
        let refused = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(refused.refused, "not the photo the file signed")
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
        try iCloudHands(rig, photo(1))
        let added = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(added.landed, "the photo the file signed")
        XCTAssertFalse(added.refused)
    }

    /// Each camera's capture against its own: the front's photo saved under the rear's name is not the rear photo
    /// signed.
    func testTheRearCaptureIsCheckedAgainstTheRearOneSigned() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1), rear: photo(3))
        try await evict(record.id, secondary: true, rig)
        try iCloudHands(rig, photo(1), camera: "rear")
        let refused = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(refused.refused, "the front's photo is not the rear photo signed")
        XCTAssertNil(held(record.id, rig)?.secondaryMediaFilename)
        try iCloudHands(rig, photo(3), camera: "rear")
        let added = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(added.landed)
        XCTAssertFalse(added.refused)
        XCTAssertNotNil(held(record.id, rig)?.secondaryMediaFilename, "the rear photo signed")
    }

    /// A clip, compared by its file.
    func testAClipIsCheckedByItsFile() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: clip(1), ext: "mov")
        try await evict(record.id, rig)
        try iCloudHands(rig, clip(2), ext: "mov")
        let refused = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(refused.refused, "not the clip signed")
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
        try iCloudHands(rig, clip(1), ext: "mov")
        let added = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(added.landed, "the clip signed")
        XCTAssertFalse(added.refused)
    }

    /// What a capture is compared with is the digest of the latest revision that names it (Claude's choice, noted to the
    /// owner): a photo an earlier revision signed, the file since changed and signed again, is not the one the record
    /// last signed.
    func testTheLatestRevisionNamingTheCaptureIsWhatItIsComparedWith() async throws {
        let rig = try await makeRig()
        var record = try await capture(rig, front: photo(1))
        // The file changes in place and the record is signed again with it (longer, so the signer hashes it again).
        let name = try XCTUnwrap(record.mediaFilename)
        try photo(4, count: 96).write(to: rig.store.mediaDirectory.appendingPathComponent(name))
        record.ownerAttributed = true
        rig.store.update(record)
        await pass(rig)
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig),
                       [EvidenceHash.digest(of: photo(1)), EvidenceHash.digest(of: photo(4, count: 96))])
        try await evict(record.id, rig)
        try iCloudHands(rig, photo(1))
        let earlier = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(earlier.refused, "an earlier revision's photo")
        try iCloudHands(rig, photo(4, count: 96))
        let latest = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(latest.landed, "the photo the latest revision naming it signed")
    }

    /// Guard: a record no signature of this phone's covers (the log held it before the key was certified) takes what
    /// iCloud has as before.
    func testACaptureNoSignatureOfThisIPhonesCoversIsAddedAsBefore() async throws {
        let id = UUID()
        let rig = try await makeRig(baseline: [id])
        let record = try await capture(rig, id: id, front: photo(1))
        try await evict(record.id, rig)
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig), [], "never signed")
        try iCloudHands(rig, photo(2))
        let outcome = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(outcome.landed, "added as before")
        XCTAssertFalse(outcome.refused)
        XCTAssertNotNil(held(record.id, rig)?.mediaFilename)
    }

    /// While the phone cannot read what it signed (the next launch's signer, its file unreadable now), a capture is not
    /// added unchecked: the download is left to try again, and once the file can be read, the capture is compared.
    func testACaptureWaitsWhileThePhoneCannotReadWhatItSigned() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        let path = rig.store.evidenceSignaturesURL.path
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        rig.engine.downloadSigner = launchSigner(for: rig.store, keys: rig.keys)
        try iCloudHands(rig, photo(2))
        let waited = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertFalse(waited.landed, "not added unchecked")
        XCTAssertFalse(waited.complete, "left to try again")
        XCTAssertFalse(waited.refused, "nothing could be compared")
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        let compared = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(compared.refused, "compared once the file can be read")
    }

    // MARK: - The event's screen, laid out for real

    /// "Download full evidence from iCloud" pressed, and iCloud's photo is not the one signed: the screen says so, in the
    /// owner's words, and not that nothing came back.
    func testTheEventScreenSaysSoWhenACaptureIsNotAdded() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        try iCloudHands(rig, photo(2))
        let shown = try XCTUnwrap(held(record.id, rig))
        let recorder = OnScreenRecorder()
        let screen = NavigationStack { EventDetailView(event: shown) }
            .environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
        try await onScreen(screen, recorder) {
            try await waitUntil("the download offered") { recorder.actions[Self.download] != nil }
            XCTAssertFalse(recorder.shown.contains(Self.refusedNote), "not before any download")
            recorder.actions[Self.download]?()
            try await waitUntil("the screen says the capture was not added") { recorder.shown.contains(Self.refusedNote) }
            try await Task.sleep(for: .milliseconds(300))   // the screen settles
            XCTAssertFalse(recorder.shown.contains(Self.nothingNote), "not that nothing came back")
        }
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
    }

    /// Guard: on the screen, a capture that joins its record says nothing of a refusal, nor that nothing came back,
    /// while the rear's file, not in iCloud, is still to get and the download still offered.
    func testTheEventScreenSaysNothingOfARefusalWhenACaptureJoins() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1), rear: photo(3))
        try await evict(record.id, rig)
        try await evict(record.id, secondary: true, rig)
        try iCloudHands(rig, photo(1))
        let shown = try XCTUnwrap(held(record.id, rig))
        let recorder = OnScreenRecorder()
        let screen = NavigationStack { EventDetailView(event: shown) }
            .environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
        try await onScreen(screen, recorder) {
            try await waitUntil("the download offered") { recorder.actions[Self.download] != nil }
            recorder.actions[Self.download]?()
            try await waitUntil("the front's photo on the record") { held(record.id, rig)?.mediaFilename != nil }
            try await Task.sleep(for: .milliseconds(300))   // the screen settles
            XCTAssertFalse(recorder.shown.contains(Self.refusedNote), "no refusal")
            XCTAssertFalse(recorder.shown.contains(Self.nothingNote), "not that nothing came back")
            XCTAssertTrue(recorder.shown.contains(Self.download), "still offered, for the rear")
        }
    }

    // MARK: - Item 194: the signer's turn, and what a refused download leaves

    /// Item 194's codex-1 (the owner's "a"): a slot's first signature still at App Attest when the storage limit removes
    /// its file and a download starts. The download waits for the signature, which is kept, and compares with it: the
    /// capture refused, nothing of it signed.
    func testADownloadWaitsForASignatureInProgressAndComparesWithIt() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1), signing: false)
        let asked = await rig.keys.assertionRequests
        await rig.keys.holdNextAssertion()
        let signing = Task { await self.pass(rig) }
        try await waitFor("the pass at App Attest") { await rig.keys.assertionRequests > asked }
        try await evict(record.id, rig, signing: false)
        try iCloudHands(rig, photo(2))
        let download = Task { await rig.engine.downloadFullEvidence(for: record.id) }
        try await Task.sleep(for: .milliseconds(300))   // a download that did not wait would be done by now
        await rig.keys.releaseHeldAssertion()
        await signing.value
        let outcome = await download.value
        XCTAssertTrue(outcome.refused, "compared with the signature kept meanwhile")
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
        await pass(rig)
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig), [EvidenceHash.digest(of: photo(1))],
                       "the signature in progress kept, nothing of iCloud's signed")
    }

    /// Item 194's codex-1: a slot's first signature made but its line refused by the file (held), the storage limit
    /// removing the slot's file, and a download: compared with the held signature while the file still refuses lines,
    /// and, once it takes them, the held line written first and compared with.
    func testADownloadComparesWithASignatureTheFileHolds() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1), signing: false)
        let asked = await rig.keys.assertionRequests
        await rig.keys.holdNextAssertion()
        let signing = Task { await self.pass(rig) }
        try await waitFor("the pass at App Attest") { await rig.keys.assertionRequests > asked }
        try setSignatureFileWritable(false, rig)   // the line refused once App Attest made the signature: held
        await rig.keys.releaseHeldAssertion()
        await signing.value
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig), [], "held, not written")
        try await evict(record.id, rig, signing: false)
        try iCloudHands(rig, photo(2))
        let whileHeld = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(whileHeld.refused, "compared with the signature the file holds")
        XCTAssertNil(held(record.id, rig)?.mediaFilename)
        try setSignatureFileWritable(true, rig)
        let written = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(written.refused, "the held line written first, and compared with")
        XCTAssertEqual(try signedDigests(of: record.id, "primary", rig), [EvidenceHash.digest(of: photo(1))],
                       "the held signature written")
    }

    /// Item 194's codex-2 (the owner's "a"): refused downloads leave nothing behind: three in a row, each refused, the
    /// media folder's files as before, the record and its signatures unchanged; also with a damaged log's backup beside
    /// the log, which keeps the launch's sweep from removing anything.
    func testRefusedDownloadsLeaveNothingInTheMediaFolder() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1))
        try await evict(record.id, rig)
        let before = try mediaFolder(rig)
        let kept = held(record.id, rig)
        let signatures = EvidenceSignatureFile(url: rig.store.evidenceSignaturesURL).read()
        try iCloudHands(rig, photo(2, count: 4_096))
        for attempt in 1...3 {
            let outcome = await rig.engine.downloadFullEvidence(for: record.id)
            XCTAssertTrue(outcome.refused, "attempt \(attempt)")
            XCTAssertEqual(try mediaFolder(rig), before, "attempt \(attempt): nothing left in the media folder")
        }
        XCTAssertEqual(held(record.id, rig), kept, "the record as it was")
        XCTAssertEqual(EvidenceSignatureFile(url: rig.store.evidenceSignaturesURL).read(), signatures, "its signatures as they were")
        let backup = rig.store.evidenceSignaturesURL.deletingLastPathComponent()
            .appendingPathComponent("events.corrupt-1793000000.json")
        try Data("damaged".utf8).write(to: backup)
        let withBackup = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(withBackup.refused)
        XCTAssertEqual(try mediaFolder(rig), before, "nothing left with a damaged log's backup beside the log")
    }

    /// Item 194's codex-2: removing a download's unattached file never touches a file a record names, nor one outside
    /// the media folder.
    func testTheRemovalOfAnUnattachedFileNeverTouchesOneARecordNames() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: photo(1), rear: photo(3))
        for named in [try XCTUnwrap(record.mediaFilename), try XCTUnwrap(record.secondaryMediaFilename)] {
            rig.store.discardUnattached(named)
            XCTAssertTrue(FileManager.default.fileExists(atPath: rig.store.mediaDirectory.appendingPathComponent(named).path),
                          "a record names it, as its front's or its rear's: kept")
        }
        let loose = try await stored(photo(5), ext: "jpg", in: rig.store)
        rig.store.discardUnattached(loose)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rig.store.mediaDirectory.appendingPathComponent(loose).path),
                       "no record names it: removed")
        // A name that is not a plain one in the media folder is never followed out of it.
        rig.store.discardUnattached("../" + EvidenceSignatureFile.name)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rig.store.evidenceSignaturesURL.path), "the signature file kept")
    }

    /// Item 194's codex-1 on bdf51301 (the owner's "a"): a clip downloaded while the signer cannot read its file is copied
    /// to be checked, and the copy goes with the download's every way out: three tries leave no copy in the temporary
    /// folder, nor anything in the media folder; once the file can be read, a clip that differs is refused and the
    /// signed one added, neither leaving a copy.
    func testAClipLeftWaitingLeavesNoCopyBehind() async throws {
        let rig = try await makeRig()
        let record = try await capture(rig, front: clip(1), ext: "mov")
        try await evict(record.id, rig)
        let path = rig.store.evidenceSignaturesURL.path
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions])
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        rig.engine.downloadSigner = launchSigner(for: rig.store, keys: rig.keys)
        try iCloudHands(rig, clip(2), ext: "mov")
        let copies = try stagedCopies()
        let media = try mediaFolder(rig)
        for attempt in 1...3 {
            let waited = await rig.engine.downloadFullEvidence(for: record.id)
            XCTAssertFalse(waited.landed, "attempt \(attempt): not added unchecked")
            XCTAssertFalse(waited.complete, "attempt \(attempt): left to try again")
            XCTAssertEqual(try stagedCopies(), copies, "attempt \(attempt): no copy left in the temporary folder")
            XCTAssertEqual(try mediaFolder(rig), media, "attempt \(attempt): nothing in the media folder")
        }
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
        let refused = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(refused.refused, "a clip that differs, refused")
        XCTAssertEqual(try stagedCopies(), copies, "refused: no copy left")
        try iCloudHands(rig, clip(1), ext: "mov")
        let added = await rig.engine.downloadFullEvidence(for: record.id)
        XCTAssertTrue(added.landed, "the signed clip, added")
        XCTAssertEqual(try stagedCopies(), copies, "added: no copy left")
    }

    // MARK: - The launch

    func testTheLaunchHandsTheEngineTheSignerThatSignsTheLog() {
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        XCTAssertTrue(services.engine.downloadSigner === services.evidenceSigning.signer,
                      "downloads compared with what the log's signer signed")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    // MARK: - Rig

    private struct Rig {
        let store: EventStore
        let engine: MonitoringEngine
        let entitlements: ProEntitlements
        let signer: EvidenceSigner
        let keys: FakeKeyService
    }

    /// A store, an engine on Pro, and a signer of the store's log whose key is certified, the records in `baseline` held
    /// before it (never signed); the engine handed the signer, as the launch hands it.
    private func makeRig(baseline: [UUID] = []) async throws -> Rig {
        let store = EventStore()
        let keys = FakeKeyService(chain: try TestAttestationChain())
        let signer = launchSigner(for: store, keys: keys)
        await signer.certifyIfNeeded(records: baseline)
        let entitlements = ProEntitlements(resolvedAs: .trial)
        XCTAssertTrue(entitlements.proActive, "the download is a Pro feature")
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.downloadSigner = signer
        return Rig(store: store, engine: engine, entitlements: entitlements, signer: signer, keys: keys)
    }

    /// A signer of `store`'s log, with its signature file and media folder, as a launch makes one.
    private func launchSigner(for store: EventStore, keys: FakeKeyService) -> EvidenceSigner {
        let now = signedAt
        return EvidenceSigner(file: EvidenceSignatureFile(url: store.evidenceSignaturesURL), keys: keys,
                              mediaDirectory: store.mediaDirectory, app: "1.11 (83)", now: { now }, retryAfter: 0)
    }

    /// The signer's pass over the store's log as it stands.
    private func pass(_ rig: Rig) async {
        generation += 1
        await rig.signer.logWritten(generation: generation, events: rig.store.events)
    }

    /// This iPhone's record of a capture with the front camera (and the rear, when given), stored in the media folder as
    /// the camera stores one, uploaded to iCloud, and signed at the pass that follows (unless `signing` is false, or the
    /// log held it before the key was certified).
    private func capture(_ rig: Rig, id: UUID = UUID(), front: Data, rear: Data? = nil, ext: String = "jpg",
                         signing: Bool = true) async throws -> Event {
        let start = TestApp.date(2026, 11, 4, 19, 0)
        var record = Event(id: id, startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion])
        record.mediaFilename = try await stored(front, ext: ext, in: rig.store)
        record.primaryCamera = "front"
        var uploaded = ["front"]
        if let rear {
            record.secondaryMediaFilename = try await stored(rear, ext: ext, in: rig.store)
            record.secondaryCamera = "rear"
            uploaded.append("rear")
        }
        record.uploadedMedia = uploaded
        rig.store.add(record)
        rig.store.setSyncState(.synced, for: id)
        if signing { await pass(rig) }
        return try XCTUnwrap(held(id, rig))
    }

    /// `bytes` in the store's media folder, as the camera stores a photo or a clip; its file's name.
    private func stored(_ bytes: Data, ext: String, in store: EventStore) async throws -> String {
        let source: EventStore.MediaSource
        if ext == "mov" {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Item190Download-\(UUID().uuidString).mov")
            try bytes.write(to: url)
            source = .clip(url)
        } else {
            source = .still(bytes)
        }
        let media = await store.store(source, ext: ext)
        return try XCTUnwrap(media?.filename, "stored")
    }

    /// The storage limit's removal of the record's file (the rear's, when `secondary`): the file gone, the record no
    /// longer naming it, and the record signed again without it (unless `signing` is false).
    private func evict(_ id: UUID, secondary: Bool = false, _ rig: Rig, signing: Bool = true) async throws {
        var record = try XCTUnwrap(held(id, rig))
        let name = try XCTUnwrap(secondary ? record.secondaryMediaFilename : record.mediaFilename)
        try FileManager.default.removeItem(at: rig.store.mediaDirectory.appendingPathComponent(name))
        if secondary { record.secondaryMediaFilename = nil } else { record.mediaFilename = nil }
        rig.store.update(record)
        if signing { await pass(rig) }
    }

    /// What iCloud hands back at the next download: `bytes`, saved under `camera`'s name, in a file of its own.
    private func iCloudHands(_ rig: Rig, _ bytes: Data, camera: String = "front", ext: String = "jpg") throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Item190Download-\(UUID().uuidString).\(ext)")
        try bytes.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: camera, camera: camera, fileURL: url)],
                                            complete: true)
        }
    }

    private func held(_ id: UUID, _ rig: Rig) -> Event? { rig.store.events.first { $0.id == id } }

    /// The signature file writable or not, as a full disk refuses a line.
    private func setSignatureFileWritable(_ writable: Bool, _ rig: Rig) throws {
        try FileManager.default.setAttributes([.posixPermissions: writable ? 0o644 : 0o444],
                                              ofItemAtPath: rig.store.evidenceSignaturesURL.path)
    }

    /// The clips a download copied into the temporary folder to check them, named by a UUID as `stageDownloadedAsset`
    /// names them (this test's own stand-ins for iCloud carry another name).
    private func stagedCopies() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path).filter { name in
            name.hasSuffix(".mov") && UUID(uuidString: String(name.dropLast(4))) != nil
        })
    }

    /// The media folder's files, each by its name with its size.
    private func mediaFolder(_ rig: Rig) throws -> [String: Int64] {
        var files: [String: Int64] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: rig.store.mediaDirectory.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: rig.store.mediaDirectory.appendingPathComponent(name).path)
            files[name] = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        }
        return files
    }

    /// The digests the file's revisions of `record` sign for `slot` ("primary", "secondary"), in the file's order; a
    /// revision that names none is left out.
    private func signedDigests(of record: UUID, _ slot: String, _ rig: Rig) throws -> [EvidenceForm.Digest] {
        try XCTUnwrap(EvidenceSignatureFile(url: rig.store.evidenceSignaturesURL).read()).compactMap { entry in
            guard entry.kind == .signature, let statement = entry.statement,
                  case .record(let form)? = try? EvidenceForm.read(statement), form.id == record else { return nil }
            return form.attachments.first { $0.name == slot }?.digest
        }
    }

    /// A photo's bytes as iCloud and the camera keep them: a JPEG's first bytes, `count` of `fill`, its last two.
    private func photo(_ fill: UInt8, count: Int = 64) -> Data {
        Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: fill, count: count) + Data([0xFF, 0xD9])
    }

    /// A clip's bytes: a movie's first box, then 200 of `fill`.
    private func clip(_ fill: UInt8) -> Data {
        Data([0x00, 0x00, 0x00, 0x18]) + Data("ftypqt  ".utf8) + Data(repeating: fill, count: 200)
    }

    /// Lays `view` out in a window the size of a 17 Pro's screen, `recorder` reading it, while `body` runs.
    private func onScreen<V: View>(_ view: V, _ recorder: OnScreenRecorder, _ body: () async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        try await body()
    }

    /// As `waitUntil`, for a condition read across an actor.
    private func waitFor(_ what: String, _ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            guard clock.now < deadline else {
                XCTFail("waited ten seconds: \(what)")
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Lets the main run loop turn until `condition` holds; after ten seconds, fails the test, naming what it waited for
    /// (a thrown error alone reads as XCTest's "InvalidTransition" on a screen laid out for real), and stops it.
    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("waited ten seconds: \(what)")
                throw TimedOut(what: what)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct TimedOut: Error {
    let what: String
}
