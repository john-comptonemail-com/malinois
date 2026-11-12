//
//  Item199SigningKeyRowTests.swift
//  MalinoisTests
//
//  BACKLOG 199 (from item 198's Fable-2 and DeepSeek-2; the owner, 2026-11-07: "as you recommend, wording approved"). A
//  check ties a ZIP to the key that signed it, and the app showed no one that key. Settings now has a row of its own,
//  "Signing key": the certified key's ID as the verifier prints a key (its first eight characters), with Copy for the
//  whole ID; before Apple has certified a key, that it waits for Apple; nothing where this iPhone cannot sign. App Attest
//  does not run in the Simulator, so the signer's stand-in plays it, as in Item90SignerTests. Written before the code, red
//  at that commit (against compile-only stubs).
//

import DeviceCheck
import XCTest
@testable import Malinois

@MainActor
final class Item199SigningKeyRowTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item199-\(UUID().uuidString)")
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

    // MARK: - The words

    /// The row's words, as the owner approved them. The footer says "Each evidence ZIP" since item 218's Codex-4 (the
    /// owner, 2026-11-09: "as you recommend, wording approved"): 1.12 adds a ZIP that is not signed, a set-aside log's, so
    /// "Each ZIP you share is signed with this key" no longer held; "a ZIP" in its next sentence became "one".
    func testTheRowSaysWhatTheOwnerApproved() {
        XCTAssertEqual(SigningKeyRow.title, "Signing key")
        XCTAssertEqual(SigningKeyRow.copy, "Copy")
        XCTAssertEqual(SigningKeyRow.value(.waitingForApple), "Waiting for Apple to certify it (needs a network connection)")
        XCTAssertEqual(SigningKeyRow.footer, "Each evidence ZIP you share is signed with this key, and its check names the key by "
                       + "these eight characters. Give someone this ID before you send them one, and they can tell it was signed "
                       + "on this iPhone. Malinois makes a new key after it is deleted and installed again, on a new iPhone, or "
                       + "if Apple's App Attest loses this one.")
        XCTAssertNil(SigningKeyRow.copyText(.waitingForApple), "nothing to copy before a key is certified")
    }

    /// A certified key: its first eight characters as the verifier prints a key, and its whole ID, 64 characters, to copy.
    func testACertifiedKeyShowsTheVerifiersShortFormAndCopiesTheWholeID() {
        let id = Data((0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) })
        let hex = id.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(SigningKeyRow.value(.certified(id)), String(hex.prefix(8)) + "…")
        XCTAssertEqual(SigningKeyRow.copyText(.certified(id)), hex)
        XCTAssertEqual(hex.count, 64)
    }

    // MARK: - The signer

    /// Before the first certification the row waits for Apple; once certified, it shows that key, after a relaunch too.
    func testTheSignerGivesTheCertifiedKeyOrThatItWaitsForApple() async throws {
        let (signer, keys) = try makeSigner()
        let before = await signer.signingKey()
        XCTAssertEqual(before, .waitingForApple, "no key certified yet")
        await signer.certifyIfNeeded(records: [])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        let after = await signer.signingKey()
        XCTAssertEqual(after, .certified(first))
        let relaunched = await relaunch(keys).signingKey()
        XCTAssertEqual(relaunched, .certified(first), "read from the file at the next launch")
    }

    /// A key App Attest lost waits for Apple again while its successor is not certified, and the successor once it is.
    func testAKeyAppAttestLostIsReplacedOnTheRowByTheNextCertifiedKey() async throws {
        let (signer, keys) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let first = try XCTUnwrap(file.read()?.first { $0.kind == .keyCertified }?.key)
        await keys.lose(first.base64EncodedString())
        await keys.failNextAttestations([DCError(.serverUnavailable)])
        await signer.logWritten(generation: 1, events: [event(1)])
        let waiting = await signer.signingKey()
        XCTAssertEqual(waiting, .waitingForApple, "the next key not certified yet")
        await signer.certifyIfNeeded(records: [])
        let second = try XCTUnwrap(file.read()?.filter { $0.kind == .keyCertified }.last?.key)
        XCTAssertNotEqual(second, first)
        let shown = await signer.signingKey()
        XCTAssertEqual(shown, .certified(second))
    }

    /// Where App Attest is not supported this iPhone signs nothing, so Settings shows no row.
    func testNothingIsShownWhereThisIPhoneCannotSign() async throws {
        let (signer, _) = try makeSigner(supported: false)
        await signer.certifyIfNeeded(records: [])
        let shown = await signer.signingKey()
        XCTAssertNil(shown)
    }

    /// Settings (read from the source tree, as built) has the row, read from the signer each time it opens, with Copy for
    /// the whole ID and the footer under it.
    func testSettingsShowsTheRowFromTheSigner() throws {
        let settings = try String(contentsOf: Self.root.appendingPathComponent("Malinois/Views/SettingsView.swift"), encoding: .utf8)
        XCTAssertTrue(settings.contains("@Environment(\\.evidenceExporter) private var exporter"))
        XCTAssertTrue(settings.contains("signingKey = await exporter?.signer.signingKey()"))
        XCTAssertTrue(settings.contains("signingKeySection"))
        XCTAssertTrue(settings.contains("SigningKeyRow.copyText("))
        XCTAssertTrue(settings.contains("UIPasteboard.general.string = whole"))
        XCTAssertTrue(settings.contains("Text(SigningKeyRow.footer)"))
    }

    // MARK: - Helpers

    private func makeSigner(supported: Bool = true) throws -> (EvidenceSigner, FakeKeyService) {
        let keys = FakeKeyService(supported: supported, chain: try TestAttestationChain())
        return (EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.12 (86)", retryAfter: 0), keys)
    }

    private func relaunch(_ keys: FakeKeyService) -> EvidenceSigner {
        EvidenceSigner(file: file, keys: keys, mediaDirectory: media, app: "1.12 (86)", retryAfter: 0)
    }

    private func event(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 11, 7, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }
}
