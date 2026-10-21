//
//  Item141WordingTests.swift
//  MalinoisTests
//
//  The app's words from Fable's review of 1.8 (75) (BACKLOG 141) and the owner's sidebar (BACKLOG 142):
//  - fable-1: the iPhone's own backups (iCloud Backup, or a computer's) hold Malinois's evidence whatever its iCloud
//    backup switch says, and on the free tier; the switch's caption says so, and the free-tier notes no longer say the
//    evidence is only on this device.
//  - fable-4: iCloud Photo & Video Storage acts on every device's photos and clips; the shortest setting wins.
//  - claude-1 (found while checking fable-5): with iCloud backup off, the launch check's notice said the phone "is
//    uploading" the records it queued again; they wait until backup is turned back on.
//  - item 142: the app's words no longer speak of theft (the owner: "it is not a focus").
//  Written before the change, red at that commit (against compile-only stubs).
//

import SwiftUI
import XCTest
@testable import Malinois

@MainActor
final class Item141WordingTests: XCTestCase {
    nonisolated private static let accountKey = "com.malinois.cloud.accountRecordName"
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem141Wording")
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.accountKey)
        TestIsolation.tearDown()
        super.tearDown()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: - fable-1: the iPhone's own backups

    /// The switch's caption names the iPhone's own backups, which it does not control, and Settings shows it.
    func testTheBackupSwitchCaptionNamesTheIPhonesOwnBackups() throws {
        XCTAssertTrue(SettingsView.backupCaption.contains("own backups"), SettingsView.backupCaption)
        XCTAssertTrue(SettingsView.backupCaption.contains("iCloud Backup"), SettingsView.backupCaption)
        XCTAssertTrue(try source("Malinois/Views/SettingsView.swift").contains("Text(Self.backupCaption)"),
                      "the switch shows another caption")
    }

    /// The free-tier footer: Malinois uploads nothing, and the iPhone's own backups can still hold the evidence.
    func testTheFreeTierFooterDoesNotSayTheEvidenceIsOnlyOnThisDevice() throws {
        XCTAssertFalse(SettingsView.freeTierNote.contains("device only"), SettingsView.freeTierNote)
        XCTAssertTrue(SettingsView.freeTierNote.contains("own backups"), SettingsView.freeTierNote)
        XCTAssertTrue(try source("Malinois/Views/SettingsView.swift").contains("Text(Self.freeTierNote)"),
                      "the footer shows other words")
    }

    /// On the free tier the countdown says Malinois uploads nothing, not that the evidence cannot reach iCloud.
    func testTheFreeTierCountdownDoesNotSayTheEvidenceCannotReachICloud() throws {
        XCTAssertFalse(ArmingView.freeTierNotice.contains("won't back up to iCloud"), ArmingView.freeTierNotice)
        XCTAssertTrue(ArmingView.freeTierNotice.contains("own backups"), ArmingView.freeTierNotice)
        let settings = AppSettings()
        settings.gracePeriodSeconds = 60
        settings.requireGuidedAccess = false
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: EventStore(),
                                                          cloud: CloudExfiltrator(), camera: FakeCamera(),
                                                          entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.beginArming()
        engine.confirmGuidedAccessAndStartGrace()
        XCTAssertEqual(engine.state, .arming)
        let shown = try shownOnScreen(ArmingView()
            .environmentObject(engine)
            .environmentObject(entitlements)
            .environmentObject(settings)).shown
        XCTAssertTrue(shown.contains(ArmingView.freeTierNotice), "\(shown)")
        engine.cancelArming()
    }

    // MARK: - fable-4: the storage setting covers every device

    func testTheStorageCaptionSaysItCoversEveryDevice() throws {
        XCTAssertTrue(SettingsView.retentionCaption.contains("all your devices"), SettingsView.retentionCaption)
        XCTAssertTrue(SettingsView.retentionCaption.contains("shortest"), SettingsView.retentionCaption)
        XCTAssertTrue(try source("Malinois/Views/SettingsView.swift").contains("Text(Self.retentionCaption)"),
                      "the setting shows another caption")
    }

    // MARK: - claude-1: the launch check's notice with iCloud backup off

    /// iCloud no longer holds this phone's records and backup is off: they are queued again, and Home says they wait
    /// for backup, not that they are uploading.
    func testWithBackupOffTheNoticeSaysTheRecordsWaitForBackup() async throws {
        let engine = wipedEngine(backupOn: false)
        await engine.checkCloudCopies()
        let notice = try XCTUnwrap(engine.cloudResetNotice)
        XCTAssertTrue(notice.contains("when iCloud backup is turned back on"), notice)
        XCTAssertFalse(notice.contains("is uploading"), notice)
    }

    /// With backup on, the notice is as before.
    func testWithBackupOnTheNoticeSaysTheyAreUploading() async throws {
        let engine = wipedEngine(backupOn: true)
        await engine.checkCloudCopies()
        let notice = try XCTUnwrap(engine.cloudResetNotice)
        XCTAssertTrue(notice.contains("This phone is uploading 5 of them again."), notice)
    }

    /// Codex's codex-1 on 76: the notice follows the switch. Turned back on, as it asks, it says the records are
    /// uploading; it kept asking for what was already done. Turned off again, it says they wait.
    func testTheNoticeFollowsTheBackupSwitch() async throws {
        let engine = wipedEngine(backupOn: false)
        await engine.checkCloudCopies()
        XCTAssertTrue(engine.setCloudBackup(true))
        let on = try XCTUnwrap(engine.cloudResetNotice)
        XCTAssertTrue(on.contains("This phone is uploading 5 of them again."), on)
        XCTAssertFalse(on.contains("turned back on"), on)
        XCTAssertTrue(engine.setCloudBackup(false))
        let off = try XCTUnwrap(engine.cloudResetNotice)
        XCTAssertTrue(off.contains("5 of them will upload again when iCloud backup is turned back on."), off)
    }

    /// Five of this phone's records went up under this account, and iCloud now holds none of them.
    private func wipedEngine(backupOn: Bool) -> MonitoringEngine {
        UserDefaults.standard.set("owner", forKey: Self.accountKey)
        let store = EventStore()
        for minutes in (1...5).reversed() {
            let at = Date().addingTimeInterval(-Double(minutes) * 60)
            store.add(Event(startDate: at, endDate: at, triggeredSensors: [.touch], cloudSyncState: .synced,
                            stateChange: nil, sourceDevice: nil))
        }
        let settings = AppSettings()
        settings.cloudBackup = backupOn
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.cloudAccountForTesting = "owner"
        engine.cloudPresenceForTesting = { _ in [] }
        return engine
    }

    // MARK: - item 142: no theft in the app's words

    /// No string in the app, its watch app or their extensions, and no Info.plist value, speaks of theft.
    func testNoTextInTheAppSpeaksOfTheft() throws {
        let words = try NSRegularExpression(pattern: #"\b(theft|thief|thieves|stolen)\b|switched off or taken"#,
                                            options: [.caseInsensitive])
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var found: [String] = []
        for folder in ["Malinois", "MalinoisWatch", "MalinoisNotificationService", "MalinoisWatchNotificationService"] {
            let files = FileManager.default.enumerator(at: Self.root.appendingPathComponent(folder),
                                                       includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                guard ["swift", "plist", "strings", "xcstrings"].contains(url.pathExtension) else { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() {
                    let code = url.pathExtension == "swift"
                    if code && line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    let pieces = code
                        ? literal.matches(in: line, range: NSRange(line.startIndex..., in: line))
                            .compactMap { Range($0.range, in: line).map { String(line[$0]) } }
                        : [line]
                    for piece in pieces where words.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) != nil {
                        found.append("\(url.lastPathComponent):\(index + 1): \(piece)")
                    }
                }
            }
        }
        XCTAssertEqual(found, [], "the app's words speak of theft")
    }
}
