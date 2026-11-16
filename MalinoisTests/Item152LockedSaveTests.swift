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

import os
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item152LockedSaveTests: XCTestCase {
    private var waiting: URL!
    /// The stores a test made: their queues are drained before the seams are reset, which they read off the main thread.
    private var stores: [EventStore] = []

    // The async forms, so that they run on the main actor with the class's state, as Item140WatchPairingTests' do
    // (item 181's point 2: from the synchronous overrides, which are nonisolated, Swift warned of each access).
    override func setUp() async throws {
        try await super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisLockedSave")
        waiting = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("Waiting", isDirectory: true)
        try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
        EventStore.pendingClipsFolderForTesting = waiting
    }

    override func tearDown() async throws {
        for store in stores { store.drainIOForTesting() }   // the gate's ThreadSanitizer pass on 8d776bd: a reset raced them
        stores = []
        EventStore.sealedForTesting = false
        EventStore.clipProtectionRefusedForTesting = false
        EventStore.pendingClipsFolderForTesting = nil
        EventStore.stagedCopyForTesting = nil
        EventStore.killBeforeReplacingForTesting = false
        TestIsolation.tearDown()
        try await super.tearDown()
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

    // MARK: - Share of a set-aside log and a clip still being saved (item 241's gpt6-astra-m1)
    //
    // gpt6-astra's look at round m: Share took the current log's names once, before the ZIP was made, and the launch's
    // retry of a clip a refusal left waiting publishes the clip and names it in the log a moment later. A set-aside log
    // whose bytes name that clip (an edited backup's: the clip's intent gives its name) carried it. Now Share also leaves
    // out what a capture still being saved names, by its intent, read before the log's names (the owner, 2026-11-13: "as
    // you recommend").

    /// The launch's retry held before it publishes the clip: Share's names, taken meanwhile, include the clip. The retry let
    /// go and the clip in the log, a set-aside log's folder made with those names leaves the clip out and carries the photo
    /// only that log names. Red at its red commit: Share's names were the log's alone, which did not have the clip yet.
    func testASetAsideShareLeavesOutAClipTheLaunchIsStillSaving() async throws {
        let first = makeStore()
        let start = Date().addingTimeInterval(-60)
        let event = Event(startDate: start, endDate: start.addingTimeInterval(1), triggeredSensors: [.motion])
        first.add(event)
        first.drainIOForTesting()
        EventStore.clipProtectionRefusedForTesting = true
        _ = await first.store(.clip(try waitingClip()), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        first.drainIOForTesting()
        let clip = try pendingFilename()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }   // never left held, whatever fails first
        // The retry waits before it publishes; the test takes Share's names only once it is there, and a pause that ran out
        // fails the test (gpt6-astra's note on round n: a read before the pause could meet the manifest's rewrite, and
        // one after a timed-out pause could see the clip already in the log).
        let paused = OSAllocatedUnfairLock(initialState: false), timedOut = OSAllocatedUnfairLock(initialState: false)
        EventStore.stagedCopyForTesting = { _ in
            paused.withLock { $0 = true }
            if gate.wait(timeout: .now() + 5) == .timedOut { timedOut.withLock { $0 = true } }
        }
        let store = makeStore()
        let reached = await eventually { paused.withLock { $0 } }
        XCTAssertTrue(reached, "the retry reached its pause")
        XCTAssertNil(store.events.first { $0.id == event.id }?.mediaFilename, "the clip is not in the log yet")
        let taken = await store.mediaSetAsideShareLeavesOut()
        let names = try XCTUnwrap(taken, "Share's names")
        XCTAssertTrue(names.contains(clip), "the clip still being saved is among them: \(names)")
        XCTAssertFalse(timedOut.withLock { $0 }, "the pause held while the names were taken")
        gate.signal()
        let attached = await eventually { store.events.first { $0.id == event.id }?.mediaFilename == clip }
        XCTAssertTrue(attached, "the retry attached the clip")
        XCTAssertFalse(timedOut.withLock { $0 }, "the retry was let go, not timed out")

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Item152-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let own = UUID().uuidString + ".jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: store.mediaDirectory.appendingPathComponent(own))
        var claiming = Event(startDate: start.addingTimeInterval(-3_600), endDate: start.addingTimeInterval(-3_599),
                             triggeredSensors: [.motion])
        claiming.mediaFilename = own
        claiming.secondaryMediaFilename = clip
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([claiming]).write(to: file)
        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: store.mediaDirectory,
                                                           in: out, liveMedia: names))
        let shared = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Media").path)) ?? [])
        XCTAssertEqual(shared, [own], "the photo only the set-aside log names, not the clip the log now names")
    }

    /// What a capture still being saved names cannot be read (a plain file in the intents folder's place): Share has no
    /// names, so the screen makes no ZIP. Red at its red commit: the log's names alone.
    func testASetAsideShareHasNoNamesWhenTheCapturesBeingSavedCannotBeRead() async throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: root.appendingPathComponent("MediaAttachments"))
        let store = makeStore()
        let names = await store.mediaSetAsideShareLeavesOut()
        XCTAssertNil(names, "no names, so no ZIP: \(String(describing: names))")
    }

    // gpt6-astra's look at round n (gpt6-astra-n1): Share's names came from Delete's reader, which answers "unknown" for
    // any file in the intents folder it cannot take for an intent, and the store's own writer leaves such files: a stop
    // between a manifest's write and its rename leaves the writer's temporary, complete, under a fresh name, until the
    // 30-day clean-up. Every set-aside Share then did nothing, silently. Now Share's own reader passes over what recovery
    // never acts on, and still answers "unknown" for a file that is there but cannot be read (the owner, 2026-11-13: "as
    // you recommend").

    /// A stop while a save replaces its manifest (the writer's seam for a kill before the rename) leaves its temporary,
    /// which a relaunch does not clear. Share still has names, the stopped save's among them, and carries a photo only the
    /// set-aside log names. Red at its red commit: the temporary made Share's names unknown, so no ZIP.
    func testASetAsideShareStillHasNamesAfterAStopLeftTheWritersTemporary() async throws {
        let first = makeStore()
        let event = capture(in: first)
        EventStore.killBeforeReplacingForTesting = true
        let stored = await first.store(.still(Data([0xFF, 0xD8, 0xFF, 0xD9])), ext: "jpg", attachingTo: event, camera: "front")
        EventStore.killBeforeReplacingForTesting = false
        XCTAssertNil(stored, "precondition: the save stopped before its manifest's rename")
        first.drainIOForTesting()
        let relaunched = makeStore()
        relaunched.drainIOForTesting()
        let manifests = try intentsFolderJSON()
        let temporaries = manifests.filter { $0.named != $0.stem }
        XCTAssertEqual(temporaries.count, 1, "the writer's temporary is still there after the relaunch: \(manifests)")
        let stopped = try XCTUnwrap(manifests.first { $0.named == $0.stem }, "the stopped save's own manifest: \(manifests)")

        let taken = await relaunched.mediaSetAsideShareLeavesOut()
        let names = try XCTUnwrap(taken, "Share's names are known")
        XCTAssertTrue(names.contains(stopped.filename), "the stopped save's photo among them: \(names)")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Item152-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relaunched.mediaDirectory, withIntermediateDirectories: true)
        let own = UUID().uuidString + ".jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: relaunched.mediaDirectory.appendingPathComponent(own))
        var record = Event(startDate: Date().addingTimeInterval(-3_600), endDate: Date().addingTimeInterval(-3_599),
                           triggeredSensors: [.motion])
        record.mediaFilename = own
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([record]).write(to: file)
        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: relaunched.mediaDirectory,
                                                           in: out, liveMedia: names))
        let shared = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Media").path)) ?? [])
        XCTAssertEqual(shared, [own], "the photo only the set-aside log names")
    }

    /// Files recovery never acts on name nothing for Share: a temporary a stop left half written (under an intent's kind
    /// of name, but no intent), and a file under a name recovery never reads. Share's names are known: the log's.
    /// Red at its red commit: either made them unknown.
    func testASetAsideShareHasNamesPastFilesRecoveryNeverActsOn() async throws {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("{\"version\":1,\"eventI".utf8).write(to: attachments.appendingPathComponent(UUID().uuidString + ".json"))
        try Data("{}".utf8).write(to: attachments.appendingPathComponent("notes.json"))
        let store = makeStore()
        let taken = await store.mediaSetAsideShareLeavesOut()
        XCTAssertEqual(taken, Set<String>(), "known, and nothing being saved")
    }

    /// An intent that is there but cannot be read (here no permission to read it): what it names is not known, so Share
    /// has no names and makes no ZIP. Green at its commit, as before Share's own reader; its undo check shows it can fail.
    func testASetAsideShareHasNoNamesWhenAnIntentCannotBeRead() async throws {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        let stem = UUID().uuidString
        let intent: [String: Any] = ["version": 1, "eventID": UUID().uuidString,
                                     "startDate": Date().timeIntervalSinceReferenceDate, "secondary": false,
                                     "camera": "rear", "duration": 1.0, "filename": stem + ".mov", "byteCount": 4_096]
        let manifest = attachments.appendingPathComponent(stem + ".json")
        try JSONSerialization.data(withJSONObject: intent).write(to: manifest)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: manifest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path) }
        XCTAssertNil(try? Data(contentsOf: manifest), "precondition: it cannot be read")
        let store = makeStore()
        let taken = await store.mediaSetAsideShareLeavesOut()
        XCTAssertNil(taken, "not known, so no ZIP: \(String(describing: taken))")
    }

    /// The store's names for Share include the photos and clips the log names, not only those being saved. Found while
    /// writing the undo list: without it no test saw the log's names dropped. Green at its commit; its undo check shows
    /// it can fail.
    func testASetAsideShareLeavesOutWhatTheLogNames() async throws {
        let store = makeStore()
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion])
        event.mediaFilename = UUID().uuidString + ".jpg"
        event.secondaryMediaFilename = UUID().uuidString + ".mov"
        store.add(event)
        store.drainIOForTesting()
        let taken = await store.mediaSetAsideShareLeavesOut()
        let names = try XCTUnwrap(taken, "Share's names")
        XCTAssertTrue(names.isSuperset(of: event.storedMediaNames), "the log's photo and clip: \(names)")
        XCTAssertEqual(event.storedMediaNames.count, 2, "precondition: both names kept")
    }

    /// The `.json` files in the intents folder, each with its own stem, the stem of the photo or clip its payload names, and
    /// that name: a manifest names its own stem; the writer's temporary names another.
    private func intentsFolderJSON() throws -> [(stem: String, named: String, filename: String)] {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        return try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                      let filename = object["filename"] as? String else { return nil }
                let named = (filename as NSString).deletingPathExtension
                return (stem: url.deletingPathExtension().lastPathComponent, named: named, filename: filename)
            }
    }

    /// The name the save a refusal left undone publishes when the next launch retries it: its intent's.
    private func pendingFilename() throws -> String {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        let intents = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(intents.count, 1, "one save left undone: \(intents)")
        let intent = try XCTUnwrap(intents.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: intent)) as? [String: Any])
        return try XCTUnwrap(object["filename"] as? String, "its name: \(object)")
    }
}
