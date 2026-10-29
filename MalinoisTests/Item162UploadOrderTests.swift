//
//  Item162UploadOrderTests.swift
//  MalinoisTests
//
//  BACKLOG 162's A10 (Codex's codex-2 on 1.8.1; 1.8.2's step 14). Each push for an incident looked up the iCloud
//  identity before it joined the event's upload queue, so the queue ordered the writes by when their lookups answered,
//  not by when they were asked for; and the pending sweep pushed the copy of each event it read at its pass's start.
//  For an event without a photo or clip, the fact and the fuller record both carry revision 1, which `mayWrite` lets
//  through, so an older copy could land last and take back, in the iCloud copy, the details added after the trip (why
//  the capture failed, the wrong PINs typed meanwhile). Now a push joins the queue first and looks up the identity at
//  its turn, and writes the event as the engine's log holds it then. The first test is Codex's probe A, on the
//  existing seams; the second, an older copy such as the sweep's; the third, the engine's wiring of its log. Written
//  before the change, red at that commit.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item162UploadOrderTests: XCTestCase {

    // Set in setUp and removed in tearDown, which XCTest runs without main-actor isolation (item 97).
    nonisolated(unsafe) private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem162Order")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem162Order-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    /// The meta records the saves sent, in order, read back as a receiving device reads them.
    @MainActor
    private final class Sent {
        private(set) var events: [Event] = []
        func add(_ records: [CKRecord]) { events += records.compactMap(CloudExfiltrator.event(from:)) }
    }

    /// Identity lookups, the first one held until the test answers it.
    @MainActor
    private final class Lookups {
        private(set) var count = 0
        private var held: CheckedContinuation<String?, Never>?
        var holdingTheFirst: Bool { held != nil }
        func next() async -> String? {
            count += 1
            guard count == 1 else { return "account-A" }
            return await withCheckedContinuation { held = $0 }
        }
        func answerTheFirst() {
            held?.resume(returning: "account-A")
            held = nil
        }
    }

    /// A verified installation on "account-A", the trip's sparse fact registered to it, and what the saves send.
    private func rig() async throws -> (cloud: CloudExfiltrator, fact: Event, sent: Sent) {
        let policy = CloudEnrollment(file: directory.appendingPathComponent("enrollment.json"), authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let enrolled = await cloud.enrollCloudAccess()
        try XCTSkipUnless(enrolled, "the enrollment could not be written")
        let fact = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        policy.registerLocalEvent(fact)
        let sent = Sent()
        cloud.saveAttemptForTesting = { records in sent.add(records) }
        return (cloud, fact, sent)
    }

    /// The fact with what the trip added after it: the capture failed, and two wrong PINs were typed.
    private func fuller(_ fact: Event) -> Event {
        var event = fact
        event.captureFailure = CaptureFailureReason.captureFailed.rawValue
        event.wrongPINCount = 2
        return event
    }

    /// Waits for `condition`, yielding the main actor meanwhile, so the pushes under test run.
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    // MARK: - The order

    /// Codex's probe A: the fact's identity lookup is slow; meanwhile the capture fails, two wrong PINs are typed and
    /// the fuller push starts. Its own lookup answered at once, so it landed first, and the fact landed after it,
    /// taking those details back out of the iCloud copy. Now the fuller push waits behind the fact in the event's
    /// queue, and the last record written is the fuller one.
    func testASlowLookupCannotPutTheFactAfterTheFullerRecord() async throws {
        let (cloud, fact, sent) = try await rig()
        let lookups = Lookups()
        cloud.accountIdentityForTesting = { await lookups.next() }
        let factPush = Task { await cloud.pushFact(fact) }
        let held = await waitFor({ lookups.holdingTheFirst }, timeout: 2)
        XCTAssertTrue(held, "the fact's lookup is held")
        let fullerPush = Task { await cloud.exfiltrate(fuller(fact), fullMediaURL: nil) }
        _ = await waitFor({ !sent.events.isEmpty }, timeout: 0.5)   // as far as the fuller push gets meanwhile
        lookups.answerTheFirst()
        let factLanded = await factPush.value
        let fullerOutcome = await fullerPush.value
        XCTAssertTrue(factLanded)
        XCTAssertEqual(fullerOutcome.syncState, .synced)
        XCTAssertEqual(sent.events.count, 2, "the fact and the fuller record, one save each")
        XCTAssertEqual(sent.events.last?.captureFailure, CaptureFailureReason.captureFailed.rawValue,
                       "the iCloud copy keeps why the capture failed")
        XCTAssertEqual(sent.events.last?.wrongPINCount, 2, "and the wrong PINs")
    }

    // MARK: - The copy

    /// The pending sweep pushes the copy of each event it read at its pass's start; the trip may have added details
    /// since, and its fuller record may already be in iCloud. A push now writes the event as the log holds it when its
    /// turn comes, so an older copy, the full push's or a fact re-push's, cannot take them back.
    func testAPushWritesTheLogsCopyNotAnOlderOne() async throws {
        let (cloud, fact, sent) = try await rig()
        let logged = fuller(fact)
        cloud.storedEvent = { $0 == logged.id ? logged : nil }
        let outcome = await cloud.exfiltrate(fact, fullMediaURL: nil)   // an older copy, as the sweep's
        XCTAssertEqual(outcome.syncState, .synced)
        let landed = await cloud.pushFact(fact)
        XCTAssertTrue(landed)
        XCTAssertEqual(sent.events.count, 2, "one save each")
        for record in sent.events {
            XCTAssertEqual(record.captureFailure, CaptureFailureReason.captureFailed.rawValue, "the log's copy went up")
            XCTAssertEqual(record.wrongPINCount, 2)
        }
    }

    /// The engine hands the uploader its log at init: the copy a push reads at its turn is the log's, as it is then.
    func testTheEngineHandsTheUploaderItsLog() {
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        store.add(event)
        event.wrongPINCount = 2
        store.update(event)
        XCTAssertEqual(cloud.storedEvent(event.id)?.wrongPINCount, 2, "the log's copy, as it is now")
        XCTAssertNil(cloud.storedEvent(UUID()), "nothing for an event the log does not hold")
        _ = engine
    }
}
