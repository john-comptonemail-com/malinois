//
//  Item90EventEvidenceTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 1: a record as evidence signing signs it. Its facts come in a fixed order, every one always
//  present, times and lengths in whole milliseconds; its photo or clip files, thumbnail and sensor traces are covered by
//  their hashes. Every stored field of a record is either a fact or named as not evidence, with the reason, so a field
//  added later cannot join the log without that decision. Written before the code, red at that commit (against
//  compile-only stubs).
//

import XCTest
@testable import Malinois

final class Item90EventEvidenceTests: XCTestCase {

    private let id = UUID(uuidString: "6F1E2D3C-4B5A-4978-8695-A4B3C2D1E0F9") ?? UUID()
    private let primary = EvidenceForm.Digest(sha256: Data(repeating: 0xAA, count: 32), bytes: 1_000)
    private let secondary = EvidenceForm.Digest(sha256: Data(repeating: 0xBB, count: 32), bytes: 2_000)

    /// A tamper record with everything a capture can leave on it.
    private var capture: Event {
        var event = Event(id: id, startDate: Date(timeIntervalSince1970: 1_793_000_000.25),
                          endDate: Date(timeIntervalSince1970: 1_793_000_005.5), triggeredSensors: [.motion, .vision],
                          mediaFilename: "front.mov", secondaryMediaFilename: "rear.mov", thumbnailData: Data([1, 2, 3]),
                          primaryCamera: "front", primaryDuration: 5.25, secondaryCamera: "rear", secondaryDuration: 4.0,
                          motionTrace: [0.5, 1.25], audioTrace: [-40.0], visionTrace: [0.125], cloudSyncState: .synced,
                          capturedOffline: true, mediaDiscarded: true,
                          captureFailuresByCamera: ["rear": "clipUnverified", "front": "cameraUnavailable"],
                          wrongPINCount: 2, thermalState: "fair")
        event.keptLocal = true
        event.uploadedMedia = ["front"]
        return event
    }

    /// A status record: no sensors, no capture.
    private var status: Event {
        Event(id: id, startDate: Date(timeIntervalSince1970: 1_793_000_000), endDate: Date(timeIntervalSince1970: 1_793_000_000),
              triggeredSensors: [], stateChange: "armed")
    }

