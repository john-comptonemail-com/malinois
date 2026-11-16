//
//  Item224FailureNoticeTests.swift
//  MalinoisTests
//
//  BACKLOG item 224's points 1 and 3 (1.13, item 240's list; docs/design/1.13-fixes.md; the owner, 2026-11-12: "as you
//  recommend": point 1 (a), point 3 Keep forever).
//  1. An event log that is a folder or a link (only an edited backup restored to the phone can put one there) was set
//     aside with no notice since 1.12: the list of set-aside logs takes plain files only (item 218), Home's notice follows
//     the list, and the flag 1.11 showed it by was read nowhere. Now Home says so at that launch, in 1.11's words.
//  3. A retention setting that could not be read (a later build's new choice) became 12 months, where a full reset of
//     the settings chooses Keep forever so that nothing in iCloud is deleted on a setting the owner never chose. Now Keep
//     forever there too; settings from before the setting existed keep its default, and nothing else is reset.
//  The store made for real over a folder in the log's place; Home laid out for real; the settings decoded from what a
//  later build could have saved. Written before the fix, red at that commit.
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item224FailureNoticeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem224")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Point 1: an event log set aside that the list does not show

    /// A folder in the log's place: set aside, not listed, and Home says so at that launch, in 1.11's words.
    func testAnEventLogThatIsAFolderSetAsideIsSaidOnHome() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("events.json"), withIntermediateDirectories: true)
        let store = EventStore(protectedDataAvailable: { true })
        XCTAssertFalse(store.loadFailed, "set aside, so the store goes on writing")
        XCTAssertTrue(store.setAsideLogs.isEmpty, "the list takes plain files only")
        XCTAssertTrue(store.setAsideNotListed)
        let shown = try home(store)
        XCTAssertTrue(shown.contains(HomeView.setAsideNotListedNotice), "\(shown)")
    }

    /// A guard, green before the fix and after: a plain log that cannot be decoded is set aside and listed, and Home says
    /// so by the list's notice, not this one.
    func testAPlainLogSetAsideIsListedAndSaidAsBefore() throws {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a log".utf8).write(to: root.appendingPathComponent("events.json"))
        let store = EventStore(protectedDataAvailable: { true })
        XCTAssertEqual(store.setAsideLogs.count, 1, "listed")
        XCTAssertFalse(store.setAsideNotListed)
        let shown = try home(store)
        XCTAssertTrue(shown.contains(SetAsideLogWords.home), "\(shown)")
        XCTAssertFalse(shown.contains(HomeView.setAsideNotListedNotice), "\(shown)")
    }

    /// 1.11's words, word for word.
    func testTheWordsAreOnePointElevens() {
        XCTAssertEqual(HomeView.setAsideNotListedNotice,
                       "The event log couldn't be read and was set aside as a backup - new events go to a fresh log.")
    }

    // MARK: - Point 3: a retention setting that cannot be read

    /// A retention choice this build does not know (a later build's) becomes Keep forever; nothing else is reset.
    func testARetentionSettingThatCannotBeReadBecomesKeepForever() throws {
        let saved = AppSettings()
        saved.cloudRetention = .months3
        saved.gracePeriodSeconds = 42
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        dict["cloudRetention"] = "months24"   // a later build's choice
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(decoded.cloudRetention, .forever, "nothing deleted on a setting the owner never chose")
        XCTAssertEqual(decoded.gracePeriodSeconds, 42, "the other settings as saved: not a reset")
    }

    /// A guard, green before the fix and after: settings saved before the retention setting existed keep its default.
    func testSettingsFromBeforeTheRetentionSettingKeepItsDefault() throws {
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        dict.removeValue(forKey: "cloudRetention")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(decoded.cloudRetention, .months12)
    }

    // MARK: - Helpers

    /// What the real Home shows over `store`.
    private func home(_ store: EventStore) throws -> [String] {
        let settings = AppSettings()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let cloud = CloudExfiltrator()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return try shownOnScreen(HomeView()
            .environmentObject(engine).environmentObject(settings).environmentObject(cloud)
            .environmentObject(store).environmentObject(entitlements)).shown
    }
}
