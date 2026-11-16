//
//  Item223ShareDiagnosticTests.swift
//  MalinoisTests
//
//  BACKLOG item 223, D7 (a) of docs/design/1.13-fixes.md (the owner, 2026-11-12: "as you recommend, wording approved"):
//  1.13's TestFlight build carries a diagnostic, log lines only, read on the owner's phone with the Console app during its
//  test, for the ruling on item 223's points 2 and 3: the thread and the time of each ask for the evidence ZIP (the
//  sheet's own ask can wait on a making: point 2), and whether a share completed with the ZIP's making never asked for
//  (point 3). Nothing else changes: each ask gets what it got before. The lines name no record: a share's number in this
//  launch, times since its sheet opened, and the destination, Apple's by its own name and another app's not named.
//  Through the real share item, with a recorder in place of the log; the event's screen and the log's privacy marker are
//  read from the source tree. Written before the code, red at that commit (where the item reports nothing and the words
//  are empty).
//

import Synchronization
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item223ShareDiagnosticTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item223Share-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - The words

    /// Each ask's line says the share's number, whose ask it was, the thread, the time since the sheet opened, the
    /// destination and what the ask found and got.
    func testTheAsksWords() {
        XCTAssertEqual(ShareDiagnostic.sheetAsk(share: 3, onMain: true, after: .milliseconds(1_240), destination: .airDrop,
                                                whileMaking: true, waited: .milliseconds(800), got: true),
                       "share 3: the sheet asked for the ZIP on the main thread, 1.24 s after it opened, for "
                       + "com.apple.UIKit.activity.AirDrop, while the ZIP was being made; it waited 0.80 s and got the ZIP")
        XCTAssertEqual(ShareDiagnostic.sheetAsk(share: 4, onMain: false, after: .milliseconds(50), destination: nil,
                                                whileMaking: false, waited: .zero, got: false),
                       "share 4: the sheet asked for the ZIP on another thread, 0.05 s after it opened, for no destination "
                       + "named, with no ZIP being made; it waited 0.00 s and got none")
        XCTAssertEqual(ShareDiagnostic.operationAsk(share: 3, onMain: false, after: .milliseconds(1_200), destination: .mail,
                                                    took: .milliseconds(850), got: true),
                       "share 3: the operation asked for the ZIP on another thread, 1.20 s after the sheet opened, for "
                       + "com.apple.UIKit.activity.Mail; it got the ZIP after 0.85 s")
        XCTAssertEqual(ShareDiagnostic.operationAsk(share: 5, onMain: true, after: .seconds(2), destination: nil,
                                                    took: .seconds(60), got: false),
                       "share 5: the operation asked for the ZIP on the main thread, 2.00 s after the sheet opened, for no "
                       + "destination named; it got none after 60.00 s")
    }

    /// The end's line says how the share ended and whether the ZIP's making was asked for; a share that completed to a
    /// destination that may take a file with the making never asked for (item 223's point 3) says what that cost.
    func testTheEndsWords() {
        XCTAssertEqual(ShareDiagnostic.end(share: 3, after: .milliseconds(4_100), completed: true, destination: .mail, made: nil),
                       "share 3: the sheet ended 4.10 s after it opened, completed, for com.apple.UIKit.activity.Mail; the "
                       + "ZIP's making was never asked for, so the share went without it and the screen said nothing")
        XCTAssertEqual(ShareDiagnostic.end(share: 3, after: .milliseconds(4_100), completed: false, destination: nil, made: nil),
                       "share 3: the sheet ended 4.10 s after it opened, not completed, for no destination named; the "
                       + "ZIP's making was never asked for")
        XCTAssertEqual(ShareDiagnostic.end(share: 6, after: .seconds(1), completed: true, destination: .copyToPasteboard,
                                           made: nil),
                       "share 6: the sheet ended 1.00 s after it opened, completed, for "
                       + "com.apple.UIKit.activity.CopyToPasteboard; the ZIP's making was never asked for")
        XCTAssertEqual(ShareDiagnostic.end(share: 7, after: .seconds(9), completed: true, destination: .airDrop, made: true),
                       "share 7: the sheet ended 9.00 s after it opened, completed, for "
                       + "com.apple.UIKit.activity.AirDrop; the ZIP was made")
        XCTAssertEqual(ShareDiagnostic.end(share: 8, after: .seconds(61), completed: true, destination: .mail, made: false),
                       "share 8: the sheet ended 61.00 s after it opened, completed, for "
                       + "com.apple.UIKit.activity.Mail; the ZIP could not be made")
    }

    /// Apple's destinations by their own names; another app's not named, so the log does not list the apps on the phone.
    func testAnotherAppsDestinationIsNotNamed() {
        XCTAssertEqual(ShareDiagnostic.destination(.airDrop), "com.apple.UIKit.activity.AirDrop")
        XCTAssertEqual(ShareDiagnostic.destination(UIActivity.ActivityType("com.apple.DocumentManagerUICore.SaveToFiles")),
                       "com.apple.DocumentManagerUICore.SaveToFiles")
        XCTAssertEqual(ShareDiagnostic.destination(UIActivity.ActivityType("net.example.chat.share")),
                       "another app's destination")
        XCTAssertEqual(ShareDiagnostic.destination(nil), "no destination named")
    }

    // MARK: - The real item's asks

    /// The sheet's own ask is reported with its thread, its time and what it got, which is what it got before: no ZIP
    /// while none is made.
    func testTheSheetsAskIsReportedWithItsThreadAndTime() async throws {
        let lines = Lines()
        let item = makeItem(lines)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: .airDrop), "none yet, as before")
        let onMain = try XCTUnwrap(lines.all.first, "the sheet's ask reported")
        XCTAssertEqual(onMain, ShareDiagnostic.sheetAsk(share: item.share, onMain: true, after: try time(Self.opened, onMain),
                                                        destination: .airDrop, whileMaking: false,
                                                        waited: try time(Self.waited, onMain), got: false))
        XCTAssertGreaterThanOrEqual(try time(Self.opened, onMain), .milliseconds(250), "counted from the sheet's opening")
        let controller = sheet()
        let offMain = await Self.onAnotherThread { item.activityViewController(controller, itemForActivityType: .mail) as? URL }
        XCTAssertNil(offMain)
        XCTAssertEqual(lines.all.count, 2, "each ask reported")
        let elsewhere = try XCTUnwrap(lines.all.last)
        XCTAssertEqual(elsewhere, ShareDiagnostic.sheetAsk(share: item.share, onMain: false,
                                                           after: try time(Self.opened, elsewhere), destination: .mail,
                                                           whileMaking: false, waited: try time(Self.waited, elsewhere),
                                                           got: false))
    }

    /// The operation's ask, the one that makes the ZIP, is reported with its thread and what it got, after how long; it
    /// gets what it got before: the ZIP, or the placeholder when none could be made.
    func testTheOperationsAskIsReportedWithItsThreadAndWhatItGot() async throws {
        let lines = Lines()
        let item = makeItem(lines)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(item.item as? URL, "made, as before")
        let made = try XCTUnwrap(lines.all.first, "the operation's ask reported")
        XCTAssertEqual(made, ShareDiagnostic.operationAsk(share: item.share, onMain: true, after: try time(Self.sheetOpened, made),
                                                          destination: nil, took: try time(Self.took, made), got: true))
        XCTAssertGreaterThanOrEqual(try time(Self.sheetOpened, made), .milliseconds(150), "counted from the sheet's opening")
        let failing = Lines()
        let none = makeItem(failing, gives: false)
        let got = await Self.onAnotherThread { none.item as? URL }
        XCTAssertEqual(got, placeholder, "the placeholder, as before")
        let notMade = try XCTUnwrap(failing.all.first, "reported off the main thread too")
        XCTAssertEqual(notMade, ShareDiagnostic.operationAsk(share: none.share, onMain: false,
                                                             after: try time(Self.sheetOpened, notMade), destination: nil,
                                                             took: try time(Self.took, notMade), got: false))
    }

    /// Item 223's point 2: the sheet's own ask while the operation is making the ZIP waits for it; its line says the ZIP
    /// was being made and how long the ask waited.
    func testASheetAskWhileTheZIPIsBeingMadeSaysSoAndHowLongItWaited() async throws {
        let lines = Lines()
        let item = makeItem(lines, taking: .milliseconds(600))
        let operation = Task.detached { await Self.onAnotherThread { item.item as? URL } }
        let underWay = await waitFor { item.makingUnderWay }
        XCTAssertTrue(underWay, "a making under way")
        let zip = item.activityViewController(sheet(), itemForActivityType: .mail) as? URL
        XCTAssertNotNil(zip, "it waited for the ZIP, as before")
        XCTAssertFalse(item.makingUnderWay, "and the making is over")
        let operationZIP = await operation.value
        XCTAssertEqual(operationZIP, zip)
        let asked = try XCTUnwrap(lines.all.first { $0.contains("the sheet asked") }, "the sheet's ask reported")
        let waited = try time(Self.waited, asked)
        XCTAssertEqual(asked, ShareDiagnostic.sheetAsk(share: item.share, onMain: true, after: try time(Self.opened, asked),
                                                       destination: .mail, whileMaking: true, waited: waited, got: true))
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(200), "how long it waited on the making")
        let making = try XCTUnwrap(lines.all.first { $0.contains("the operation asked") }, "the operation's ask reported")
        XCTAssertGreaterThanOrEqual(try time(Self.took, making), .milliseconds(500), "how long the making took")
    }

    // MARK: - The end

    /// Item 223's point 3: the end says whether the ZIP's making was asked for, and how the share ended.
    func testTheEndSaysWhetherTheZIPsMakingWasAskedFor() async throws {
        let lines = Lines()
        let unasked = makeItem(lines)
        try await Task.sleep(for: .milliseconds(150))
        unasked.shareEnded(destination: .mail, completed: true)
        try assertEnd(lines, of: unasked, completed: true, destination: .mail, made: nil)
        let ended = try XCTUnwrap(lines.all.last)
        XCTAssertGreaterThanOrEqual(try time(Self.ended, ended), .milliseconds(150), "counted from the sheet's opening")
        let made = makeItem(lines)
        _ = made.item
        made.shareEnded(destination: .airDrop, completed: true)
        try assertEnd(lines, of: made, completed: true, destination: .airDrop, made: true)
        let failed = makeItem(lines, gives: false)
        _ = failed.item
        failed.shareEnded(destination: .mail, completed: true)
        try assertEnd(lines, of: failed, completed: true, destination: .mail, made: false)
        let cancelled = makeItem(lines)
        cancelled.shareEnded(destination: nil, completed: false)
        try assertEnd(lines, of: cancelled, completed: false, destination: nil, made: nil)
    }

    /// Each share has a number of its own in this launch, so one share's lines can be told from another's.
    func testEachShareHasANumberOfItsOwn() {
        let first = makeItem(Lines())
        let second = makeItem(Lines())
        XCTAssertGreaterThan(first.share, 0)
        XCTAssertEqual(second.share, first.share + 1)
    }

    /// No line names the record: not its bundle's name, its date, a path or an identifier.
    func testTheLinesNeverNameTheRecord() async throws {
        let lines = Lines()
        let item = makeItem(lines)
        _ = item.activityViewController(sheet(), itemForActivityType: .mail)
        let zip = await Self.onAnotherThread { item.item as? URL }
        XCTAssertNotNil(zip)
        _ = item.activityViewController(sheet(), itemForActivityType: .mail)
        item.shareEnded(destination: .mail, completed: true)
        XCTAssertEqual(lines.all.count, 4, "every ask and the end reported")
        for line in lines.all {
            XCTAssertFalse(line.contains("Malinois evidence"), line)
            XCTAssertFalse(line.contains("2026"), line)
            XCTAssertFalse(line.contains("/"), line)
            XCTAssertNil(line.firstMatch(of: #/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}/#), line)
        }
    }

    // MARK: - Where the lines go

    /// The event's screen (read from the source tree, as built) reports the sheet's end to the share's item.
    func testTheEventScreenReportsTheShareEnd() throws {
        let screen = try source("Malinois/Views/EventDetailView.swift")
        XCTAssertTrue(screen.contains("request.bundle?.shareEnded(destination: destination, completed: completed)"))
    }

    /// The lines go to the share log by default, in the open (public), so the Console app on the phone shows them; at
    /// the notice level, which it shows without any setting.
    func testTheLinesGoToTheShareLogInTheOpen() throws {
        let item = try source("Malinois/Views/EvidenceBundleItem.swift")
        XCTAssertTrue(item.contains("report: @escaping @Sendable (String) -> Void = { EvidenceBundleItem.log($0) }"))
        XCTAssertTrue(item.contains("Log.share.notice(\"\\(line, privacy: .public)\")"))
        let log = try source("Malinois/Support/Log.swift")
        XCTAssertTrue(log.contains("static let share  = Logger(subsystem: subsystem, category: \"share\")"))
    }

    // MARK: - Helpers

    private static let opened = #/, (\d+\.\d\d) s after it opened/#
    private static let sheetOpened = #/, (\d+\.\d\d) s after the sheet opened/#
    private static let waited = #/it waited (\d+\.\d\d) s/#
    private static let took = #/after (\d+\.\d\d) s$/#
    private static let ended = #/the sheet ended (\d+\.\d\d) s after it opened/#

    private var placeholder: URL { folder.appendingPathComponent("Malinois evidence 2026-10-31 0926.zip") }

    /// A share item over a stand-in making that takes `taking` and gives a ZIP, or none, its lines to `lines`.
    private func makeItem(_ lines: Lines, taking delay: Duration = .zero, gives: Bool = true) -> EvidenceBundleItem {
        EvidenceBundleItem(placeholder: placeholder, report: { lines.add($0) }, make: { [folder] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            return gives ? try? standInBundle(in: folder) : nil
        })
    }

    private func sheet() -> UIActivityViewController { UIActivityViewController(activityItems: [], applicationActivities: nil) }

    /// The time a line gives where `pattern` finds it, in hundredths of a second, as the line wrote it.
    private func time(_ pattern: Regex<(Substring, Substring)>, _ line: String) throws -> Duration {
        let match = try XCTUnwrap(line.firstMatch(of: pattern), "no time in: \(line)")
        let seconds = try XCTUnwrap(Double(match.output.1), line)
        return .milliseconds(Int((seconds * 100).rounded()) * 10)
    }

    /// The last line is the end of `item`'s share, as the words say it.
    private func assertEnd(_ lines: Lines, of item: EvidenceBundleItem, completed: Bool, destination: UIActivity.ActivityType?,
                           made: Bool?, file: StaticString = #filePath, line: UInt = #line) throws {
        let end = try XCTUnwrap(lines.all.last, "the end reported", file: file, line: line)
        XCTAssertEqual(end, ShareDiagnostic.end(share: item.share, after: try time(Self.ended, end), completed: completed,
                                                destination: destination, made: made), file: file, line: line)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Runs `work` on a thread of the system's, not the main one, as iOS runs the sheet's operation.
    nonisolated private static func onAnotherThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: work()) }
        }
    }

    /// Lets the main run loop turn until `condition` holds; false after `timeout`.
    private func waitFor(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// The lines an item reported, in order, from any thread.
private final class Lines: Sendable {
    private let lines = Mutex<[String]>([])
    var all: [String] { lines.withLock { $0 } }
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

/// A stand-in for a bundle: a ZIP-named file in a folder of its own, as the exporter makes them.
private func standInBundle(in folder: URL) throws -> URL {
    let place = folder.appendingPathComponent("MalinoisExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
    let zip = place.appendingPathComponent("Malinois evidence.zip")
    try Data("PK".utf8).write(to: zip)
    return zip
}
