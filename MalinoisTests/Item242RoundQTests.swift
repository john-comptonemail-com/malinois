//
//  Item242RoundQTests.swift
//  MalinoisTests
//
//  Round q, from TestFlight 88's steps (BACKLOG 242; the owner, 2026-11-14: "as you recommend, wording approved").
//  Written before the changes, red at that commit (against compile-only stubs).
//  - Step 8 failed: the iPad's "reinstalled" entry reached iCloud ("iCloud synced") and never showed on the 17 Pro.
//    The 17 Pro's status history was full, and the status budget took another device's copies first, oldest first
//    (ADR 0035), so the entry SECURITY.md promises on the other devices went at once. Other devices' status entries
//    now have a budget of their own (ADR 0088): they no longer compete with this phone's own, and still cannot push
//    them out.
//  - The Vision still in clip mode (a new install's default) took its turn and mirroring from the photo output, which a
//    clip session does not have (item 241's A5): now from the movie output's connection there, as the clip is turned.
//  - The owner's words: the reinstall entry, Settings' Security footer, "Before you arm" with "No one can delete an
//    entry" last, and Voice Control's step on "Before you arm" and on the arming screen.
//

import Combine
import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item242RoundQTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    private static let noCamera = Just(false).eraseToAnyPublisher()

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem242q")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Other devices' status entries: a budget of their own (step 8)

    /// This phone's own status history at its limit, and another device's status entry from the middle of it, as a pull
    /// brings it: nothing goes (the copy went first, at once, before).
    func testAnotherDevicesStatusEntryStaysWhenThisPhonesOwnHistoryIsFull() {
        let own = (0..<EventStore.maxAuditEvents).map { _ in UUID() }
        var rows: [EventStore.EvictionRow] = own.map { .init(id: $0, isSynced: true, isAudit: true) }
        rows.insert(.init(id: UUID(), isSynced: true, isAudit: true, isMirrored: true), at: own.count / 2)
        XCTAssertEqual(evictions(rows), [], "both status budgets within their limits")
    }

    /// Other devices' status entries keep to a limit of their own: one over, the oldest copy goes, and only it.
    func testOtherDevicesStatusEntriesKeepToABudgetOfTheirOwn() throws {
        let own = (0..<EventStore.maxAuditEvents).map { _ in UUID() }
        let copies = (0...EventStore.maxMirroredAuditEvents).map { _ in UUID() }
        // Newest first: the copies are newer than this phone's own entries.
        let rows: [EventStore.EvictionRow] = copies.map { .init(id: $0, isSynced: true, isAudit: true, isMirrored: true) }
            + own.map { .init(id: $0, isSynced: true, isAudit: true) }
        XCTAssertEqual(evictions(rows), [try XCTUnwrap(copies.last)], "the oldest copy, and only it")
    }

    /// This phone's own status entries over their limit: the oldest of its own goes, and no copy.
    func testThisPhonesOwnStatusEntriesOverTheirLimitLoseTheirOldestAndNoCopy() throws {
        let own = (0...EventStore.maxAuditEvents).map { _ in UUID() }
        let copies = (0..<5).map { _ in UUID() }
        let rows: [EventStore.EvictionRow] = own.map { .init(id: $0, isSynced: true, isAudit: true) }
            + copies.map { .init(id: $0, isSynced: true, isAudit: true, isMirrored: true) }
        XCTAssertEqual(evictions(rows), [try XCTUnwrap(own.last)], "the oldest of this phone's own, and only it")
    }

    /// None of this phone's own status entries is taken for a copy, whatever the copies.
    func testThisPhonesOwnStatusEntriesAreNeverTakenForCopies() {
        let own = (0..<EventStore.maxAuditEvents).map { _ in UUID() }
        let copies = (0..<5).map { _ in UUID() }
        let rows: [EventStore.EvictionRow] = copies.map { .init(id: $0, isSynced: true, isAudit: true, isMirrored: true) }
            + own.map { .init(id: $0, isSynced: true, isAudit: true) }
        XCTAssertTrue(Set(evictions(rows)).isDisjoint(with: own), "none of this phone's own goes for a copy")
    }

    /// Step 8 through the real store: a log full of this phone's own status entries takes another device's "reinstalled"
    /// entry from a pull and keeps it, beside every entry of its own.
    func testAPulledReinstalledEntryStaysInALogFullOfThisPhonesOwnStatusEntries() {
        let store = EventStore()
        let start = Date().addingTimeInterval(-3_600)
        for i in 0..<EventStore.maxAuditEvents {
            let at = start.addingTimeInterval(Double(i) * 10)
            store.add(Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .synced,
                            stateChange: i.isMultiple(of: 2) ? "armed" : "disarmed"))
        }
        let at = start.addingTimeInterval(500)
        let reinstalled = Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .synced,
                                stateChange: "reinstalled", sourceDevice: "Owner's iPad")
        _ = store.mergeFromCloud([reinstalled])
        XCTAssertTrue(store.events.contains { $0.id == reinstalled.id }, "the iPad's entry stays")
        XCTAssertEqual(store.events.filter { $0.isStateChange && !$0.isMirrored }.count, EventStore.maxAuditEvents,
                       "and none of this phone's own went for it")
    }

    /// Other devices' status entries keep to their own limit through the real store: a pull that brings one more than
    /// the limit drops the oldest copy, and only it, and none of this phone's own entries. Added after the fixes, at the
    /// undo check, so that a store that sets no limit for copies fails a test.
    func testAPullOverOtherDevicesLimitDropsTheirOldestEntryThroughTheStore() {
        let store = EventStore()
        let start = Date().addingTimeInterval(-7_200)
        for i in 0..<3 {
            let at = start.addingTimeInterval(Double(i))
            store.add(Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .synced,
                            stateChange: i.isMultiple(of: 2) ? "armed" : "disarmed"))
        }
        let copies = (0...EventStore.maxMirroredAuditEvents).map { i in
            let at = start.addingTimeInterval(100 + Double(i))
            return Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .synced,
                         stateChange: i.isMultiple(of: 2) ? "armed" : "disarmed", sourceDevice: "Owner's iPad")
        }
        _ = store.mergeFromCloud(copies)
        let kept = Set(store.events.filter(\.isMirrored).map(\.id))
        XCTAssertEqual(kept.count, EventStore.maxMirroredAuditEvents, "other devices' entries, at their limit")
        XCTAssertFalse(kept.contains(copies[0].id), "the oldest copy went")
        XCTAssertEqual(store.events.filter { $0.isStateChange && !$0.isMirrored }.count, 3, "this phone's own stay")
    }

    /// The Debug seed (item 79's leg) beside a status budget full of copies: it fills this phone's own budget, and the
    /// copies stay, since they no longer give way. In place of item 79's testSeedingAtTheCapDropsOnlyCopies, which held
    /// the old rule.
    func testTheSeedFillsThisPhonesOwnBudgetAndLeavesOtherDevicesCopies() {
        let store = EventStore()
        let old = Date().addingTimeInterval(-86_400)
        let copies = (0..<(EventStore.maxAuditEvents - 3)).map { i in
            Event(startDate: old.addingTimeInterval(Double(i)), endDate: old.addingTimeInterval(Double(i)),
                  triggeredSensors: [], cloudSyncState: .synced, stateChange: "armed", sourceDevice: "Another iPhone")
        }
        _ = store.merge(copies)
        for _ in 0..<3 {
            let at = Date().addingTimeInterval(-600)
            store.add(Event(startDate: at, endDate: at, triggeredSensors: [], cloudSyncState: .localOnly,
                            stateChange: "disarmed"))
        }
        let result = store.seedUnsyncedBacklogForTesting(count: 100)
        XCTAssertEqual(result.added, EventStore.maxAuditEvents - 3, "this phone's own budget, filled")
        XCTAssertEqual(result.droppedCopies, 0, "no copy gives way")
        XCTAssertEqual(store.events.filter(\.isMirrored).count, copies.count, "every copy stays")
    }

    // MARK: - The Vision still follows the event's capture (item 241's A5)

    /// A clip session has the movie output and no photo output: the still takes its turn and mirroring from the movie
    /// output's connection there, as the event's clip is turned, and from the photo output's in a photo session.
    func testTheStillTakesItsTurnFromTheEventsCaptureOutput() {
        XCTAssertEqual(CameraController.stillTurnSource(forClips: true, movie: "movie", photo: "photo"), "movie")
        XCTAssertEqual(CameraController.stillTurnSource(forClips: false, movie: "movie", photo: "photo"), "photo")
    }

    /// Both sessions, one camera's and both cameras', turn the still by that rule (read from the source: a test has no
    /// camera to build a connection from).
    func testBothSessionsTurnTheStillByTheRule() throws {
        // Spaces and line breaks collapsed, so the calls are found however they are wrapped.
        let camera = try source("Malinois/Services/CameraController.swift")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let single = "noteVisionStillOrientation(capture: Self.stillTurnSource(forClips: forClips, "
            + "movie: movieOutput.connection(with: .video), photo: photoOutput.connection(with: .video)),"
        let multi = "noteVisionStillOrientation(capture: Self.stillTurnSource(forClips: forClips, "
            + "movie: frontMovieOutput.connection(with: .video), photo: frontPhotoOutput.connection(with: .video)),"
        XCTAssertTrue(camera.contains(single), "the one-camera session")
        XCTAssertTrue(camera.contains(multi), "the two-camera session")
        XCTAssertFalse(camera.contains("noteVisionStillOrientation(photo:"), "no call takes the photo output's turn alone")
    }

    // MARK: - The owner's words (2026-11-14: "wording approved")

    /// The reinstall entry names no device (another device shows it under the iPad's name) and no longer says "kept".
    func testTheReinstalledEntryReadsInTheApprovedWords() {
        let now = Date()
        let entry = Event(startDate: now, endDate: now, triggeredSensors: [], stateChange: "reinstalled")
        XCTAssertEqual(entry.sensorSummary, "Malinois was reinstalled: its earlier event log was deleted with the app")
    }

    /// Settings' Security footer, as shown, without repeating the Require Guided Access caption.
    func testSettingsSecurityFooterSaysAForcedRestartStillEndsTheArmedSession() throws {
        let shown = try settingsShownOnScreen()
        let footer = try XCTUnwrap(shown.first { $0.hasPrefix("A forced restart still ends the armed session") },
                                   "the footer is not among the \(shown.count) texts Settings shows")
        XCTAssertEqual(footer, "A forced restart still ends the armed session, even under Guided Access. Malinois coaches "
                       + "you through Guided Access on the arming screen.")
        XCTAssertFalse(shown.contains { $0.contains("is strongly recommended while armed") }, "the old footer is gone")
    }

    /// "Before you arm" shows "No one can delete an entry" after every other part, the least pressing one last.
    func testBeforeYouArmShowsNoOneCanDeleteAnEntryLast() throws {
        let all = FirstArmBriefingView(parts: .init(disarm: true, guidedAccess: true, voiceControl: true, sideButton: true,
                                                    noDelete: true), recording: Self.noCamera) {}
        let layout = try shownOnScreen(all, in: CGSize(width: 402, height: 3_000))
        let noDelete = try XCTUnwrap(layout.frames[FirstArmBriefing.noDeleteHeading], "No one can delete an entry")
        for heading in [FirstArmBriefing.disarmHeading, FirstArmBriefing.guidedAccessHeading,
                        FirstArmBriefing.sideButtonHeading, FirstArmBriefing.voiceControlHeading] {
            let frame = try XCTUnwrap(layout.frames[heading], heading)
            XCTAssertLessThan(frame.minY, noDelete.minY, "\(heading) comes before No one can delete an entry")
        }
    }

    /// Voice Control's step, on "Before you arm" and on the arming screen in both modes: off unless the owner turned it on.
    func testVoiceControlsStepSaysItIsOffUnlessTheOwnerTurnedItOn() {
        let words = "Voice Control is off unless you turned it on. If you did, turn it OFF before you arm (Settings → "
            + "Accessibility → Voice Control): it keeps working under Guided Access and can be told to close Malinois. "
            + "Malinois can't see whether it is on, so this is up to you."
        XCTAssertEqual(FirstArmBriefing.voiceControlText, words, "Before you arm")
        for siren in [false, true] {
            let steps = ArmingView.guidedAccessSteps(siren: siren)
            XCTAssertTrue(steps.contains(words), "the arming screen, Siren mode \(siren)")
            XCTAssertFalse(steps.contains { $0.hasPrefix("If you use Voice Control") }, "the old step is gone")
        }
    }

    // MARK: - Helpers

    /// The rows the count limits take, at the production limits.
    private func evictions(_ rows: [EventStore.EvictionRow]) -> [UUID] {
        EventStore.countEvictionOrder(events: rows, incidentCap: EventStore.maxIncidentEvents,
                                      auditCap: EventStore.maxAuditEvents)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }
}
