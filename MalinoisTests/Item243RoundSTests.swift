//
//  Item243RoundSTests.swift
//  MalinoisTests
//
//  Round s, from the third full review of 1.13 (BACKLOG 243; the owner, 2026-11-15: "b as you recommend, wording
//  approved"), for build 90:
//  - the camera permission text said the Vision tripwire works "in memory only"; since 1.13 a slow trip saves the view
//    it compared against (glm-5.3-7), in the owner's approved words;
//  - a set-aside log's Delete retired its note once its entry was written, stored or not (gpt6-astra-1): a note now goes
//    only with a saved log that holds its entry;
//  - the launch's sweep of a share's leftover folders could take a share's ZIP made before it ran (gpt6-astra-3): the
//    launch lists the leftovers first and removes only those;
//  - the watch, coming to the front, did not hand over the alerts it owes once notifications were allowed (gpt6-astra-4);
//  - a cloud record whose start date is not a real date was read, and stopped the log saving (fable-3);
//  - the siren came back from an interruption only on its end, which iOS does not always post (glm-5.3-6);
//  - the recorder's floor (−160 dBFS, no data) after a restart sank the Sound tripwire's bar (glm-5.3-4).
//  Written before the fixes, red at that commit (against compile-only stubs, and a Debug seam that makes the log's save
//  fail); three guards pass there too.
//

import CloudKit
import XCTest
@testable import Malinois