    func testARecordsFactsAreWrittenInTheirFixedOrder() {
        let facts = TestApp.text(EvidenceJSON.object(capture.evidenceFacts).bytes)
        XCTAssertEqual(facts, #"{"startDate":1793000000250,"endDate":1793000005500,"triggeredSensors":["motion","vision"],"#
            + #""stateChange":null,"interrupted":false,"interruptionCause":null,"sustainedCount":null,"wrongPINCount":2,"#
            + #""cancelCount":null,"ownerAttributed":false,"capturedOffline":true,"thermalState":"fair","captureFailure":null,"#
            + #""captureFailuresByCamera":{"front":"cameraUnavailable","rear":"clipUnverified"},"primaryCamera":"front","#
            + #""primaryDuration":5250,"secondaryCamera":"rear","secondaryDuration":4000,"mediaDiscarded":true}"#)
    }

    func testAStatusRecordsFactsSayFalseOrNullForWhatItDoesNotHave() {
        var interrupted = status
        interrupted.stateChange = nil
        interrupted.interrupted = true
        interrupted.interruptionCause = "rebooted"
        interrupted.ownerAttributed = false
        interrupted.cancelCount = 3
        interrupted.captureFailuresByCamera = [:]
        let facts = TestApp.text(EvidenceJSON.object(interrupted.evidenceFacts).bytes)
        XCTAssertEqual(facts, #"{"startDate":1793000000000,"endDate":1793000000000,"triggeredSensors":[],"stateChange":null,"#
            + #""interrupted":true,"interruptionCause":"rebooted","sustainedCount":null,"wrongPINCount":null,"cancelCount":3,"#
            + #""ownerAttributed":false,"capturedOffline":false,"thermalState":null,"captureFailure":null,"#
            + #""captureFailuresByCamera":null,"primaryCamera":null,"primaryDuration":null,"secondaryCamera":null,"#
            + #""secondaryDuration":null,"mediaDiscarded":false}"#)
        XCTAssertEqual(status.evidenceFacts.first { $0.key == "stateChange" }?.value, .string("armed"))
    }

    func testCameraFailuresComeInTheOrderOfTheirNamesNotTheDictionarys() {
        var event = status
        event.captureFailuresByCamera = ["rear": "r", "front": "f", "b": "2", "a": "1", "c": "3"]
        XCTAssertEqual(event.evidenceFacts.first { $0.key == "captureFailuresByCamera" }?.value,
                       .object([EvidenceJSON.Member("a", .string("1")), EvidenceJSON.Member("b", .string("2")),
                                EvidenceJSON.Member("c", .string("3")), EvidenceJSON.Member("front", .string("f")),
                                EvidenceJSON.Member("rear", .string("r"))]))
    }

    func testEveryStoredFieldIsAFactOrNamedAsNotEvidence() {
        let stored = Set(Mirror(reflecting: capture).children.compactMap(\.label))
        let facts = Set(capture.evidenceFacts.map(\.key))
        let notEvidence = Set(Event.notEvidenceFields.keys)
        XCTAssertEqual(capture.evidenceFacts.count, facts.count, "a fact named twice")
        XCTAssertEqual(facts.intersection(notEvidence), [], "a field both a fact and not evidence")
        XCTAssertEqual(stored.subtracting(facts.union(notEvidence)).sorted(), [], "a stored field nobody decided on")
        XCTAssertEqual(facts.union(notEvidence).subtracting(stored).sorted(), [], "a name that is not a stored field")
        for (field, reason) in Event.notEvidenceFields { XCTAssertFalse(reason.isEmpty, field) }
        // The ones the attachments cover, and the identity the statement names, are among them.
        for field in ["id", "mediaFilename", "secondaryMediaFilename", "thumbnailData", "motionTrace", "audioTrace", "visionTrace"] {
            XCTAssertNotNil(Event.notEvidenceFields[field], field)
        }
    }

    func testTheAttachmentsCoverTheFilesTheThumbnailAndTheTraces() {
        let attachments = capture.evidenceAttachments(primary: primary, secondary: secondary)
        XCTAssertEqual(attachments.map(\.name), ["primary", "secondary", "thumbnail", "motionTrace", "audioTrace", "visionTrace"])
        guard attachments.count == 6 else { return }
        XCTAssertEqual(attachments[0].digest, primary)
        XCTAssertEqual(attachments[1].digest, secondary)
        XCTAssertEqual(attachments[2].digest, EvidenceForm.Digest(sha256: TestApp.sha256(Data([1, 2, 3])), bytes: 3))
        let motion = doubles([0.5, 1.25])
        XCTAssertEqual(attachments[3].digest, EvidenceForm.Digest(sha256: TestApp.sha256(motion), bytes: 16))
        XCTAssertEqual(attachments[4].digest, EvidenceForm.Digest(sha256: TestApp.sha256(doubles([-40.0])), bytes: 8))
        XCTAssertEqual(attachments[5].digest, EvidenceForm.Digest(sha256: TestApp.sha256(doubles([0.125])), bytes: 8))
        // A file whose digest the caller could not read is left out, not guessed at.
        XCTAssertEqual(capture.evidenceAttachments(primary: nil, secondary: secondary).map(\.name),
                       ["secondary", "thumbnail", "motionTrace", "audioTrace", "visionTrace"])
        // A status record has no files, no thumbnail and no samples.
        XCTAssertEqual(status.evidenceAttachments(primary: nil, secondary: nil), [])
    }

    func testARevisionIsTheRecordReadyToSign() throws {
        let record = capture.evidenceRecord(revision: 3, signedAt: Date(timeIntervalSince1970: 1_793_000_006.0004), app: "1.10 (81)",
                                            primary: primary, secondary: secondary)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.revision, 3)
        XCTAssertEqual(record.signedAt, 1_793_000_006_000)
        XCTAssertEqual(record.app, "1.10 (81)")
        XCTAssertEqual(record.facts, capture.evidenceFacts)
        XCTAssertEqual(record.attachments, capture.evidenceAttachments(primary: primary, secondary: secondary))
        XCTAssertEqual(try EvidenceForm.read(EvidenceForm.bytes(.record(record))), .record(record))
    }

    func testATimeOrLengthNoWholeMillisecondCanHoldIsNull() {
        var damaged = capture
        damaged.endDate = Date(timeIntervalSince1970: 1e300)
        damaged.primaryDuration = .nan
        damaged.secondaryDuration = .infinity
        let facts = damaged.evidenceFacts
        XCTAssertEqual(facts.first { $0.key == "endDate" }?.value, .null)
        XCTAssertEqual(facts.first { $0.key == "primaryDuration" }?.value, .null)
        XCTAssertEqual(facts.first { $0.key == "secondaryDuration" }?.value, .null)
        XCTAssertEqual(facts.first { $0.key == "startDate" }?.value, .int(1_793_000_000_250))
    }

    /// Samples as IEEE 754 doubles, big-endian, written here without the code under test.
    private func doubles(_ samples: [Double]) -> Data {
        Data(samples.flatMap { withUnsafeBytes(of: $0.bitPattern.bigEndian, Array.init) })
    }
}
