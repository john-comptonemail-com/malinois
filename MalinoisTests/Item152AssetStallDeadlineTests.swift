//
//  Item152AssetStallDeadlineTests.swift
//  MalinoisTests
//
//  BACKLOG 152's lead 2, item 145 step 17 (ADR 0003 amended). Every save attempt raced a fixed 20 s deadline, the
//  clip's CKAsset included, with no progress observed, so a clip that needs more than 20 s to send was cut off on
//  every attempt and every pass, and only its meta record and thumbnail reached iCloud (a 30 s Until clear clip is
//  tens of MB; a 10 Mbps uplink moves about 1.25 MB/s). Now a record carrying an asset races a stall deadline: the
//  20 s restart whenever CloudKit reports progress, within an overall cap; records without an asset keep the fixed
//  20 s. The operation is driven here through a seam at the operation level, since the Simulator has no container.
//  Written before the change, red at that commit (against compile-only stubs).
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item152AssetStallDeadlineTests: XCTestCase {

    // Set in setUp and removed in tearDown, which XCTest runs without main-actor isolation (item 97).
    nonisolated(unsafe) private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem152Stall")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem152Stall-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Helpers

    private struct Rig {
        let cloud: CloudExfiltrator
        let policy: CloudEnrollment
        let event: Event
        let media: URL
    }

    /// A verified installation on "account-A", with a registered incident and a small media file for it.
    private func rig() async throws -> Rig {
        let policy = CloudEnrollment(file: directory.appendingPathComponent("enrollment.json"), authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let enrolled = await cloud.enrollCloudAccess()
        try XCTSkipUnless(enrolled, "the enrollment could not be written")
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        policy.registerLocalEvent(event)
        let media = directory.appendingPathComponent("clip.mov")
        try Data(repeating: 0x4D, count: 4096).write(to: media)
        return Rig(cloud: cloud, policy: policy, event: event, media: media)
    }

    /// Waits for `condition`, yielding the main actor meanwhile (the runner notes a cancel from its own task, up to
    /// one tick after the save has returned).
    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        return condition()
    }

    private func statusEvent() -> Event {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [])
        event.stateChange = "armed"
        return event
    }

    /// Drives a save's operation as CloudKit would (the Simulator has no container): progress every `every` seconds
    /// until `silentAfter` (nil: never silent), finishing with success after `finishAfter` (nil: never), and noting when
    /// the save cancelled it. With `finishSmallRecordsAtOnce`, an operation without an asset finishes at once.
    private final class Runner: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled: [Date] = []
        private var submissions = 0
        private let every: TimeInterval
        private let silentAfter: TimeInterval?
        private let finishAfter: TimeInterval?
        private let finishSmallRecordsAtOnce: Bool

        init(every: TimeInterval, silentAfter: TimeInterval?, finishAfter: TimeInterval?, finishSmallRecordsAtOnce: Bool = true) {
            self.every = every
            self.silentAfter = silentAfter
            self.finishAfter = finishAfter
            self.finishSmallRecordsAtOnce = finishSmallRecordsAtOnce
        }

        var cancelledAt: [Date] { lock.withLock { cancelled } }
        var submitted: Int { lock.withLock { submissions } }

        func run(_ op: CKModifyRecordsOperation) {
            lock.withLock { submissions += 1 }
            let records = op.recordsToSave ?? []
            let finish = (finishSmallRecordsAtOnce && !CloudExfiltrator.carriesAsset(records)) ? 0 : finishAfter
            let began = Date()
            Task.detached { [self] in
                var progress = 0.0
                while !op.isCancelled {
                    let elapsed = Date().timeIntervalSince(began)
                    if let finish, elapsed >= finish {
                        for record in records { op.perRecordSaveBlock?(record.recordID, .success(record)) }
                        op.modifyRecordsResultBlock?(.success(()))
                        return
                    }
                    if silentAfter.map({ elapsed < $0 }) ?? true {
                        progress = min(progress + 0.01, 0.99)
                        for record in records { op.perRecordProgressBlock?(record, progress) }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(every * 1_000_000_000))
                }
                lock.withLock { cancelled.append(Date()) }
            }
        }
    }

    // MARK: - The rule

    /// A photo or clip's record carries an asset, and so does a meta record with a thumbnail; a status record, or a
    /// meta record without one, does not.
    func testTheRuleTellsRecordsWithAnAssetApart() throws {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        let media = directory.appendingPathComponent("still.jpg")
        try Data(repeating: 0x4A, count: 16).write(to: media)
        XCTAssertTrue(CloudExfiltrator.carriesAsset([CloudExfiltrator.makePhotoRecord(event, mediaURL: media, suffix: "photo-front")]))
        XCTAssertTrue(CloudExfiltrator.carriesAsset([CloudExfiltrator.makeMetaRecord(event, deviceName: "x", thumbnailURL: media)]),
                      "the thumbnail is an asset too")
        XCTAssertFalse(CloudExfiltrator.carriesAsset([CloudExfiltrator.makeMetaRecord(event, deviceName: "x", thumbnailURL: nil)]))
        XCTAssertFalse(CloudExfiltrator.carriesAsset([CloudExfiltrator.makeStateRecord(event, kind: "armed", deviceName: "x")]))
        XCTAssertFalse(CloudExfiltrator.carriesAsset([]))
    }

    /// The production numbers: a 20 s stall, a 10-minute cap for an asset.
    func testTheProductionDeadlines() {
        XCTAssertEqual(CloudExfiltrator.saveAttemptDeadline, 20)
        XCTAssertEqual(CloudExfiltrator.assetSaveCap, 600)
    }

    // MARK: - The stall deadline

    /// Progress keeps an asset's save alive past the stall: a clip that keeps moving lands.
    func testProgressKeepsAnAssetSaveAlive() async throws {
        let rig = try await rig()
        rig.cloud.saveDeadlinesForTesting = (stall: 0.2, assetCap: 5)
        let runner = Runner(every: 0.05, silentAfter: nil, finishAfter: 0.6)   // three stalls' worth of progress
        rig.cloud.submitForTesting = runner.run
        let outcome = await rig.cloud.exfiltrate(rig.event, fullMediaURL: rig.media)
        XCTAssertEqual(outcome.syncState, .synced, "the clip landed after 0.6 s of progress")
        XCTAssertTrue(runner.cancelledAt.isEmpty, "nothing was cut off")
        XCTAssertEqual(runner.submitted, 2, "the meta record and the photo record, one attempt each")
    }

    /// Silence past the stall still cancels the attempt as a network-class failure, as the fixed deadline did: the
    /// attempt is retried, and the sweep hears a transient failure.
    func testSilencePastTheStallCancelsTheAttemptAsTransient() async throws {
        let rig = try await rig()
        rig.cloud.saveDeadlinesForTesting = (stall: 0.2, assetCap: 5)
        let runner = Runner(every: 0.05, silentAfter: 0.1, finishAfter: nil)   // progress for 0.1 s, then nothing
        rig.cloud.submitForTesting = runner.run
        let began = Date()
        let outcome = await rig.cloud.exfiltrate(rig.event, fullMediaURL: rig.media)
        XCTAssertEqual(outcome.syncState, .pending, "the meta landed; the clip waits for the sweep")
        let threeCancels = await waitFor({ runner.cancelledAt.count == 3 }, timeout: 2)
        XCTAssertTrue(threeCancels, "each attempt cancelled past the stall: \(runner.cancelledAt.count)")
        let first = try XCTUnwrap(runner.cancelledAt.first)
        XCTAssertGreaterThan(first.timeIntervalSince(began), 0.15, "after the stall, not before")
        XCTAssertLessThan(first.timeIntervalSince(began), 1.0, "and not long after")
        XCTAssertEqual(rig.cloud.lastTransientFailure, .init(retryAfter: nil), "network-class, for the sweep")
    }

    /// The cap bounds the whole wait: progress that never ends is cut off at the cap, not at the stall.
    func testTheCapEndsAnAssetSaveThatNeverFinishes() async throws {
        let rig = try await rig()
        rig.cloud.saveDeadlinesForTesting = (stall: 0.2, assetCap: 0.5)
        let runner = Runner(every: 0.05, silentAfter: nil, finishAfter: nil)   // progress for ever
        rig.cloud.submitForTesting = runner.run
        let began = Date()
        let outcome = await rig.cloud.exfiltrate(rig.event, fullMediaURL: rig.media)
        XCTAssertEqual(outcome.syncState, .pending)
        let threeCancels = await waitFor({ runner.cancelledAt.count == 3 }, timeout: 2)
        XCTAssertTrue(threeCancels, "each attempt cancelled at the cap: \(runner.cancelledAt.count)")
        let first = try XCTUnwrap(runner.cancelledAt.first)
        XCTAssertGreaterThan(first.timeIntervalSince(began), 0.45, "the cap, not the stall")
        XCTAssertLessThan(first.timeIntervalSince(began), 1.5)
    }

    /// A record without an asset keeps the fixed deadline: progress, if any, does not extend it.
    func testASmallRecordKeepsTheFixedDeadline() async throws {
        let rig = try await rig()
        rig.cloud.saveDeadlinesForTesting = (stall: 0.2, assetCap: 5)
        let runner = Runner(every: 0.05, silentAfter: nil, finishAfter: nil, finishSmallRecordsAtOnce: false)
        rig.cloud.submitForTesting = runner.run
        let event = statusEvent()
        rig.policy.registerLocalEvent(event)
        let began = Date()
        let landed = await rig.cloud.pushStateChange(event)
        XCTAssertFalse(landed)
        let threeCancels = await waitFor({ runner.cancelledAt.count == 3 }, timeout: 2)
        XCTAssertTrue(threeCancels, "each attempt cancelled at the fixed deadline: \(runner.cancelledAt.count)")
        let first = try XCTUnwrap(runner.cancelledAt.first)
        XCTAssertLessThan(first.timeIntervalSince(began), 0.45, "the fixed deadline: progress did not extend it")
    }
}
