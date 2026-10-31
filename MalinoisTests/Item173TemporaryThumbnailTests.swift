//
//  Item173TemporaryThumbnailTests.swift
//  MalinoisTests
//
//  A killed upload can leave its disposable JPG behind. These tests drive launch and
//  the real uploader staging path, replacing only CloudKit's save with its existing seam.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item173TemporaryThumbnailTests: XCTestCase {
    private let fm = FileManager.default
    private let bytes = Data([0xff, 0xd8, 0xff, 0x01])

    private var root: URL {
        (EventStore.rootOverrideForTesting ?? fm.temporaryDirectory).appendingPathComponent("upload-tmp", isDirectory: true)
    }

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem173")
        MainActor.assumeIsolated {
            let directory = (EventStore.rootOverrideForTesting ?? FileManager.default.temporaryDirectory)
                .appendingPathComponent("upload-tmp", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            CloudExfiltrator.thumbnailTempRootForTesting = directory
        }
    }

    override func tearDown() {
        TestIsolation.tearDown()
        MainActor.assumeIsolated { CloudExfiltrator.thumbnailTempRootForTesting = nil }
        super.tearDown()
    }

    private func ownedName() -> String { "malinois-upload-thumbnail-" + UUID().uuidString + ".jpg" }

    @discardableResult
    private func write(_ name: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func launch() {
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        TestIsolation.track(services.engine)
    }

    private func rig() async throws -> (CloudExfiltrator, Event) {
        let policy = CloudEnrollment(file: root.appendingPathComponent(UUID().uuidString + ".json"),
                                     authenticate: { _ in true })
        let cloud = CloudExfiltrator(enrollment: policy)
        cloud.accountIdentityForTesting = { "account-A" }
        let enrolled = await cloud.enrollCloudAccess()
        XCTAssertTrue(enrolled)
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch])
        event.thumbnailData = bytes
        policy.registerLocalEvent(event)
        return (cloud, event)
    }

    private func thumbnailURL(_ records: [CKRecord]) throws -> URL {
        let asset = try XCTUnwrap(records.first?["thumbnail"] as? CKAsset)
        return try XCTUnwrap(asset.fileURL)
    }

    func testLaunchRemovesAnOrphanedUploadThumbnail() throws {
        let orphan = try write(ownedName())
        launch()
        XCTAssertFalse(fm.fileExists(atPath: orphan.path), "The real service construction must run the sweep.")
    }

    func testSweepOnlyRemovesItsOwnDirectRegularFiles() throws {
        let orphan = try write(ownedName())
        let keptNames = [UUID().uuidString + ".jpg", "photo.jpg", "malinois-siren.wav", UUID().uuidString + ".mov",
                         "malinois-upload-thumbnail-not-a-uuid.jpg", ownedName() + ".backup",
                         "outsider-upload-thumbnail-" + UUID().uuidString + ".jpg",
                         "malinois-upload-thumbnail-" + UUID().uuidString + ".JPG",
                         "malinois-upload-thumbnail-" + UUID().uuidString.lowercased() + ".jpg"]
        let kept = try keptNames.map { try write($0) }
        let directory = root.appendingPathComponent(ownedName(), isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let nested = try write(ownedName(), in: directory)
        CloudExfiltrator.sweepOrphanedThumbnails()
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        for url in kept + [directory, nested] {
            XCTAssertTrue(fm.fileExists(atPath: url.path), "Preserve \(url.lastPathComponent).")
        }
    }

    func testSweepPreservesSymbolicLinksAndTheirTargets() throws {
        let target = try write("unrelated.jpg")
        let link = root.appendingPathComponent(ownedName())
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = try write(ownedName(), in: outside)
        let directoryLink = root.appendingPathComponent(ownedName())
        try fm.createSymbolicLink(at: directoryLink, withDestinationURL: outside)
        CloudExfiltrator.sweepOrphanedThumbnails()
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: directoryLink.path), outside.path)
        XCTAssertEqual(try Data(contentsOf: target), bytes)
        XCTAssertEqual(try Data(contentsOf: outsideFile), bytes)
    }

    func testSweepRefusesASymbolicLinkRoot() throws {
        let orphan = try write(ownedName())
        let link = root.deletingLastPathComponent().appendingPathComponent("linked-tmp")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        CloudExfiltrator.sweepOrphanedThumbnails(in: link)
        XCTAssertEqual(try Data(contentsOf: orphan), bytes, "A supplied root cannot redirect deletion through a link.")
    }

    func testSuccessfulUploadNamesAndRemovesItsOwnTemporaryThumbnail() async throws {
        let (cloud, event) = try await rig()
        var staged: URL?
        cloud.saveAttemptForTesting = { records in
            let url = try self.thumbnailURL(records)
            staged = url
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, self.root.standardizedFileURL)
            XCTAssertTrue(url.lastPathComponent.hasPrefix("malinois-upload-thumbnail-"))
            XCTAssertEqual(try Data(contentsOf: url), self.bytes)
        }
        let landed = await cloud.pushFact(event)
        XCTAssertTrue(landed)
        let url = try XCTUnwrap(staged)
        XCTAssertFalse(fm.fileExists(atPath: url.path), "The ordinary completion still deletes the disposable copy.")
        XCTAssertEqual(event.thumbnailData, bytes, "The event keeps the thumbnail used by any later retry.")
    }

    func testFailedUploadAlsoRemovesItsTemporaryThumbnail() async throws {
        let (cloud, event) = try await rig()
        var staged: URL?
        cloud.saveAttemptForTesting = { records in
            staged = try self.thumbnailURL(records)
            throw CKError(.quotaExceeded)
        }
        let outcome = await cloud.exfiltrate(event, fullMediaURL: nil)
        XCTAssertEqual(outcome.syncState, .localOnly)
        let url = try XCTUnwrap(staged)
        XCTAssertFalse(fm.fileExists(atPath: url.path))
        XCTAssertEqual(event.thumbnailData, bytes)
    }

    @MainActor
    private final class HeldUploads {
        var active: [URL] = []
        var releases: [CheckedContinuation<Void, Never>] = []
        var released = false
    }

    func testRepeatedLaunchPreservesBothActiveUploadFiles() async throws {
        let (first, firstEvent) = try await rig()
        let (second, secondEvent) = try await rig()
        let bothStarted = expectation(description: "both thumbnail assets reached save")
        bothStarted.expectedFulfillmentCount = 2
        let uploads = HeldUploads()
        let orphan = try write(ownedName())
        let save: @MainActor ([CKRecord]) async throws -> Void = { records in
            uploads.active.append(try self.thumbnailURL(records))
            guard !uploads.released else { return }
            await withCheckedContinuation { uploads.releases.append($0); bothStarted.fulfill() }
        }
        first.saveAttemptForTesting = save
        second.saveAttemptForTesting = save
        let firstPush = Task { await first.pushFact(firstEvent) }
        let secondPush = Task { await second.exfiltrate(secondEvent, fullMediaURL: nil) }
        await fulfillment(of: [bothStarted], timeout: 5)
        // Keep failed fixture setup from leaving either upload suspended.
        defer { uploads.releases.forEach { $0.resume() }; firstPush.cancel(); secondPush.cancel() }
        XCTAssertEqual(uploads.active.count, 2)
        // Resolve an ancestor alias consistently without treating a live asset as an orphan.
        let alias = root.deletingLastPathComponent().appendingPathComponent("parent-alias", isDirectory: true)
        try fm.createSymbolicLink(at: alias, withDestinationURL: root.deletingLastPathComponent())
        CloudExfiltrator.thumbnailTempRootForTesting = alias.appendingPathComponent("upload-tmp", isDirectory: true)
        launch()
        XCTAssertFalse(fm.fileExists(atPath: orphan.path))
        for url in uploads.active { XCTAssertEqual(try? Data(contentsOf: url), bytes, "A second service graph must keep live assets.") }
        uploads.released = true
        let held = uploads.releases
        uploads.releases.removeAll()
        held.forEach { $0.resume() }
        let firstLanded = await firstPush.value
        let secondOutcome = await secondPush.value
        XCTAssertTrue(firstLanded)
        XCTAssertEqual(secondOutcome.syncState, .synced)
        for url in uploads.active {
            XCTAssertFalse(fm.fileExists(atPath: url.path))
            try bytes.write(to: url)   // A finished upload no longer reserves its old path.
        }
        CloudExfiltrator.sweepOrphanedThumbnails()
        for url in uploads.active { XCTAssertFalse(fm.fileExists(atPath: url.path)) }
    }

    func testMissingSweepDirectoryIsHarmless() {
        let missing = root.appendingPathComponent("not-created", isDirectory: true)
        CloudExfiltrator.sweepOrphanedThumbnails(in: missing)
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
    }
}