@MainActor
final class Item243RoundSTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let setAsideAt = Date(timeIntervalSince1970: 1_762_520_000)   // the log's name says so

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem243s")
    }

    override func tearDown() {
        EventStore.journalOpenFailsForTesting = false
        EventStore.logSaveFailsForTesting = false
        SirenPlayer.recheckIntervalForTesting = nil
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - The camera permission text (glm-5.3-7)

    /// The text iOS shows at the camera's prompt, in the owner's approved words: a slow trip's view is saved.
    func testTheCameraPermissionTextSaysASlowTripsViewIsSaved() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String,
                       "Malinois captures a photo or short clip as evidence when your unattended device is tampered with. "
                           + "If you turn on the optional Vision tripwire, it also watches the camera's view for movement "
                           + "in memory; if it trips on a slow change, the view it was comparing against is saved with "
                           + "that event.")
    }

    // MARK: - A Delete's note goes only with a saved log that holds its entry (gpt6-astra-1)

    /// The Delete's entry is never stored and Malinois stops: the note is still there, so the next launch writes the entry
    /// under its ID, and the note goes with the save that has it. Never stored: every save of the log is refused, so an
    /// earlier entry's line waits in the journal, and the journal's open is refused, so the Delete's line is not written.
    /// With no journal there, a refused open makes a new one with the Delete's line, the next launch finds the entry
    /// written and retires the note itself, and the save's part goes untested (chain s's undo check, mutation 3).
    func testADeletesNoteStaysUntilASavedLogHoldsItsEntry() async throws {
        let (store, log) = try storeWithASetAsideLog()
        let engine = engine(on: store)
        EventStore.logSaveFailsForTesting = true
        engine.notePINChanged()   // an earlier entry, whose line stays in the journal while no save of the log succeeds
        try await settle(store)
        EventStore.journalOpenFailsForTesting = true
        let outcome = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(outcome, .deleted)
        let entry = try XCTUnwrap(deletionEntries(in: store).first, "the entry, in memory")
        try await settle(store)
        XCTAssertEqual(Self.notes(in: try root())?.map(\.id), [entry.id], "the note stays while no saved log holds its entry")

        EventStore.journalOpenFailsForTesting = false
        EventStore.logSaveFailsForTesting = false
        let relaunched = EventStore()   // Malinois stopped; the next launch
        _ = self.engine(on: relaunched)
        try await waitUntil("the owed entry") { !self.deletionEntries(in: relaunched).isEmpty }
        XCTAssertEqual(deletionEntries(in: relaunched).map(\.id), [entry.id], "written once, under the note's ID")
        relaunched.drainIOForTesting()
        try await waitUntil("the note retired once a saved log holds the entry") { Self.notes(in: try self.root()) == nil }
    }

    /// A Delete that removed nothing writes no entry, and its note goes at once (a guard).
    func testADeleteThatRemovedNothingRetiresItsNoteAtOnce() async throws {
        let (store, log) = try storeWithASetAsideLog()
        let engine = engine(on: store)
        try FileManager.default.removeItem(at: log)   // gone before the Delete: nothing to remove
        _ = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertTrue(deletionEntries(in: store).isEmpty, "no entry for a Delete that removed nothing")
        try await settle(store)
        XCTAssertNil(Self.notes(in: try root()), "its note went at once")
    }

    // MARK: - The launch's sweep of a share's leftovers (gpt6-astra-3)

    /// The launch lists the leftover folders before any share; the background task, later, removes only those, so a
    /// share's ZIP made meanwhile stays.
    func testTheLaunchRemovesOnlyTheExportFoldersItListedBeforeAShare() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("Item243s-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let leftover = folder.appendingPathComponent(EvidenceExporter.folderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: leftover, withIntermediateDirectories: true)
        let listed = EvidenceExporter.leftoverFolders(in: folder)   // at launch, before any share
        let share = folder.appendingPathComponent(EvidenceExporter.folderPrefix + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: share, withIntermediateDirectories: true)
        let zip = share.appendingPathComponent("evidence.zip")
        try Data("a share's ZIP".utf8).write(to: zip)
        EvidenceExporter.remove(listed)   // the background task, later
        XCTAssertFalse(manager.fileExists(atPath: leftover.path), "the leftover went")
        XCTAssertTrue(manager.fileExists(atPath: zip.path), "the share's ZIP stays")
    }

    /// The launch takes the list before its background task, and that task removes only the list (read from the
    /// source: a test cannot launch the app).
    func testTheLaunchListsTheLeftoverExportsBeforeItsBackgroundTask() throws {
        let app = try source("Malinois/MalinoisApp.swift")
        let list = try XCTUnwrap(app.range(of: "let leftoverExports = EvidenceExporter.leftoverFolders()"),
                                 "the list, taken at launch")
        let task = try XCTUnwrap(app.range(of: "Task.detached(priority: .background)"), "the background task")
        XCTAssertLessThan(list.lowerBound, task.lowerBound, "taken before the background task")
        XCTAssertTrue(app.contains("EvidenceExporter.remove(leftoverExports)"), "the task removes only the list")
        XCTAssertFalse(app.contains("EvidenceExporter.removeLeftovers()"), "no sweep of whatever is there by then")
    }

    // MARK: - The watch, coming to the front (gpt6-astra-4)

    /// Once its permission refresh says notifications are allowed, the watch hands over the alerts it owes (read from
    /// the source, as item 219's watch tests are: the watch's target is not in this bundle).
    func testTheWatchHandsOverOwedAlertsWhenItComesToTheFrontWithNotificationsAllowed() throws {
        let delegate = try source("MalinoisWatch/WatchAppDelegate.swift")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let active = try XCTUnwrap(delegate.range(of: "func applicationDidBecomeActive()"), "the foreground's handler")
        let rest = delegate[active.upperBound...]
        let end = rest.range(of: "func ")?.lowerBound ?? rest.endIndex
        XCTAssertTrue(rest[..<end].contains("await requestNotificationPermission() if state.notifications == .allowed { handOwedAlerts() }"),
                      "the owed alerts handed over once notifications are allowed")
    }

    // MARK: - A cloud record whose start is not a real date (fable-3)

    /// Not a number and minus infinity are not dates: neither decoder reads such a record (it then counts among those
    /// this version cannot read); a real date still reads.
    func testACloudRecordWhoseStartIsNotARealDateIsNotRead() {
        func tamper(_ seconds: Double) -> CKRecord {
            let record = CKRecord(recordType: CloudExfiltrator.metaRecordTypeV2)
            record.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
            record.encryptedValues["startDate"] = Date(timeIntervalSinceReferenceDate: seconds) as CKRecordValue
            return record
        }
        func status(_ seconds: Double) -> CKRecord {
            let record = CKRecord(recordType: CloudExfiltrator.stateRecordTypeV2)
            record.encryptedValues["eventID"] = UUID().uuidString as CKRecordValue
            record.encryptedValues["startDate"] = Date(timeIntervalSinceReferenceDate: seconds) as CKRecordValue
            record.encryptedValues["kind"] = "armed" as CKRecordValue
            return record
        }
        let real = Date().addingTimeInterval(-3_600).timeIntervalSinceReferenceDate
        XCTAssertNotNil(CloudExfiltrator.event(from: tamper(real)), "a real date reads")
        XCTAssertNotNil(CloudExfiltrator.stateEvent(from: status(real)), "a real date reads")
        for seconds in [Double.nan, -Double.infinity] {
            XCTAssertNil(CloudExfiltrator.event(from: tamper(seconds)), "\(seconds)")
            XCTAssertNil(CloudExfiltrator.stateEvent(from: status(seconds)), "\(seconds)")
        }
    }

    // MARK: - The siren after an interruption with no end (glm-5.3-6)

    /// iOS silences the alarm for an interruption and posts no end: the alarm comes back by the re-check.
    func testTheSirenComesBackWithNoEndToItsInterruption() {
        SirenPlayer.recheckIntervalForTesting = 0.2
        let siren = SirenPlayer()
        defer { siren.stop() }
        siren.start(rampUp: false)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        siren.silenceForTesting()   // paused for an interruption that posts no end
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm came back with no end to its interruption")
    }

    /// A stopped siren stays stopped: the re-check goes with it (a guard).
    func testAStoppedSirenStaysStopped() {
        SirenPlayer.recheckIntervalForTesting = 0.2
        let siren = SirenPlayer()
        siren.start(rampUp: false)
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "the alarm sounds")
        siren.stop()
        XCTAssertFalse(pump(until: { siren.isPlaying }, timeout: 1), "nothing brings a stopped alarm back")
    }

    // MARK: - The recorder's floor after a restart (glm-5.3-4)

    /// The restarted recorder reads its floor while it says it records: those readings are not samples, so the room,
    /// unchanged, does not trip.
    func testTheRecordersFloorAfterARestartIsNotASample() {
        let (audio, tick, level, tripped) = calibratedSound()
        defer { audio.stop() }
        level.value = -160   // the restarted recorder's first readings
        for _ in 0..<50 { tick() }
        level.value = -50    // the room, unchanged
        for _ in 0..<5 { tick() }
        XCTAssertFalse(tripped.value, "the unchanged room tripped once the floor readings had sunk the bar")
    }

    /// A real sound still trips after such readings (a guard).
    func testARealSoundStillTripsAfterTheFloorReadings() {
        let (audio, tick, level, tripped) = calibratedSound()
        defer { audio.stop() }
        level.value = -160
        for _ in 0..<50 { tick() }
        level.value = -10    // a shout
        tick()
        XCTAssertTrue(tripped.value, "a real sound trips")
    }

    // MARK: - Helpers

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// A Sound tripwire calibrated and warmed up at −50 dBFS, recording, with its tick, its level and whether it tripped.
    private func calibratedSound() -> (AudioMonitor, () -> Void, Box<Double>, Box<Bool>) {
        let audio = AudioMonitor()
        let level = Box(-50.0), tripped = Box(false)
        audio.currentLevelForTesting = { level.value }
        audio.recordingForTesting = { true }
        audio.uptimeForTesting = { 1_000 }
        audio.deactivateAudioSessionForTesting = {}
        audio.onTrip = { _ in tripped.value = true }
        audio.beginCalibration()
        let calibrate = audio.queuedMeterTickForTesting(calibration: true)
        for _ in 0..<5 { calibrate() }
        audio.endCalibration()
        audio.start()
        let tick = audio.queuedMeterTickForTesting(calibration: false)
        for _ in 0..<30 { tick() }   // the warm-up, then the room
        XCTAssertFalse(tripped.value, "the room alone does not trip")
        return (audio, tick, level, tripped)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Turns the main run loop until `condition` holds or `timeout` passes.
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// The store's queue drained, the main actor's follow-ups run, and the queue drained again.
    private func settle(_ store: EventStore) async throws {
        store.drainIOForTesting()
        try await Task.sleep(for: .milliseconds(300))
        store.drainIOForTesting()
    }

    /// The notes' file in `root`, decoded; nil when there is none.
    nonisolated private static func notes(in root: URL) -> [EventStore.SetAsideDeleteOwed]? {
        let url = root.appendingPathComponent(EventStore.setAsideDeletesOwedFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([EventStore.SetAsideDeleteOwed].self, from: data)
    }

    private func root() throws -> URL { try XCTUnwrap(EventStore.rootOverrideForTesting) }

    /// A store whose folder holds a set-aside log of one record, listed.
    private func storeWithASetAsideLog() throws -> (store: EventStore, log: URL) {
        let store = EventStore()
        store.drainIOForTesting()
        let url = try root().appendingPathComponent("events.corrupt-1762520000.json")
        let start = Date(timeIntervalSince1970: 1_762_510_000)
        let record = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion])
        try JSONEncoder().encode([record]).write(to: url)
        store.refreshSetAsideLogs()
        return (store, url)
    }

    /// An engine on `store`, on the free tier, as the screens' rigs make one.
    private func engine(on store: EventStore) -> MonitoringEngine {
        TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                             camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .free),
                                             timing: EngineCharacterizationTests.fastTiming))
    }

    /// The status entries of set-aside logs' Deletes in `store`'s log.
    private func deletionEntries(in store: EventStore) -> [Event] {
        store.events.filter { $0.stateChange.flatMap(Event.setAsideDeleted(kind:)) != nil }
    }

    /// Lets the main run loop turn until `condition` holds; after five seconds, fails, naming what it waited for.
    private func waitUntil(_ what: String, _ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while try !condition() {
            guard clock.now < deadline else { return XCTFail("waited five seconds: \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
