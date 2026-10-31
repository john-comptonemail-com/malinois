//
//  Item180ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG item 180: the full review of 1.9 (80) by Fable and DeepSeek. The owner's batch (2026-10-29, "yes, go ahead
//  with that batch"): the alert extensions' privacy manifests (A5) and the launch sweep that could remove a clip still
//  waiting to be attached (A3). The until-clear clip iOS ends on its own (A1) is in EvidenceCapturePipelineTests, and
//  the iCloud read with no deadline (A2) in Item166ReviewTests, beside the rigs they use.
//

import Foundation
import XCTest
@testable import Malinois

@MainActor
final class Item180ReviewTests: XCTestCase {
    private var waiting: URL!
    /// The stores a test made: their queues are drained before the seams are reset, which they read off the main thread.
    private var stores: [EventStore] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        TestIsolation.setUp(folderPrefix: "MalinoisItem180Review")
        waiting = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("Waiting", isDirectory: true)
        try FileManager.default.createDirectory(at: waiting, withIntermediateDirectories: true)
        EventStore.pendingClipsFolderForTesting = waiting
    }

    override func tearDown() {
        for store in stores { store.drainIOForTesting() }
        stores = []
        EventStore.clipProtectionRefusedForTesting = false
        EventStore.pendingClipsFolderForTesting = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    /// Polls until `condition` holds, for at most three seconds.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

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

    /// A save iOS refuses to protect (1.8.2's step 63): its clip stays waiting, named by the intent the save wrote.
    private func clipLeftWaiting(in store: EventStore) async throws -> (event: Event, clip: URL) {
        let event = capture(in: store)
        let clip = try waitingClip()
        EventStore.clipProtectionRefusedForTesting = true
        let stored = await store.store(.clip(clip), ext: "mov", attachingTo: event, camera: "rear", duration: 1)
        EventStore.clipProtectionRefusedForTesting = false
        store.drainIOForTesting()
        XCTAssertNil(stored, "the save was refused: the clip waits, named by its intent")
        return (event, clip)
    }

    /// A launch a month and a day after the clips were recorded: past the sweep's month.
    private static var aMonthLater: Date { Date().addingTimeInterval(31 * 86_400) }

    // MARK: - A5: the alert extensions' privacy manifests

    /// claude-fable-13 and DeepSeek-1 on 296bab0: both alert extensions count a burst of alerts in UserDefaults since
    /// 1.8.2, a required-reason API, and carried no privacy manifest of their own, as the watch app had not before item
    /// 120's F17. Each now declares it, as the watch app does: reason CA92.1, data only it reads. Read from the
    /// extensions as built into this app. Red at its red commit: neither had a manifest.
    func testBothAlertExtensionsDeclareTheirUserDefaultsUse() throws {
        for path in ["PlugIns/MalinoisNotificationService.appex",
                     "Watch/MalinoisWatch.app/PlugIns/MalinoisWatchNotificationService.appex"] {
            let bundle = Bundle.main.bundleURL.appendingPathComponent(path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Info.plist").path),
                          "\(path) is not built into this app")
            let data = try Data(contentsOf: bundle.appendingPathComponent("PrivacyInfo.xcprivacy"))
            let manifest = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
            XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false, path)
            XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "\(path) collects nothing")
            let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
            let defaults = try XCTUnwrap(apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" },
                                         "\(path) does not declare UserDefaults")
            XCTAssertEqual(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"], path)
        }
    }

    // MARK: - A3: the launch sweep and the clips still waiting

    /// DeepSeek-4 on 296bab0: the launch sweep removed every pending clip over a month old (item 108's F8), though 1.8.2's
    /// step 63 leaves a refused save's clip waiting there, named by its intent, for the next unlocked launch to save. A
    /// clip that waited that long (no unlocked launch since) was removed before the store could attach it, and the event
    /// kept only its storage failure. Now the sweep keeps every clip an intent names, and that launch still attaches it.
    /// Red at its red commit: the clip was removed.
    func testTheLaunchSweepKeepsAMonthOldClipThatAnIntentNames() async throws {
        let store = makeStore()
        let (event, clip) = try await clipLeftWaiting(in: store)
        CameraController.sweepPendingClipsAtLaunch(in: waiting, now: Self.aMonthLater)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path), "kept for the next unlocked launch")
        let relaunched = makeStore()
        let attached = await eventually { relaunched.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "and that launch attaches it")
    }

    /// A month-old clip no intent names is one no path will attach: with every intent readable, the sweep still removes
    /// it (item 108's F8). Passes at the red commit too: its undo check shows it can fail.
    func testTheLaunchSweepStillRemovesAMonthOldClipNothingNames() async throws {
        let store = makeStore()
        _ = try await clipLeftWaiting(in: store)   // an intent the sweep reads, naming another clip
        let stray = try waitingClip()
        CameraController.sweepPendingClipsAtLaunch(in: waiting, now: Self.aMonthLater)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path), "the stray is removed")
    }

    /// An intent the sweep cannot read (while the phone is locked the store's files are sealed) might name any of the clips:
    /// the sweep then removes nothing, the stray included, until a launch that can read them all. Red at its red commit:
    /// both clips were removed.
    func testTheLaunchSweepRemovesNothingWhenAnIntentCannotBeRead() async throws {
        let store = makeStore()
        let (_, kept) = try await clipLeftWaiting(in: store)
        let stray = try waitingClip()
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        let intents = try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(intents.count, 1, "the refused save's intent")
        let sealed = try XCTUnwrap(intents.first)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sealed.path) }
        CameraController.sweepPendingClipsAtLaunch(in: waiting, now: Self.aMonthLater)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), "the waiting clip stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "and so does the stray, until the intents can be read")
    }

    // MARK: - The review of the fixes (Codex and DeepSeek on ee565c2)

    /// The store's attachment intents, as `MediaAttachments` holds them.
    private func intents() throws -> [URL] {
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        return try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    /// codex-1 on ee565c2: the store's checkpoint, which every save on a log read whole runs, removed an unattached
    /// intent over a month old unless its capture was already in `Media`; a waiting clip's is not. So a save before the
    /// clip's retry (at the next unlocked launch: the journal's recovery, the count limits' trims, another attachment's
    /// recovery; or a month into a run that never relaunched) removed the intent, the clip had nothing to be saved from,
    /// and A3's keeping of it came to nothing. Now an intent whose clip still waits is kept. Red at its red commit: the
    /// intent was removed, and the next launch could not attach the clip.
    func testASaveKeepsTheMonthOldIntentOfAClipStillWaiting() async throws {
        let (event, clip) = try await clipLeftWaiting(in: makeStore())
        EventStore.clipProtectionRefusedForTesting = true   // the next launch's retry is refused again
        let store = makeStore()   // that launch, which reads the log whole
        store.drainIOForTesting()
        EventStore.clipProtectionRefusedForTesting = false
        let monthOld = Date().addingTimeInterval(-31 * 86_400)
        let waitingIntents = try intents()
        XCTAssertFalse(waitingIntents.isEmpty, "the clip's intent")
        for file in waitingIntents + [clip] {
            try FileManager.default.setAttributes([.modificationDate: monthOld], ofItemAtPath: file.path)
        }
        store.flush()   // any save runs the checkpoint
        store.drainIOForTesting()
        XCTAssertFalse(try intents().isEmpty, "the intent of a clip still waiting is kept")
        let relaunched = makeStore()
        let attached = await eventually { relaunched.events.first { $0.id == event.id }?.mediaFilename != nil }
        XCTAssertTrue(attached, "and the next launch attaches the clip")
    }

    /// codex-1: a waiting clip the checkpoint cannot look at (its folder unreadable) might still be there: its intent is
    /// kept, as one the store cannot read is. Passes at the fix; its undo check shows it can fail.
    func testASaveKeepsTheIntentOfAClipItCannotLookAt() async throws {
        let (_, clip) = try await clipLeftWaiting(in: makeStore())
        EventStore.clipProtectionRefusedForTesting = true
        let store = makeStore()
        store.drainIOForTesting()
        EventStore.clipProtectionRefusedForTesting = false
        let monthOld = Date().addingTimeInterval(-31 * 86_400)
        for file in try intents() + [clip] {
            try FileManager.default.setAttributes([.modificationDate: monthOld], ofItemAtPath: file.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: waiting.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: waiting.path) }
        store.flush()
        store.drainIOForTesting()
        XCTAssertFalse(try intents().isEmpty, "kept: the clip it names might still be there")
    }

    /// codex-3 on ee565c2 (deepseek-1): a recording that finished before its stop with no file left (iOS never wrote one,
    /// or a full disk took it) was not noted as ended: A1 noted only a finish with a file, so the until-clear loop waited
    /// to its ceiling, folding later trips into a capture that then failed. Now any finish of the current recording
    /// before its stop is noted. Red at its red commit: it was not.
    func testARecordingThatEndsBeforeItsStopWithNoFileIsNotedAsEnded() async {
        let camera = CameraController()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        camera.finishRecordingBeforeItsStopForTesting(at: missing, failure: CocoaError(.fileWriteOutOfSpace))
        let ended = await camera.clipRecordingEndedOnItsOwn()
        XCTAssertTrue(ended, "noted as ended, though no file was left")
    }

    /// The control: a recording that finished before its stop with its file is noted as ended, as A1 made it. Passes at
    /// the red commit too.
    func testARecordingThatEndsBeforeItsStopWithItsFileIsNotedAsEnded() async throws {
        let camera = CameraController()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data(count: 1_024).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        camera.finishRecordingBeforeItsStopForTesting(at: file, failure: nil)
        let ended = await camera.clipRecordingEndedOnItsOwn()
        XCTAssertTrue(ended, "noted as ended")
    }
}
