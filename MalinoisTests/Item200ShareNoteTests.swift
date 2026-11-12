//
//  Item200ShareNoteTests.swift
//  MalinoisTests
//
//  BACKLOG 200 (from item 198's DeepSeek-4; the owner, 2026-11-07: "as you recommend, wording approved": option (a)).
//  Share left the signed evidence ZIP out with no reason on screen: when the signature file or a photo or clip could not be
//  read, with no certified key, and when the making failed after a destination was picked, so a sender could think the
//  signed evidence went. After a share that completed to a destination that takes files, for this phone's own record, the
//  event's screen now says it went without the ZIP, and why, until the owner leaves the screen; a cancelled share, a
//  destination that takes no file, another device's copy and a record this phone never signed show nothing. App Attest
//  does not run in the Simulator, so the signer's stand-in plays it, as in Item90SignerTests. Written before the code, red
//  at that commit (against compile-only stubs).
//

import DeviceCheck
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item200ShareNoteTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item200-\(UUID().uuidString)")
    nonisolated private var media: URL { folder.appendingPathComponent("Media", isDirectory: true) }
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - The line

    /// The two lines, as the owner approved them.
    func testTheLinesSayWhatTheOwnerApproved() {
        XCTAssertEqual(ShareNote.noCertifiedKey, "Sent without the signed evidence ZIP: Apple has not certified this iPhone's "
                       + "signing key yet, which needs a network connection. Share again once it is online.")
        XCTAssertEqual(ShareNote.notMade, "Sent without the signed evidence ZIP: Malinois could not make it just now. Share again later.")
    }

    /// After a completed share to a destination that takes files: the line for no certified key, and the other line when
    /// the ZIP could not be offered now or its making failed after the destination was picked.
    func testALineAfterACompletedShareThatWentWithoutTheZIP() {
        XCTAssertEqual(line(.noCertifiedKey), ShareNote.noCertifiedKey)
        XCTAssertEqual(line(.notNow), ShareNote.notMade)
        XCTAssertEqual(line(.ready, made: false), ShareNote.notMade, "made for the destination picked, and it failed")
        XCTAssertEqual(line(.noCertifiedKey, destination: nil), ShareNote.noCertifiedKey, "a destination iOS does not name")
        XCTAssertEqual(line(.notNow, destination: .mail), ShareNote.notMade)
    }

    /// A guard, green before the fix and after: no line where no ZIP was expected or it went.
    func testNoLineWhereNoZIPWasExpectedOrItWent() {
        XCTAssertNil(line(.noCertifiedKey, completed: false), "a share cancelled sent nothing")
        XCTAssertNil(line(.notNow, destination: .saveToCameraRoll), "a destination that takes no file")
        XCTAssertNil(line(.notNow, destination: .copyToPasteboard), "Copy takes no ZIP")
        XCTAssertNil(line(.notSigned), "a record this phone never signed has no ZIP")
        XCTAssertNil(line(.noCertifiedKey, mirrored: true), "another device's copy has none")
        XCTAssertNil(line(.ready, made: true), "the ZIP went")
        XCTAssertNil(line(.ready, made: nil), "not known to have failed")
        XCTAssertNil(line(nil), "no exporter: a test's screen")
    }

    // MARK: - Why there is no ZIP

    /// The signer says why it offers no bundle: a record it never signed; a signed record before the log is compared in
    /// this launch; then ready; and a signed record whose key App Attest lost, until the next key is certified.
    func testTheSignerSaysWhyItOffersNoBundle() async throws {
        let keys = FakeKeyService(chain: try TestAttestationChain())
        let signer = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.12 (86)", retryAfter: 0)
        await signer.certifyIfNeeded(records: [])
        let record = event(1)
        await signer.logWritten(generation: 1, events: [record])
        let unknown = await signer.exportReadiness(UUID())
        XCTAssertEqual(unknown, .notSigned)
        let ready = await signer.exportReadiness(record.id)
        XCTAssertEqual(ready, .ready)
        let canExport = await signer.canExport(record.id)
        XCTAssertTrue(canExport, "the same answer as before")

        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.12 (86)", retryAfter: 0)
        let beforeTheLog = await relaunched.exportReadiness(record.id)
        XCTAssertEqual(beforeTheLog, .notNow, "the log on disk not compared yet in this launch")

        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await signer.logWritten(generation: 2, events: [record, event(2)])
        let lost = await signer.exportReadiness(record.id)
        XCTAssertEqual(lost, .noCertifiedKey, "a key App Attest lost, the next not certified yet")
    }

    /// The bundle item says whether it was made for the destination picked: not asked, failed, or made; and a share's
    /// end keeps the answer.
    func testTheBundleItemSaysWhetherItWasMadeForTheDestination() throws {
        let failing = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) { nil }
        XCTAssertNil(failing.madeForTheDestination, "no destination picked yet")
        XCTAssertNil(failing.madeBundle(for: .saveToCameraRoll))
        XCTAssertNil(failing.madeForTheDestination, "a destination that takes no file asks for none")
        _ = failing.madeBundle(for: .airDrop)
        XCTAssertEqual(failing.madeForTheDestination, false, "asked for, and not made")
        failing.finish()
        XCTAssertEqual(failing.madeForTheDestination, false, "kept once the share is over")

        let zip = folder.appendingPathComponent("made/Malinois evidence.zip")
        try FileManager.default.createDirectory(at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x50, 0x4B]).write(to: zip)
        let making = EvidenceBundleItem(placeholder: zip) { zip }
        _ = making.madeBundle(for: .mail)
        XCTAssertEqual(making.madeForTheDestination, true)
        making.finish()
    }

    /// The event's screen (read from the source tree, as built) opens Share with the offer, keeps its bundle and reason
    /// with the sheet, hears the sheet's end, and shows the line.
    func testTheEventScreenShowsTheLineAfterTheShare() throws {
        let screen = try String(contentsOf: Self.root.appendingPathComponent("Malinois/Views/EventDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(screen.contains("await EvidenceBundleItem.offer(of: current"))
        XCTAssertTrue(screen.contains("completionWithItemsHandler"))
        XCTAssertTrue(screen.contains("ShareNote.line(readiness: request.readiness"))
        XCTAssertTrue(screen.contains("made: request.bundle?.madeForTheDestination"))
        XCTAssertTrue(screen.contains("if let shareNote"))
    }

    // MARK: - Helpers

    private func line(_ readiness: EvidenceExportReadiness?, completed: Bool = true,
                      destination: UIActivity.ActivityType? = .airDrop, made: Bool? = nil, mirrored: Bool = false) -> String? {
        ShareNote.line(readiness: readiness, completed: completed, destination: destination, made: made, mirrored: mirrored)
    }

    private func event(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 11, 7, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }
}
