//
//  Item120ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG 120 (1.7 (70), the top-down review of 69), the fixes below the screens.
//  F5: an event log that will not decode is set aside and a fresh log starts; a later launch deleted
//  the set-aside log once it was 30 days old (or once three newer ones existed), and the same
//  launch's media sweep then deleted every photo and clip only it referred to. Build 70's stopgap:
//  nothing deletes them automatically (item 122 holds the rest). Driven through the real path: a
//  photo captured by the engine, the log damaged, launches that set it aside and then read the
//  fresh log cleanly. F6: the armed screen's press flag was cleared only when the touch ended, so a
//  touch iOS cancelled left it set and later taps recorded nothing. F7: Share offers Save Image and
//  Save Video, and iOS ends an app that saves to the photo library without a reason in its
//  Info.plist. F17: the watch app reads its settings with UserDefaults and had no privacy manifest.
//  Written before the fixes, red at that commit.
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item120ReviewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item120ReviewTests")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let day: TimeInterval = 86_400

    // MARK: - F5: a set-aside log and its media are kept

    /// A photo captured while armed, then the log damaged: one launch sets the log aside, and a month
    /// later a launch that reads the fresh log cleanly runs the media sweep. The set-aside log and the
    /// photo only it refers to are both still there.
    func testALaunchKeepsAMonthOldSetAsideLogAndThePhotoOnlyItRefersTo() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let photo = try capturePhoto().photo
        let photoURL = root.appendingPathComponent("Media").appendingPathComponent(photo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path), "the capture saved the photo")

        let backup = try damageAndSetAside(root: root, ageInDays: 31)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * Self.day)],
                                              ofItemAtPath: photoURL.path)

        let later = EventStore()
        later.drainIOForTesting()
        XCTAssertFalse(later.logWasQuarantined, "this launch read the fresh log cleanly, so its sweep ran")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(backup).path),
                      "the month-old set-aside log was deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photoURL.path),
                      "the photo only the set-aside log refers to was deleted")
    }

    /// Four set-aside logs, the oldest four days old: a launch used to delete all but the newest three.
    func testALaunchKeepsEverySetAsideLogNotOnlyTheNewestThree() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        var backups: [String] = []
        for age in [4, 3, 2, 1] {
            backups.append(try damageAndSetAside(root: root, ageInDays: Double(age)))
        }
        let later = EventStore()
        later.drainIOForTesting()
        XCTAssertFalse(later.logWasQuarantined)
        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("events.corrupt-") }
        XCTAssertEqual(Set(kept), Set(backups), "a set-aside log was deleted")
    }

    // MARK: - Codex's look at 70, V1: retention and a set-aside log's photo

    /// The journal and an attachment intent can bring an event back after its log was set aside,
    /// with a photo the set-aside log refers to as well; the byte limit then deleted that photo.
    /// Built as a crash leaves it: the event's birth line in the journal, the capture's attachment
    /// intent and photo, and the log written with the photo and then damaged. A launch sets the log
    /// aside and brings the event back with its photo; the byte limit evicts it. The photo is kept.
    func testTheByteLimitKeepsAPhotoASetAsideLogRefersTo() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let crash = fm.temporaryDirectory.appendingPathComponent("Item120V1-" + UUID().uuidString, isDirectory: true)
        defer {
            EventStore.rootOverrideForTesting = root
            try? fm.removeItem(at: crash)
        }
        try fm.createDirectory(at: crash.appendingPathComponent("Media"), withIntermediateDirectories: true)
        var intentsCopied = false
        let (store, photo) = try capturePhoto { store in
            store.attachmentPublishedForTesting = { _, _ in   // the photo is saved; its intent still stands
                intentsCopied = (try? fm.copyItem(at: root.appendingPathComponent("MediaAttachments"),
                                                  to: crash.appendingPathComponent("MediaAttachments"))) != nil
            }
        }
        XCTAssertTrue(intentsCopied, "the attachment intent was copied when the photo was published")
        var born = try XCTUnwrap(store.events.first { $0.mediaFilename == photo })
        born.mediaFilename = nil
        try XCTUnwrap(EventStore.journalLine(for: born)).write(to: crash.appendingPathComponent("events.journal"))
        try fm.copyItem(at: root.appendingPathComponent("Media").appendingPathComponent(photo),
                        to: crash.appendingPathComponent("Media").appendingPathComponent(photo))
        var damaged = try Data(contentsOf: root.appendingPathComponent("events.json"))
        damaged.append(Data("damaged".utf8))   // still names the photo; no longer decodes
        try damaged.write(to: crash.appendingPathComponent("events.json"))

        EventStore.rootOverrideForTesting = crash
        let relaunched = EventStore()
        XCTAssertTrue(relaunched.logWasQuarantined, "the damaged log is set aside")
        XCTAssertEqual(relaunched.events.first { $0.id == born.id }?.mediaFilename, photo,
                       "the journal and the intent bring the event back with its photo")
        relaunched.mediaBudgetForTesting = 1
        relaunched.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .localOnly))
        XCTAssertTrue(pump(until: { relaunched.events.first { $0.id == born.id }?.mediaFilename == nil }, timeout: 5),
                      "the byte limit evicts the photo from the current log")
        relaunched.drainIOForTesting()
        XCTAssertTrue(fm.fileExists(atPath: crash.appendingPathComponent("Media").appendingPathComponent(photo).path),
                      "the byte limit deleted a photo the set-aside log refers to")
    }

    /// Guard: with no set-aside log, the byte limit still deletes the photo it evicts.
    func testTheByteLimitStillDeletesAPhotoNoSetAsideLogRefersTo() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let (store, photo) = try capturePhoto()
        let id = try XCTUnwrap(store.events.first { $0.mediaFilename == photo }?.id)
        store.mediaBudgetForTesting = 1
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .localOnly))
        XCTAssertTrue(pump(until: { store.events.first { $0.id == id }?.mediaFilename == nil }, timeout: 5))
        store.drainIOForTesting()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Media").appendingPathComponent(photo).path),
                       "the byte limit kept a photo nothing else refers to")
    }

    // MARK: - F6: a cancelled touch

    /// iOS cancels a touch (the Guided Access triple-click, leaving the app) without ending it, and
    /// the old flag was cleared only when a touch ended, so every later tap was ignored. The press is
    /// now a `GestureState`, which SwiftUI resets when a touch ends AND when iOS cancels it. No unit
    /// test can cancel a real touch, so this checks the mechanism; the device check in the build
    /// report checks the behaviour.
    func testTheArmedScreensPressIsAGestureStateThatACancelledTouchResets() {
        let stored = Mirror(reflecting: ArmedView()).children
        XCTAssertTrue(stored.contains { $0.value is GestureState<Bool> },
                      "the armed screen does not track its press with a GestureState")
        XCTAssertFalse(stored.contains { $0.value is State<Bool> && $0.label == "_pressActive" },
                       "the old flag, cleared only when a touch ends, is still there")
    }

    // MARK: - F7: Save Image and Save Video

    /// iOS ends an app that adds to the photo library without this key; Share offers Save Image and
    /// Save Video. The owner's text (2026-10-15).
    func testTheAppSaysWhyItSavesToThePhotoLibrary() throws {
        let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") as? String,
                                 "no NSPhotoLibraryAddUsageDescription: saving a photo or clip to Photos ends the app")
        XCTAssertEqual(text, "Malinois saves the photos and clips you choose to keep to your photo library.")
    }

    // MARK: - F17: the watch app's privacy manifest

    /// The watch app reads and writes UserDefaults (the last alert, the relayed IDs it has shown), a
    /// required-reason API, so it declares it, as the iPhone app does: reason CA92.1, data only it
    /// reads. Read from the watch app as built into this app.
    func testTheWatchAppDeclaresItsUserDefaultsUse() throws {
        let watchApp = Bundle.main.bundleURL.appendingPathComponent("Watch/MalinoisWatch.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: watchApp.appendingPathComponent("Info.plist").path),
                      "the watch app is not built into this app at \(watchApp.path)")
        let data = try Data(contentsOf: watchApp.appendingPathComponent("PrivacyInfo.xcprivacy"))
        let manifest = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "the watch collects nothing")
        let apis = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        let defaults = try XCTUnwrap(apis.first { $0["NSPrivacyAccessedAPIType"] as? String == "NSPrivacyAccessedAPICategoryUserDefaults" },
                                     "UserDefaults is not declared")
        XCTAssertEqual(defaults["NSPrivacyAccessedAPITypeReasons"] as? [String], ["CA92.1"])
    }

    // MARK: - Helpers

    /// Arms an engine, trips Motion and returns its store and the name of the photo the capture
    /// attached, with the log written, as after an ordinary watch. `prepare` sees the store first.
    private func capturePhoto(prepare: (EventStore) -> Void = { _ in }) throws -> (store: EventStore, photo: String) {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.enabledSensors.insert(.camera)
        settings.captureMode = .photo
        settings.cameraPosition = .front
        let store = EventStore()
        prepare(store)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(),
                                                          entitlements: ProEntitlements(resolvedAs: .free),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { engine.state == .armed }, timeout: 5), "armed")
        engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { store.events.contains { $0.mediaFilename != nil } }, timeout: 5),
                      "the trip's photo is attached")
        engine.disarm()
        store.flush()
        store.drainIOForTesting()
        return (store, try XCTUnwrap(store.events.first { $0.mediaFilename != nil }?.mediaFilename))
    }

    /// Damages the log on disk and launches once: that launch sets it aside and, with one new event,
    /// writes a fresh log for the next launch to read. Returns the set-aside log's name, re-stamped
    /// `ageInDays` old (the stamp in the name is what a launch reads as its age).
    private func damageAndSetAside(root: URL, ageInDays: Double) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)   // before any store has made it
        try Data("not json".utf8).write(to: root.appendingPathComponent("events.json"))
        try? fm.removeItem(at: root.appendingPathComponent("events.journal"))   // nothing newer than the log
        let before = Set(try fm.contentsOfDirectory(atPath: root.path))
        let damaged = EventStore()
        XCTAssertTrue(damaged.logWasQuarantined, "the damaged log is set aside")
        let made = try XCTUnwrap(Set(try fm.contentsOfDirectory(atPath: root.path)).subtracting(before)
            .first { $0.hasPrefix("events.corrupt-") }, "no set-aside log was made")
        let aged = "events.corrupt-\(Int(Date().timeIntervalSince1970 - ageInDays * Self.day)).json"
        try fm.moveItem(at: root.appendingPathComponent(made), to: root.appendingPathComponent(aged))
        damaged.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .localOnly))
        damaged.flush()
        damaged.drainIOForTesting()
        try? fm.removeItem(at: root.appendingPathComponent("events.journal"))
        return aged
    }

    /// Spins the main run loop until `condition` holds or `timeout` passes.
    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}
