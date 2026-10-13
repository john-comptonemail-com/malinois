//
//  Item57WatchAlertsTests.swift
//  MalinoisTests
//
//  BACKLOG 57, resumed for 1.6 as alerts only (owner, 2026-10-12; ADR 0042). An Apple Watch app,
//  embedded in the iPhone app, registers for the existing cross-device alert pushes so a tamper
//  alert reaches the wrist even when the armed iPhone is the watch's own (an armed phone never
//  forwards its notifications to its watch). It reads no iCloud records: 1.5.1's enrollment
//  boundary (ADR 0039). These tests read the project file and the watch's own files from the
//  source tree, as built. Written before the watch target, red at that commit (against a
//  compile-only stub for the screen's wording).
//

import XCTest
@testable import Malinois

final class Item57WatchAlertsTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ relativePath: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = Self.root.appendingPathComponent(relativePath)
        return try XCTUnwrap(try? String(contentsOf: url, encoding: .utf8), "missing \(relativePath)", file: file, line: line)
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    /// The watch app is its own target, embedded in the iPhone app's Watch folder, with the
    /// iPhone app as its companion.
    func testTheWatchAppIsEmbeddedWithTheIPhoneAppsIdentity() throws {
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        XCTAssertEqual(count("PRODUCT_BUNDLE_IDENTIFIER = com.johncompton.Malinois.watchkitapp;", in: project), 2)
        XCTAssertEqual(count("INFOPLIST_KEY_WKCompanionAppBundleIdentifier = com.johncompton.Malinois;", in: project), 2)
        XCTAssertEqual(count("SDKROOT = watchos;", in: project), 2)
        XCTAssertTrue(project.contains("dstPath = \"$(CONTENTS_FOLDER_PATH)/Watch\";"), "embedded in the iPhone app")
        XCTAssertTrue(project.contains("/* MalinoisWatch.app in Embed Watch Content */,"))
    }

    /// The watch app ships with the iPhone app's version and build number: one version for
    /// every app target (the test bundle keeps build 1).
    func testEveryAppTargetSharesOneVersion() throws {
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        func values(_ key: String) -> [String] {
            project.components(separatedBy: "\n")
                .compactMap { line -> String? in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard trimmed.hasPrefix("\(key) = ") else { return nil }
                    return String(trimmed.dropFirst(key.count + 3).dropLast())
                }
        }
        let marketing = values("MARKETING_VERSION")
        XCTAssertEqual(marketing.count, 8, "app, extension, watch and tests, Debug and Release")
        XCTAssertEqual(Set(marketing).count, 1, "one marketing version: \(marketing)")
        let builds = values("CURRENT_PROJECT_VERSION").filter { $0 != "1" }
        XCTAssertEqual(builds.count, 6, "app, extension and watch, Debug and Release")
        XCTAssertEqual(Set(builds).count, 1, "one build number: \(builds)")
    }

    /// The watch names the iPhone app's container literally (deriving it from its own bundle
    /// identifier would name an empty container), with a production push environment for
    /// TestFlight and App Store builds: a development token never receives the alert.
    func testTheWatchNamesTheIPhoneAppsCloudContainerLiterally() throws {
        let debug = try text("MalinoisWatch/MalinoisWatch.entitlements")
        let release = try text("MalinoisWatch/MalinoisWatch-Release.entitlements")
        for entitlements in [debug, release] {
            // The files' comments explain the derived name they avoid; check the values only.
            let values = entitlements.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "",
                                                           options: .regularExpression)
            XCTAssertTrue(values.contains("<string>iCloud.com.johncompton.Malinois</string>"))
            XCTAssertTrue(values.contains("<string>CloudKit</string>"))
            XCTAssertFalse(values.contains("$(PRODUCT_BUNDLE_IDENTIFIER)"))
        }
        XCTAssertTrue(debug.contains("<key>aps-environment</key>\n\t<string>development</string>"))
        XCTAssertTrue(release.contains("<key>aps-environment</key>\n\t<string>production</string>"))
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = MalinoisWatch/MalinoisWatch.entitlements;"))
        XCTAssertTrue(project.contains("CODE_SIGN_ENTITLEMENTS = \"MalinoisWatch/MalinoisWatch-Release.entitlements\";"))
    }

    /// Alerts only: the watch compiles none of the iPhone app's cloud code and calls no CloudKit
    /// record API, so it reads and writes no event records (ADR 0042); listing the account's
    /// subscriptions is its one server call.
    func testTheWatchReadsNoCloudRecords() throws {
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        XCTAssertEqual(count("/* CloudExfiltrator.swift in Sources */", in: project), 2, "the iPhone app's target only")
        let folder = Self.root.appendingPathComponent("MalinoisWatch")
        let sources = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty)
        for url in sources {
            let code = try String(contentsOf: url, encoding: .utf8)
            for api in ["CKQuery", "CKFetch", "CKModify", "record(for", "records(matching", "fetch(withRecordID", ".save("] {
                XCTAssertFalse(code.contains(api), "\(url.lastPathComponent) uses \(api)")
            }
        }
    }

    private typealias Checks = WatchAlertStatus.Checks

    /// Everything known good, the tamper subscription included.
    private static let ready = Checks(registration: .registered, account: .available, notifications: .allowed,
                                      subscriptions: .found)

    /// The watch screen says whether alerts will arrive, and why not. Ready needs the account's tamper
    /// subscription to be visible to the watch, not only its own sign-up (TestFlight 1.6 (59): the screen
    /// said ready and no alert arrived).
    func testTheWatchScreenSaysWhetherAlertsWillArrive() {
        func headline(_ change: (inout Checks) -> Void) -> String {
            var checks = Self.ready
            change(&checks)
            return WatchAlertStatus.describe(checks).headline
        }
        XCTAssertEqual(headline { _ in }, "Ready for alerts")
        XCTAssertEqual(WatchAlertStatus.describe(Self.ready).detail,
                       "When Malinois detects tampering on one of your devices, the alert arrives here.")
        XCTAssertEqual(headline { $0.subscriptions = .unknown }, "Checking…", "not ready before the subscription is seen")
        XCTAssertEqual(headline { $0.registration = .pending }, "Checking…")
        XCTAssertEqual(headline { $0.registration = .failed }, "Can't receive alerts")
        XCTAssertEqual(headline { $0.account = .unavailable }, "iCloud unavailable")
    }

    /// The watch asks for permission to show alerts itself: a one-iPhone owner's armed iPhone never
    /// receives an alert, so the iPhone app may never have asked. Off, the screen says so.
    func testTheWatchSaysWhenNotificationsAreOff() {
        var checks = Self.ready
        checks.notifications = .denied
        XCTAssertEqual(WatchAlertStatus.describe(checks).headline, "Notifications are off")
        XCTAssertEqual(WatchAlertStatus.describe(checks).detail, "Turn on notifications for Malinois in the Watch app on your iPhone.")
        checks.registration = .failed
        XCTAssertEqual(WatchAlertStatus.describe(checks).headline, "Can't receive alerts", "a failed registration comes first")
    }

    /// No tamper subscription for this account means no alert can come: Cross-device alerts are off
    /// (or the watch sees a different account or environment). A failed lookup says why.
    func testTheWatchSaysWhenThisAccountHasNoAlertSubscription() {
        var checks = Self.ready
        checks.subscriptions = .missing
        XCTAssertEqual(WatchAlertStatus.describe(checks).headline, "Alerts are off for this account")
        XCTAssertEqual(WatchAlertStatus.describe(checks).detail,
                       "Turn on Cross-device alerts in Malinois on your iPhone (Settings → iCloud).")
        checks.subscriptions = .unreadable("The network connection was lost.")
        XCTAssertEqual(WatchAlertStatus.describe(checks).headline, "Can't check alerts")
        XCTAssertTrue(WatchAlertStatus.describe(checks).detail.contains("The network connection was lost."))
    }

    /// Each check has its own line, so a stuck screen says what it is waiting for, and the last alert
    /// the watch app saw is shown.
    func testTheWatchScreenShowsEachCheckAndTheLastAlert() {
        let waiting = Checks(registration: .registered, account: .available, notifications: .unknown,
                             subscriptions: .found, link: .ready)
        XCTAssertEqual(WatchAlertStatus.describe(waiting).lines,
                       ["Sign-up: done", "iCloud: signed in", "Notifications: waiting for your answer",
                        "Alert subscription: found", "iPhone link: ready", "Last alert: none yet"])
        var starting = waiting
        starting.link = .starting
        XCTAssertTrue(WatchAlertStatus.describe(starting).lines.contains("iPhone link: starting"))
        starting.link = .unavailable
        XCTAssertTrue(WatchAlertStatus.describe(starting).lines.contains("iPhone link: unavailable"))
        var seen = Self.ready
        seen.lastAlert = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let last = WatchAlertStatus.describe(seen).lines.last ?? ""
        XCTAssertTrue(last.hasPrefix("Last alert: ") && last != "Last alert: none yet", last)
    }

    /// iCloud never sends the watch a change made by its own iPhone (TestFlight 1.6 (59)), so the
    /// armed iPhone also sends its alerts straight to the watch (ADR 0043). The watch activates its end
    /// of the link at launch, handles messages that wake it in the background, and shows each as a
    /// local alert.
    func testTheWatchReceivesAlertsStraightFromItsIPhone() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        XCTAssertTrue(delegate.contains("WCSession.default.activate()"))
        XCTAssertTrue(delegate.contains("WKWatchConnectivityRefreshBackgroundTask"))
        XCTAssertTrue(delegate.contains("didReceiveUserInfo"))
        XCTAssertTrue(delegate.contains("UNNotificationRequest"))
        let project = try text("Malinois.xcodeproj/project.pbxproj")
        XCTAssertEqual(count("/* WatchAlertMessage.swift in Sources */", in: project), 4, "the iPhone app and the watch app")
    }

    /// The watch looks for the iPhone app's own tamper subscription.
    func testTheWatchLooksForThePhonesTamperSubscription() {
        XCTAssertEqual(WatchAlertStatus.tamperSubscriptionID, CloudExfiltrator.makeTamperSubscription().subscriptionID)
    }

    /// When it opens, the watch signs up again, lists the account's subscriptions on the iCloud server
    /// (the September build that delivered alerts contacted the server; 1.6 (59) did not), and records
    /// each alert it sees.
    func testTheWatchListsSubscriptionsAndRecordsTheLastAlert() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        XCTAssertTrue(delegate.contains("privateCloudDatabase.allSubscriptions()"))
        XCTAssertTrue(delegate.contains("func didReceiveRemoteNotification"))
        XCTAssertTrue(delegate.contains("lastAlertReceived"))
    }

    /// The watch requests the permission when it opens; an answer already given returns at once.
    func testTheWatchAsksForNotificationPermission() throws {
        let delegate = try text("MalinoisWatch/WatchAppDelegate.swift")
        XCTAssertTrue(delegate.contains("requestAuthorization(options: [.alert, .sound])"))
    }
}
