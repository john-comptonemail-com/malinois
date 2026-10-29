//
//  Item152LockedSaveTests.swift
//  MalinoisTests
//
//  1.8.2's step 63 (item 152's lead 7, the security audit's; reproduced on the owner's iPhone Air, BACKLOG 163): a photo or
//  clip whose save starts after the phone has been locked past its grace period was not saved, since the store reopened
//  its own files by path to flush them, which iOS then refuses. The Simulator enforces no Data Protection, so seams stand
//  in for the sealed phone (`EventStore.sealedForTesting`, `clipProtectionRefusedForTesting`); the device test on the Air
//  (the branch `wip/1.8.2-step28-device-test`) checks the real thing. Written before the fix, red at its red commit.
//  BACKLOG 176 (the owner: "as recommended"): the Air's run of that test on the fixed code found the writer asking a
//  sealed phone to change a class it refuses to change (step 64); Codex's look found the retry's and the folder limit's
//  (steps 65 and 66). Each red at its step's red commit, or shown able to fail by its undo check.
//

import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item152LockedSaveTests: XCTestCase {
    private var waiting: URL!
    /// The stores a test made: their queues are drained before the seams are reset, which they read off the main thread.
    private var stores: [EventStore] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestIsolation.setUp(folderPrefix: "MalinoisLockedSave")
        waiting = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("Waiting", isDirectory: true)
        try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
        EventStore.pendingClipsFolderForTesting = waiting
    }

    override func tearDown() {
        for store in stores { store.drainIOForTesting() }   // the gate's ThreadSanitizer pass on 8d776bd: a reset raced them
        stores = []
        EventStore.sealedForTesting = false
        EventStore.clipProtectionRefusedForTesting = false
        EventStore.pendingClipsFolderForTesting = nil
        EventStore.stagedCopyForTesting = nil
        EventStore.killBeforeReplacingForTesting = false
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// Polls until `condition` holds, for at most three seconds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A store this test makes, kept so that `tearDown` drains its queue.
    private func makeStore() -> EventStore {
        let store = EventStore()
        stores.append(store)
        return store
    }

    private func capture(in store: EventStore) -> Event {
        let event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        store.add(event)
        store.drainIOForTesting()
        return event
    }

    /// A clip waiting where the camera leaves its recordings.
    private func waitingClip() throws -> URL {
        let url = waiting.appendingPathComponent(UUID().uuidString + ".mov")
        try Data(count: 4_096).write(to: url)
        return url
    }

    private func savedSize(_ store: EventStore, _ stored: EventStore.StoredMedia) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: store.mediaDirectory.appendingPathComponent(stored.filename).path)
        return (attributes?[.size] as? NSNumber)?.intValue
    }

    /// A photo whose save starts on a sealed phone is kept: the store flushes its files through the handles that wrote
    /// them. Red at the red commit: it reopened its manifest by path to flush it, and the save failed.
    func testAPhotoSavedOnASealedPhoneIsKept() async throws {
        let store = makeStore()
        let event = capture(in: store)
        EventStore.sealedForTesting = true
        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        let saved = try XCTUnwrap(stored, "the photo is saved")
        XCTAssertEqual(savedSize(store, saved), 4)
    }

    /// The same for a clip: saved, and gone from where it waited. Red at the red commit: not saved.
    func testAClipSavedOnASealedPhoneIsKept() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let source = try waitingClip()
        EventStore.sealedForTesting = true
        let stored = await store.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        let saved = try XCTUnwrap(stored, "the clip is saved")
        XCTAssertEqual(savedSize(store, saved), 4_096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "the store took it")
    }

    /// Staging left by an earlier save counts by its size, without opening it, which a sealed phone refuses. Red at the red
    /// commit: the admission opened it, and the save was refused.
    func testStagingLeftByAnEarlierSaveDoesNotStopASealedSave() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data(count: 100).write(to: attachments.appendingPathComponent(UUID().uuidString + ".pending"))
        EventStore.sealedForTesting = true
        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        XCTAssertNotNil(stored, "the earlier staging is counted, not opened")
    }

    /// iOS refuses to raise a waiting clip to the store's protection: the clip stays where it waits, untouched, never
    /// deleted. Red at the red commit: the clip had been moved into staging, and was deleted when the raise failed.
    func testAClipWhoseProtectionIsRefusedStaysWhereItWaits() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let source = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        let stored = await store.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        XCTAssertNil(stored, "not saved yet")
        XCTAssertEqual(try? Data(contentsOf: source).count, 4_096, "the clip waits where it was, whole")
    }

    /// A clip left waiting is not saved again at an unlock, when a capture may be saving: only at the next launch or
    /// deferred load (BACKLOG 176, the owner's ruling). Red at its red commit: the unlock saved it again.
    func testAClipLeftWaitingIsNotSavedAgainAtAnUnlock() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let source = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        _ = await store.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        try await Task.sleep(for: .milliseconds(300))
        store.drainIOForTesting()
        try await Task.sleep(for: .milliseconds(100))   // a recovery's turn on the main actor, had the unlock queued one
        XCTAssertNil(store.events.first { $0.id == event.id }?.mediaFilename, "not attached at the unlock")
        XCTAssertEqual(try? Data(contentsOf: source).count, 4_096, "the clip still waits, whole")
    }

    /// At the next launch, if the app was ended first, that clip is saved and attached to its event. Red at the red
    /// commit: it had been deleted.
    func testAClipLeftWaitingIsAttachedAtTheNextLaunch() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let source = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        _ = await store.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        store.drainIOForTesting()
        let relaunched = makeStore()
        let attached = await eventually { relaunched.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "the clip is attached at the launch")
        let after = try XCTUnwrap(relaunched.events.first { $0.id == event.id })
        XCTAssertEqual(after.primaryCamera, "rear")
        XCTAssertEqual(after.primaryDuration, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "it has left where it waited")
    }

    /// Or at the deferred load: the unlock after a launch while the phone was locked, when the store first reads its
    /// log. Not red at the red commit, which retried there too; its undo check shows it can fail.
    func testAClipLeftWaitingIsAttachedAtTheDeferredLoad() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let source = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        _ = await store.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        store.drainIOForTesting()
        let log = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: log.path)   // sealed, as at a locked launch
        let phone = LockState()
        let relaunched = EventStore(protectedDataAvailable: { phone.unlocked })
        stores.append(relaunched)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log.path)
        phone.unlocked = true
        NotificationCenter.default.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        let attached = await eventually { relaunched.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "the clip is attached at the deferred load")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "it has left where it waited")
    }

    /// A save during which the recovery attaches the save's own file reports that file, which the event keeps: a retry's
    /// recovery at launch can land while a capture saves (BACKLOG 176's codex-1). Red at its red commit: the save found
    /// its slot filled and reported no file, and the capture's response then wrote its copy back without it.
    func testASaveWhoseFileTheRecoveryAttachedMeanwhileReportsIt() async throws {
        let store = makeStore()
        let event = capture(in: store)
        store.attachmentPublishedForTesting = { [unowned store] _, _ in store.recoverMediaAttachmentsForTesting() }
        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        let saved = try XCTUnwrap(stored, "the save reports its file")
        XCTAssertEqual(store.events.first { $0.id == event.id }?.mediaFilename, saved.filename, "which the event holds")
    }

    /// A clip the retry attaches at launch, after the launch's own upload pass found nothing to send, starts a pass of
    /// its own, as a late camera file does, rather than waiting for the next foreground or reconnection (BACKLOG 176's
    /// codex-5). Red at its red commit: nothing asked for one.
    func testAClipAttachedAtLaunchStartsAnUploadPass() async throws {
        let first = makeStore()
        let start = Date().addingTimeInterval(-60)
        let event = Event(startDate: start, endDate: start.addingTimeInterval(1), triggeredSensors: [.motion],
                          cloudSyncState: .synced)   // its record went up without the clip
        first.add(event)
        first.drainIOForTesting()
        let source = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        _ = await first.store(.clip(source), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        first.drainIOForTesting()
        let gate = DispatchSemaphore(value: 0)
        EventStore.stagedCopyForTesting = { _ in _ = gate.wait(timeout: .now() + 5) }   // the retry waits for the launch's pass
        let store = makeStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.simulateConnectivityForTesting(online: true)
        try await Task.sleep(for: .milliseconds(200))   // the launch's pass finds no iCloud and ends
        var uploaded: [UUID] = []
        engine.sweepUploadForTesting = { sent in uploaded.append(sent.id); return (.synced, nil) }
        gate.signal()
        let attached = await eventually { store.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "the retry attached the clip")
        let sent = await eventually { uploaded.contains(event.id) }
        XCTAssertTrue(sent, "and its upload started without another trigger")
    }

    /// A retry that saves a clip but attaches nothing, its event gone, asks for no upload pass (codex-5's fix asks only
    /// when the recovery attached one). Not red at any commit; its undo check shows it can fail.
    func testARetryThatAttachesNothingAsksForNoUploadPass() async throws {
        let source = try waitingClip()
        let stem = UUID().uuidString
        let intent: [String: Any] = ["version": 1, "eventID": UUID().uuidString,   // an event the log does not hold
                                     "startDate": Date().timeIntervalSinceReferenceDate, "secondary": false,
                                     "camera": "rear", "duration": 1.0, "filename": stem + ".mov", "byteCount": 4_096,
                                     "source": source.lastPathComponent]
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: intent).write(to: attachments.appendingPathComponent(stem + ".json"))
        let store = makeStore()
        var asked = false
        store.mediaAttachedLate = { asked = true }   // set before the retry's recovery can take the main actor
        let saved = await eventually { !FileManager.default.fileExists(atPath: source.path) }
        XCTAssertTrue(saved, "the retry saved the clip")
        try await Task.sleep(for: .milliseconds(200))   // the recovery's turn on the main actor
        store.drainIOForTesting()
        XCTAssertFalse(asked, "nothing attached: no pass asked for")
    }

    /// In the Simulator the store's files carry no protection class, as Foundation's protection options set none there:
    /// a class set on the Mac's own volume seals with the Mac's screen lock, and the gate's suite on `0af5bf2` failed 70
    /// times while the Mac was locked. Red at its red commit: the manifest carried the sealed class, or could not be
    /// opened at all.
    func testTheSimulatorSetsNoProtectionClassOnTheStoresFiles() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        XCTAssertNotNil(stored)
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        let manifest = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" }, "the save's manifest")
        let descriptor = open(manifest.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0, "the manifest opens whatever the Mac's lock")
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        XCTAssertNotEqual(fcntl(descriptor, F_GETPROTECTIONCLASS), 2, "no sealed class in the Simulator")
    }

    /// A file the writer creates in one of the store's folders has the store's protection already, from its folder, and
    /// a sealed phone refuses any change of that class, even to the same class (the owner's iPhone Air, 2026-10-28:
    /// EPERM, BACKLOG 176): the writer leaves it as it is. Red at its red commit: the writer always asked, and every save
    /// that started after the lock's grace period failed on the Air.
    func testTheWriterLeavesAFileThatHasTheStoresProtectionAsItIs() {
        var asked = false
        let protected = EventStore.protects(0, currentClass: { _ in EventStore.completeUnlessOpenClass },
                                            setClass: { _ in asked = true; return false })   // refused, as on the Air
        XCTAssertTrue(protected, "the file has the store's protection")
        XCTAssertFalse(asked, "no change asked of a sealed phone")
    }

    /// A file of a weaker class still takes the store's protection, which a sealed phone allows (the Air raised a class C
    /// file to class B), and a refusal fails the write. Not red at the red commit, which always asked; its undo check
    /// shows it can fail.
    func testTheWriterRaisesAFileOfAWeakerClassAndFailsWhenRefused() {
        var asked = 0
        XCTAssertTrue(EventStore.protects(0, currentClass: { _ in 3 }, setClass: { _ in asked += 1; return true }))
        XCTAssertEqual(asked, 1, "a class C file is raised")
        XCTAssertFalse(EventStore.protects(0, currentClass: { _ in 3 }, setClass: { _ in false }), "a refusal fails the write")
        XCTAssertFalse(EventStore.protects(0, currentClass: { _ in -1 }, setClass: { _ in false }),
                       "a class that cannot be read is not taken for the store's")
    }

    /// The attachment folder's entries.
    private func attachmentEntries() throws -> Int {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        return try FileManager.default.contentsOfDirectory(atPath: attachments.path).count
    }

    /// `count` empty staging files in the attachment folder, as interrupted saves leave them.
    private func leftovers(_ count: Int) throws {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        for _ in 0..<count { try Data().write(to: attachments.appendingPathComponent(UUID().uuidString + ".pending")) }
    }

    /// A kill while a save replaces its manifest leaves the replacement's temporary file beside the manifest and the
    /// staging file. A save admitted near the folder's limit must not leave it past the limit, where every later save,
    /// recovery and clean-up refused for good (BACKLOG 176's codex-3). Red at its red commit: a save was admitted with two
    /// entries free, and the kill left 1,201.
    func testAKillWhileASaveReplacesItsManifestLeavesTheFolderWithinItsLimit() async throws {
        let store = makeStore()
        let event = capture(in: store)
        try leftovers(1_198)
        EventStore.killBeforeReplacingForTesting = true
        _ = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        XCTAssertLessThanOrEqual(try attachmentEntries(), 1_200, "within the folder's limit")
    }

    /// A folder left just past its limit, as such a kill left it under the earlier rule, is still read: the intent in it
    /// is recovered, not refused for good (codex-3). Red at its red commit: nothing in it was read.
    func testAFolderLeftJustPastItsLimitIsStillRead() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let stored = await store.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        XCTAssertNotNil(stored, "saved, its intent kept: the caller's update never ran, as after a kill")
        store.drainIOForTesting()
        try leftovers(1_200)   // 1,201 entries with the intent
        let relaunched = makeStore()
        let attached = await eventually { relaunched.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "the intent is read and its photo attached")
    }

    /// A manifest naming a source outside the waiting folder is not followed: only a recording's own name, in the folder
    /// the camera uses, is taken. Not red at the red commit (nothing is retried there); its undo check shows it can fail.
    func testASourceOutsideTheWaitingFolderIsNotTaken() async throws {
        let store = makeStore()
        let event = capture(in: store)
        let outside = waiting.deletingLastPathComponent().appendingPathComponent("outside.mov")
        try Data(count: 4_096).write(to: outside)
        let stem = UUID().uuidString
        let intent: [String: Any] = ["version": 1, "eventID": event.id.uuidString,
                                     "startDate": event.startDate.timeIntervalSinceReferenceDate, "secondary": false,
                                     "camera": "rear", "duration": 1.0, "filename": stem + ".mov", "byteCount": 4_096,
                                     "source": "../outside.mov"]
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: intent).write(to: attachments.appendingPathComponent(stem + ".json"))
        store.drainIOForTesting()
        let relaunched = makeStore()
        try await Task.sleep(for: .milliseconds(300))
        relaunched.drainIOForTesting()
        XCTAssertNil(relaunched.events.first { $0.id == event.id }?.mediaFilename, "nothing attached")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "the file outside is untouched")
    }
}
