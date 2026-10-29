//
//  Item165ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 165, Codex's full review of 1.8.2 at 224a07a (item 163's steps 37 and 38). A1: a limit deleted the media it
//  dropped right after the log write that dropped its reference, whether or not that write succeeded, so a failed
//  write left the log on disk naming a deleted photo, without its "discarded before upload" mark. A2: with Both cameras
//  the arming screen said Vision watches through the front camera also when the camera is kept cold (Battery saver,
//  and Auto on battery), when Vision has nothing to watch through. Each written before its change, red at that commit.
//

import XCTest
@testable import Malinois

final class Item165ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem165Review")
    }

    override func tearDown() {
        TestIsolation.tearDownFolderAndFlags()
        super.tearDown()
    }

    // MARK: - A1: a limit's deletion waits for its log write

    /// Polls until `condition` holds, for at most three seconds.
    @MainActor
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private func onDisk(_ log: URL) throws -> [Event] {
        try JSONDecoder().decode([Event].self, from: Data(contentsOf: log))
    }

    /// A pending photo the byte limit dropped while the log could not be replaced.
    private struct DroppedPhoto {
        let store: EventStore
        let photo: Event
        let file: URL
        let log: URL
        /// The folder's permissions, to put back.
        let permissions: Any
    }

    /// A pending photo the byte limit drops while the log cannot be replaced: the folder read-only, the media folder in
    /// it still writable, so a deletion there succeeds.
    @MainActor
    private func photoDroppedWhileTheLogCannotBeWritten() async throws -> DroppedPhoto {
        let fm = FileManager.default
        let store = EventStore()
        store.mediaBudgetForTesting = 1_000
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let log = root.appendingPathComponent("events.json")
        let at = Date().addingTimeInterval(-60)
        var photo = Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .pending)
        photo.mediaFilename = UUID().uuidString + ".jpg"
        photo.primaryCamera = "front"
        let file = store.mediaDirectory.appendingPathComponent(try XCTUnwrap(photo.mediaFilename))
        try Data(count: 100).write(to: file)
        store.add(photo)
        let firstPassDone = await eventually { store.byteCapPruneIdleForTesting }
        XCTAssertTrue(firstPassDone)
        store.drainIOForTesting()
        XCTAssertEqual(try onDisk(log).first { $0.id == photo.id }?.mediaFilename, photo.mediaFilename, "on disk")

        let permissions = try XCTUnwrap(fm.attributesOfItem(atPath: root.path)[.posixPermissions])
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)   // the log cannot be replaced
        store.mediaBudgetForTesting = 10   // the next pass drops the photo: pending, so marked discarded
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))
        let secondPassDone = await eventually { store.byteCapPruneIdleForTesting }
        XCTAssertTrue(secondPassDone)
        store.drainIOForTesting()
        let failed = await eventually { store.persistDegraded }
        XCTAssertTrue(failed, "the write must actually fail")
        XCTAssertNil(store.events.first { $0.id == photo.id }?.mediaFilename, "dropped in memory")
        return DroppedPhoto(store: store, photo: photo, file: file, log: log, permissions: permissions)
    }

    /// item 165's A1: while the log on disk still names the photo, the photo stays, and a relaunch then finds it there.
    @MainActor
    func testAPhotoALimitDropsStaysWhileTheLogOnDiskNamesIt() async throws {
        let dropped = try await photoDroppedWhileTheLogCannotBeWritten()
        let (store, photo, file, log) = (dropped.store, dropped.photo, dropped.file, dropped.log)
        let root = log.deletingLastPathComponent()
        defer { try? FileManager.default.setAttributes([.posixPermissions: dropped.permissions], ofItemAtPath: root.path) }
        XCTAssertEqual(try onDisk(log).first { $0.id == photo.id }?.mediaFilename, photo.mediaFilename,
                       "the log on disk still names the photo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "so the photo is kept")
        store.drainIOForTesting()
        let relaunched = EventStore()   // the app ended before any write succeeded
        relaunched.drainIOForTesting()
        let named = try XCTUnwrap(relaunched.events.first { $0.id == photo.id }?.mediaFilename, "the relaunch reads it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: relaunched.mediaDirectory.appendingPathComponent(named).path),
                      "and the photo it names is there")
    }

    /// item 165's A1, the control: once a write that no longer names it succeeds, the photo goes, and the log records
    /// the discard before it uploaded, its check owed since item 166's codex-24 (passes before the fix too, which deleted
    /// the photo at once).
    @MainActor
    func testAPhotoALimitDropsGoesOnceTheLogThatDropsItIsWritten() async throws {
        let dropped = try await photoDroppedWhileTheLogCannotBeWritten()
        let (store, photo, file, log) = (dropped.store, dropped.photo, dropped.file, dropped.log)
        try FileManager.default.setAttributes([.posixPermissions: dropped.permissions], ofItemAtPath: log.deletingLastPathComponent().path)
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch], cloudSyncState: .pending))   // it succeeds
        let passDone = await eventually { store.byteCapPruneIdleForTesting }
        XCTAssertTrue(passDone)
        store.drainIOForTesting()
        let recovered = await eventually { !store.persistDegraded }
        XCTAssertTrue(recovered, "the write succeeded")
        let entry = try XCTUnwrap(try onDisk(log).first { $0.id == photo.id })
        XCTAssertNil(entry.mediaFilename, "the log on disk drops the photo")
        XCTAssertEqual(entry.mediaDiscardUnchecked, true,
                       "and records the discard, its check owed (item 166's codex-24: marked once iCloud holds none of it)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "then the photo goes")
    }

    // MARK: - A2: the arming screen's Vision note with Both cameras

    /// item 165's A2: with Both cameras the arming screen said only that Vision watches through the front camera, also
    /// when the camera is kept cold (Battery saver, and Auto on battery). The readiness caveat now comes with the Both
    /// note; the tap's own failure still says only that.
    func testTheVisionNoteSaysWhenTheCameraIsColdWithBothCameras() {
        for readiness in CameraReadiness.allCases {
            let both = ArmingView.visionGuidance(tapUnavailable: false, both: true, readiness: readiness)
            let single = ArmingView.visionGuidance(tapUnavailable: false, both: false, readiness: readiness)
            if readiness == .instant {
                XCTAssertEqual(both, [ArmingView.visionBothNote], "kept warm: \(readiness)")
                XCTAssertEqual(single, [], "kept warm: \(readiness)")
            } else {
                XCTAssertEqual(both, [ArmingView.visionBothNote, ArmingView.visionWarmOnlyNote], "cold on battery: \(readiness)")
                XCTAssertEqual(single, [ArmingView.visionWarmOnlyNote], "cold on battery: \(readiness)")
            }
            XCTAssertEqual(ArmingView.visionGuidance(tapUnavailable: true, both: true, readiness: readiness),
                           [ArmingView.visionUnavailableNote], "the tap's own failure: \(readiness)")
        }
    }
}
