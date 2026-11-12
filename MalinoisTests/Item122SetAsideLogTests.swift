//
//  Item122SetAsideLogTests.swift
//  MalinoisTests
//
//  BACKLOG 122 (the owner, 2026-11-07: "as you recommend, wording approved": decisions 1 (a), 2 (a), 3 (a), 4 (a) of
//  docs/design/set-aside-log.md). A log that does not decode as a whole is set aside and a fresh one started; since build 70
//  nothing deletes it, but the owner could neither read it nor share it. Now it is read record by record, so one record a
//  build cannot read, or damaged bytes, cost only what they touch; the Event Log lists each set-aside log at its top, with a
//  screen of its own that shows what could be read, read only; Share sends the file as kept with the photos and clips it
//  names and a README; and Home says so while any is kept. Nothing goes back into the log, so what the phone signed about
//  those records stays true. Written before the code, red at that commit (against compile-only stubs).
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item122SetAsideLogTests: XCTestCase {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    nonisolated private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("Item122-\(UUID().uuidString)")

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem122")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Reading record by record

    /// A log every record of which reads: all of them, in the file's order, none unreadable.
    func testAWholeLogReadsEveryRecord() throws {
        let events = [event(3), event(2), event(1)]
        let reading = SetAsideLog.reading(try JSONEncoder().encode(events))
        XCTAssertEqual(reading.records.map(\.id), events.map(\.id))
        XCTAssertEqual(reading.unreadable, 0)
    }

    /// One record with a value this build does not know (as after going back to an older build) costs that record only.
    func testARecordABuildCannotReadCostsThatRecordOnly() throws {
        let events = [event(3), event(2), event(1)]
        var list = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(events)) as? [[String: Any]])
        list[1]["cloudSyncState"] = "fromALaterBuild"
        let reading = SetAsideLog.reading(try JSONSerialization.data(withJSONObject: list))
        XCTAssertEqual(reading.records.map(\.id), [events[0].id, events[2].id])
        XCTAssertEqual(reading.unreadable, 1)
    }

    /// Damaged bytes inside one record cost that record only.
    func testDamagedBytesInsideARecordCostThatRecordOnly() throws {
        let events = [event(3), event(2), event(1)]
        let text = try XCTUnwrap(String(data: JSONEncoder().encode(events), encoding: .utf8))
        let second = try XCTUnwrap(text.range(of: events[1].id.uuidString))
        let damaged = text.replacingCharacters(in: second, with: "#not-an-id#")
        let reading = SetAsideLog.reading(Data(damaged.utf8))
        XCTAssertEqual(reading.records.map(\.id), [events[0].id, events[2].id])
        XCTAssertEqual(reading.unreadable, 1)
    }

    /// A log cut off in its third record keeps the two before the cut; what follows counts as one unreadable part.
    func testACutOffLogKeepsTheRecordsBeforeTheCut() throws {
        let events = [event(3), event(2), event(1)]
        let data = try JSONEncoder().encode(events)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let third = try XCTUnwrap(text.range(of: events[2].id.uuidString))
        let cut = Data(text[..<third.upperBound].utf8)
        let reading = SetAsideLog.reading(cut)
        XCTAssertEqual(reading.records.map(\.id), [events[0].id, events[1].id])
        XCTAssertEqual(reading.unreadable, 1)
    }

    /// A closing and an opening brace between two escaped quotation marks inside a record's text (here another device's
    /// name) neither end the record nor start one: the reading skips what is inside a string, escapes included. Written
    /// after the fix, for its undo check.
    func testBracesAndQuotesInsideTextDoNotEndARecord() throws {
        var named = event(2)
        named.sourceDevice = "Kim's \"work } {\" iPhone"
        let events = [event(3), named, event(1)]
        let reading = SetAsideLog.reading(try JSONEncoder().encode(events))
        XCTAssertEqual(reading.records.map(\.id), events.map(\.id))
        XCTAssertEqual(reading.records.dropFirst().first?.sourceDevice, "Kim's \"work } {\" iPhone")
        XCTAssertEqual(reading.unreadable, 0)
    }

    /// A file that is not a log reads no record, and counts as one unreadable part; an empty file holds nothing.
    func testAFileThatIsNotALogReadsNothing() {
        let damaged = SetAsideLog.reading(Data("damaged".utf8))
        XCTAssertEqual(damaged.records, [])
        XCTAssertEqual(damaged.unreadable, 1)
        let empty = SetAsideLog.reading(Data())
        XCTAssertEqual(empty.records, [])
        XCTAssertEqual(empty.unreadable, 0)
    }

    /// Bytes after the list's end are damage too, and count as one unreadable part (item 218's Codex-3): the reader
    /// stopped at the closing bracket, so a log with other bytes after its records, which the log's own decoder refuses,
    /// read as whole, and a bracket too early hid the records after it. Written before the fix, red at that commit.
    func testBytesAfterTheListsEndCountAsOneUnreadablePart() throws {
        let one = try XCTUnwrap(String(data: JSONEncoder().encode([event(2)]), encoding: .utf8))
        let other = try XCTUnwrap(String(data: JSONEncoder().encode([event(1)]), encoding: .utf8))
        XCTAssertThrowsError(try StoredJSON.decode([Event].self, from: Data((one + "xyz").utf8)),
                             "such a log does not load, so it is set aside")
        let trailing = SetAsideLog.reading(Data((one + "xyz").utf8))
        XCTAssertEqual(trailing.records.count, 1)
        XCTAssertEqual(trailing.unreadable, 1, "the bytes after the list")
        let empty = SetAsideLog.reading(Data("[]xyz".utf8))
        XCTAssertEqual(empty.records, [])
        XCTAssertEqual(empty.unreadable, 1, "the bytes after an empty list")
        // A bracket too early: the list closes after its first record, and a second record follows.
        let early = SetAsideLog.reading(Data((one + "," + String(other.dropFirst())).utf8))
        XCTAssertEqual(early.records.count, 1)
        XCTAssertEqual(early.unreadable, 1, "the record after a bracket too early")
    }

    /// The control: white space after the list's end is not damage.
    func testWhiteSpaceAfterTheListsEndIsNotDamage() throws {
        let events = [event(2), event(1)]
        var data = try JSONEncoder().encode(events)
        data.append(Data(" \t\r\n\n".utf8))
        let reading = SetAsideLog.reading(data)
        XCTAssertEqual(reading.records.map(\.id), events.map(\.id))
        XCTAssertEqual(reading.unreadable, 0)
    }

    // MARK: - The list

    /// Only the set-aside event logs are listed, newest first, each with the time in its name; the other files the app
    /// keeps apart and the log itself are not.
    func testOnlyTheSetAsideEventLogsAreListedNewestFirst() throws {
        for name in ["events.corrupt-1762500000.json", "events.corrupt-1762520000.json", "limit-removals.corrupt-1762510000.json",
                     "events.json", "events.journal"] {
            try Data("x".utf8).write(to: scratch.appendingPathComponent(name))
        }
        let logs = SetAsideLog.all(in: scratch)
        XCTAssertEqual(logs.map(\.id), ["events.corrupt-1762520000.json", "events.corrupt-1762500000.json"])
        XCTAssertEqual(logs.first?.setAsideAt, Date(timeIntervalSince1970: 1_762_520_000))
    }

    /// The launch that sets the log aside lists it, and so does the next: it is kept until the owner deletes it.
    func testALaunchListsTheLogItSetAsideAndTheNextLaunchStillDoes() throws {
        try Data("damaged".utf8).write(to: try logURL())
        let settingAside = EventStore()
        XCTAssertTrue(settingAside.logWasQuarantined)
        XCTAssertEqual(settingAside.setAsideLogs.count, 1)
        settingAside.drainIOForTesting()
        let next = EventStore()
        XCTAssertEqual(next.setAsideLogs.map(\.id), settingAside.setAsideLogs.map(\.id), "still listed at the next launch")
    }

    /// A guard, green before the code and after: a launch never deletes or changes a set-aside log (since build 70).
    func testALaunchNeverDeletesOrChangesASetAsideLog() throws {
        try Data("damaged".utf8).write(to: try logURL())
        let settingAside = EventStore()
        settingAside.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("events.corrupt-") }
        XCTAssertEqual(names.count, 1)
        _ = EventStore()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(try XCTUnwrap(names.first))), Data("damaged".utf8))
    }

    /// Item 220's defect 4 (an outside reading of 1.11's public source; the owner, 2026-11-09: into 1.12): a log set aside
    /// in the same second as one still kept is kept too, under a name of its own. A set-aside log's name has whole
    /// seconds, so the move failed on the name already taken, and the store then wrote nothing until the next launch.
    /// The names taken here are those of this second and the next few: the test cannot know the second the store reads.
    /// Written before the fix, red at that commit.
    func testASecondSetAsideInTheSameSecondIsKeptUnderANameOfItsOwn() throws {
        let log = try logURL()
        let root = log.deletingLastPathComponent()
        let now = Int(Date().timeIntervalSince1970)
        let taken = (now...(now + 5)).map { root.appendingPathComponent("events.corrupt-\($0).json") }
        for url in taken { try Data("an earlier set-aside log".utf8).write(to: url) }
        try Data("damaged".utf8).write(to: log)

        let store = EventStore()
        XCTAssertFalse(store.loadFailed, "the log was set aside, so the store goes on writing")
        XCTAssertTrue(store.logWasQuarantined)
        for url in taken {
            XCTAssertEqual(try Data(contentsOf: url), Data("an earlier set-aside log".utf8), "the earlier ones are as they were")
        }
        let all = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("events.corrupt-") }
        let new = all.filter { name in !taken.contains { $0.lastPathComponent == name } }
        XCTAssertEqual(new.count, 1, "one more set-aside log: \(all)")
        let added = root.appendingPathComponent(try XCTUnwrap(new.first))
        XCTAssertEqual(try Data(contentsOf: added), Data("damaged".utf8), "the log as it was")
        XCTAssertNotNil(SetAsideLog(url: added).setAsideAt, "its name still says when")
        XCTAssertEqual(store.setAsideLogs.count, taken.count + 1, "each is listed")
    }

    /// The same defect on the store's two other files it sets aside, each named by the whole second too: the limit's
    /// removals here, the reports owed below. With this second's name taken, the file stayed in its place, and the
    /// store then left it there and wrote it no more until the next launch. Written before the fix, red at that commit.
    func testTheLimitsRemovalsSetAsideInATakenSecondKeepANameOfTheirOwn() throws {
        try assertSetAsideUnderANameOfItsOwn(EventStore.limitRemovalsFileName, namedFrom: "limit-removals.corrupt-")
    }

    func testTheReportsOwedSetAsideInATakenSecondKeepANameOfTheirOwn() throws {
        try assertSetAsideUnderANameOfItsOwn(EventStore.reportsOwedFileName, namedFrom: "reports-owed.corrupt-")
    }

    /// The name a file set aside takes: the plain one, with its seconds, while no name of that second is taken; then
    /// "-2", "-3" and so on, the number after the last one taken (item 226's Codex-6; the first one free, until then: the
    /// test below has the difference); and the plain one again when the last try is taken, where the move then fails as
    /// it did. Written with item 220's fix, for its undo check.
    func testAFileSetAsideTakesThePlainNameThenTheNumberAfterTheLastTaken() {
        let log = URL(fileURLWithPath: "/store/events.json")
        let at = Date(timeIntervalSince1970: 1_762_520_000)
        func name(taking: Set<String>, tries: Int = 100) -> String {
            EventStore.setAsideURL(for: log, now: at, tries: tries) { taking.contains($0.lastPathComponent) }.lastPathComponent
        }
        let plain = "events.corrupt-1762520000.json", second = "events.corrupt-1762520000-2.json"
        XCTAssertEqual(name(taking: []), plain)
        XCTAssertEqual(name(taking: [plain]), second)
        XCTAssertEqual(name(taking: [plain, second]), "events.corrupt-1762520000-3.json")
        XCTAssertEqual(name(taking: [plain, second], tries: 2), plain, "every try taken: the plain name, and the move fails")
        XCTAssertEqual(EventStore.corruptArtifactDate(second), at, "the name still gives its time")
        XCTAssertTrue(second.hasPrefix(SetAsideLog.namePrefix), "and is still a set-aside log's")
    }

    /// Set-aside logs of one second are listed newest first too. Item 220's defect 4 gave the later ones of a second a
    /// number after the seconds, the plain name being the first of them; by their names as text the plain one came first,
    /// and `-10` before `-2`. Found by a sweep of the documents against the code, whose note said "in the order of their
    /// names". Written before the fix, red at that commit.
    func testSetAsideLogsOfOneSecondAreListedNewestFirst() throws {
        let root = try logURL().deletingLastPathComponent()
        for name in ["events.corrupt-1762500000.json", "events.corrupt-1762520000.json", "events.corrupt-1762520000-2.json",
                     "events.corrupt-1762520000-10.json"] {
            try Data("[]".utf8).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(SetAsideLog.all(in: root).map(\.id),
                       ["events.corrupt-1762520000-10.json", "events.corrupt-1762520000-2.json", "events.corrupt-1762520000.json",
                        "events.corrupt-1762500000.json"])
    }

    /// Whether a name is taken is asked of the entry itself: a link that leads nowhere holds its name as a file does,
    /// and a move onto it fails the same. Asked through the link, the name would read as free. Written with the fix,
    /// for its undo check.
    func testANameALinkHoldsCountsAsTaken() throws {
        let log = try logURL()
        let root = log.deletingLastPathComponent()
        let at = Date(timeIntervalSince1970: 1_762_520_000)
        let plain = "events.corrupt-1762520000.json"
        XCTAssertEqual(EventStore.setAsideURL(for: log, now: at).lastPathComponent, plain, "free: the plain name")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(plain),
                                                   withDestinationURL: root.appendingPathComponent("nothing-here"))
        XCTAssertEqual(EventStore.setAsideURL(for: log, now: at).lastPathComponent, "events.corrupt-1762520000-2.json",
                       "a link that leads nowhere holds the name")
    }

    /// Codex-6 on the store's files (BACKLOG item 226; the owner, 2026-11-10: "yes, it is"): a name freed below the
    /// others of its second is not given again. The name was the first one free, while the list takes the number after
    /// the seconds as the order of making: with the plain name deleted and "-2" kept, the next file set aside in that
    /// second took the plain name and was listed as the older of the two. Written before the fix, red at that commit.
    func testAFileNameFreedBelowTheOthersOfItsSecondIsNotGivenAgain() {
        let log = URL(fileURLWithPath: "/store/events.json")
        let at = Date(timeIntervalSince1970: 1_762_520_000)
        func name(taking: Set<String>, tries: Int = 100) -> String {
            EventStore.setAsideURL(for: log, now: at, tries: tries) { taking.contains($0.lastPathComponent) }.lastPathComponent
        }
        let plain = "events.corrupt-1762520000.json", second = "events.corrupt-1762520000-2.json"
        let third = "events.corrupt-1762520000-3.json"
        XCTAssertEqual(name(taking: [second]), third, "after the last one taken")
        XCTAssertEqual(name(taking: [plain, third]), "events.corrupt-1762520000-4.json",
                       "a free name between two taken is passed over too")
        XCTAssertEqual(name(taking: [second], tries: 2), plain, "the last try taken: the plain name, as before")
    }

    /// The same through a launch and the list: with "-2" of a second kept and its plain name deleted, a log set aside in
    /// that second is listed above the one kept, as the newer of the two. The names taken are those of this second and
    /// the next few: the test cannot know the second the store reads. Written before the fix, red at that commit.
    func testALogSetAsideAfterADeletedOneOfItsSecondIsListedAboveTheOneKept() throws {
        let log = try logURL()
        let root = log.deletingLastPathComponent()
        let now = Int(Date().timeIntervalSince1970)
        let kept = (now...(now + 5)).map { root.appendingPathComponent("events.corrupt-\($0)-2.json") }
        for url in kept { try Data("an earlier set-aside log".utf8).write(to: url) }
        try Data("damaged".utf8).write(to: log)

        let store = EventStore()
        XCTAssertTrue(store.logWasQuarantined)
        let listed = SetAsideLog.all(in: root)
        let new = try XCTUnwrap(listed.first { entry in !kept.contains { $0.lastPathComponent == entry.id } },
                                "one more set-aside log: \(listed.map(\.id))")
        XCTAssertEqual(try Data(contentsOf: new.url), Data("damaged".utf8), "the log as it was")
        let second = try XCTUnwrap(new.setAsideAt, "its name says when")
        let ofItsSecond = listed.filter { $0.setAsideAt == second }.map(\.id)
        XCTAssertEqual(ofItsSecond.count, 2, "the one kept of that second, and the new one: \(ofItsSecond)")
        XCTAssertEqual(ofItsSecond.first, new.id, "the newer one is listed first: \(ofItsSecond)")
    }

    // MARK: - Share

    /// Share's folder: the README, the file as the phone kept it, byte for byte, and the photos and clips it names, and no
    /// other.
    func testShareCarriesTheFileAsKeptItsMediaAndAReadme() throws {
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg", other = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(named))
        try Data([0xFF, 0xD8, 0x02]).write(to: media.appendingPathComponent(other))
        var record = event(1)
        record.mediaFilename = named
        let bytes = try JSONEncoder().encode([record])
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try bytes.write(to: file)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: media, in: out))
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8), SetAsideLogWords.readme + "\n")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(file.lastPathComponent)), bytes, "the file as kept")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("Media").appendingPathComponent(named)), Data([0xFF, 0xD8, 0x01]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Media").appendingPathComponent(other).path),
                       "a photo it does not name stays out")
    }

    // MARK: - The words

    /// The words the owner approved. The explanation's third sentence no longer says the records are not in the event log
    /// above a row marked as also in it (item 213's fable-3; Claude's draft, approved by the owner on 2026-11-08). Home's
    /// notice is item 216's (the owner, 2026-11-09: "a, 1"), in the words the Event Log's row and What's New use: the words
    /// before, "An event log that couldn't be read is kept apart. Open the Event Log to read, share or delete it.", read
    /// clunkily. The explanation's last sentence is item 227's (DS-2): it said the records backed up to iCloud "are still
    /// there", which the screen does not check, and which the app's own iCloud retention makes untrue of old photos and
    /// clips as a matter of course.
    func testTheWordsAreTheOwnersApprovedOnes() {
        XCTAssertEqual(SetAsideLogWords.home, "Malinois set aside an event log it couldn't read. It's at the top of the Event Log.")
        XCTAssertEqual(SetAsideLogWords.title, "Set-aside log")
        XCTAssertEqual(SetAsideLogWords.explanation, "This log couldn't be read as a whole, so Malinois set it aside and started a new "
                       + "one. These are the records it could read. Except any marked below, they are not in your event log. A "
                       + "badge shows whether a record was backed up to iCloud when the log was set aside; Malinois doesn't check "
                       + "again.")
        XCTAssertFalse(SetAsideLogWords.explanation.contains("still there"), "nothing here says what iCloud has now")
        XCTAssertEqual(SetAsideLogWords.alsoInLog, "Also in your event log")
        XCTAssertEqual(SetAsideLogWords.noneReadable, "No records could be read.")
        XCTAssertEqual(SetAsideLogWords.readme, "This ZIP contains an event log Malinois set aside because it couldn't be read, with "
                       + "the photos and clips it names that were still on the iPhone when it was shared. It is not signed "
                       + "evidence: it is the file as the phone kept it. Malinois's verifier does not check it.")
    }

    /// The Event Log's row: when it was set aside, as the event log's lines give a time, and how many records it could and
    /// could not read.
    func testTheRowSaysWhenAndHowMany() {
        let at = Date(timeIntervalSince1970: 1_762_520_700)
        let when = "\(at.formatted(.dateTime.month(.abbreviated).day())), \(at.formatted(date: .omitted, time: .shortened))"
        XCTAssertEqual(SetAsideLogWords.row(setAsideAt: at, records: 37, unreadable: 2), "Set-aside log, \(when): 37 records, 2 unreadable")
        XCTAssertEqual(SetAsideLogWords.row(setAsideAt: at, records: 1, unreadable: 0), "Set-aside log, \(when): 1 record")
        XCTAssertEqual(SetAsideLogWords.row(setAsideAt: nil, records: 0, unreadable: 1), "Set-aside log: 0 records, 1 unreadable")
    }

    // MARK: - Where it shows (the app's screens, read from the source tree, as built)

    /// Home says so while any set-aside log is kept, not only at the launch that set it aside.
    func testHomeSaysSoWhileAnyIsKept() throws {
        let home = try source("Malinois/Views/HomeView.swift")
        XCTAssertTrue(home.contains("if !eventStore.setAsideLogs.isEmpty {"))
        XCTAssertTrue(home.contains("Label(SetAsideLogWords.home,"))
        XCTAssertFalse(home.contains("if eventStore.logWasQuarantined {"), "no longer only at the launch that set it aside")
    }

    /// The Event Log lists each set-aside log at its top, even when the fresh log is empty, and opens its screen. Since
    /// item 227 it also shows what a Delete left to tell with nothing else to list (red at that item's first commit, by
    /// its first line).
    func testTheEventLogListsThemAtItsTop() throws {
        let log = try source("Malinois/Views/EventLogView.swift")
        XCTAssertTrue(log.contains("if eventStore.events.isEmpty && eventStore.setAsideLogs.isEmpty && deleteNotices.isEmpty {"))
        XCTAssertTrue(log.contains("ForEach(eventStore.setAsideLogs) { setAside in"))
        XCTAssertTrue(log.contains("SetAsideLogView(log: setAside)"))
    }

    /// A set-aside log's screen opens each record read only: no Share of its own, no download, no store.
    func testARecordFromASetAsideLogOpensReadOnly() throws {
        let screen = try source("Malinois/Views/SetAsideLogView.swift")
        XCTAssertTrue(screen.contains("EventDetailView(event: record, setAside: true)"))
        let detail = try source("Malinois/Views/EventDetailView.swift")
        XCTAssertTrue(detail.contains("var setAside = false"))
        XCTAssertTrue(detail.contains("if !setAside {"), "no Share of its own")
        XCTAssertTrue(detail.contains("if !setAside, current.mayLackAFileHere"), "no download")
    }

    // MARK: - Delete (the owner, 2026-11-07: "as you recommend, wording approved": the photos and clips only it names go at once)

    /// Delete's confirmation and button, in the owner's words. Since item 227 the message says that the photos and clips
    /// go from this iPhone whatever iCloud has of them (DS-2), and that the sweep runs again once no set-aside log is kept
    /// (DS-1: ADR 0078's decision 3 had it, and nothing told the owner).
    func testTheDeleteWordsAreTheOwnersApprovedOnes() {
        XCTAssertEqual(SetAsideLogWords.deleteTitle, "Delete this set-aside log?")
        XCTAssertEqual(SetAsideLogWords.deleteMessage, "The photos and clips only it names are deleted from this iPhone too, whether or "
                       + "not iCloud has full copies of them. After the last set-aside log is deleted, Malinois also clears photos "
                       + "and clips that no record names. This can't be undone.")
        XCTAssertEqual(SetAsideLogWords.deleteButton, "Delete")
    }

    /// Of the photos and clips a deleted log names, only those nothing else names go: not the event log's in memory or on
    /// disk, not another set-aside log's, not a capture's still being saved; and none at all when the log on disk or a
    /// capture's record could not be read.
    func testOnlyTheMediaNothingElseNamesGoWithTheLog() {
        let named = ["a.jpg", "b.jpg", "c.jpg", "d.jpg", "e.mov"]
        XCTAssertEqual(EventStore.mediaGoingWithASetAsideLog(named: named, inMemory: ["b.jpg"], onDisk: ["c.jpg"],
                                                             otherLogs: ["d.jpg"], saving: ["e.mov"]), ["a.jpg"])
        XCTAssertEqual(EventStore.mediaGoingWithASetAsideLog(named: named, inMemory: [], onDisk: nil, otherLogs: [], saving: []), [],
                       "the log on disk could not be read: none")
        XCTAssertEqual(EventStore.mediaGoingWithASetAsideLog(named: named, inMemory: [], onDisk: [], otherLogs: [], saving: nil), [],
                       "a capture's record could not be read: none")
    }

    /// The whole path: Delete removes the log, and at once the photo only it names, keeping the one the event log names,
    /// the one another set-aside log names and one it does not name; the list no longer has it.
    func testDeleteRemovesTheLogAndAtOnceTheMediaOnlyItNames() async throws {
        let store = EventStore()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let only = "\(UUID().uuidString).jpg", inTheLog = "\(UUID().uuidString).jpg"
        let inAnother = "\(UUID().uuidString).jpg", unnamed = "\(UUID().uuidString).jpg"
        for name in [only, inTheLog, inAnother, unnamed] { try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(name)) }
        var live = event(4)
        live.mediaFilename = inTheLog
        store.add(live)
        store.drainIOForTesting()
        let deleting = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(only, minute: 1), recorded(inTheLog, minute: 2), recorded(inAnother, minute: 3)]).write(to: deleting)
        let other = root.appendingPathComponent("events.corrupt-1762500000.json")
        try JSONEncoder().encode([recorded(inAnother, minute: 5)]).write(to: other)
        store.refreshSetAsideLogs()
        XCTAssertEqual(store.setAsideLogs.count, 2)

        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: deleting))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [], "a whole delete has nothing to tell")
        XCTAssertFalse(FileManager.default.fileExists(atPath: deleting.path), "the log")
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.appendingPathComponent(only).path), "the photo only it named, at once")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(inTheLog).path), "the event log's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(inAnother).path), "another set-aside log's")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent(unnamed).path), "one it did not name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "the other set-aside log")
        XCTAssertEqual(store.setAsideLogs.map(\.id), [other.lastPathComponent])
    }

    /// Delete deletes nothing but a set-aside log in the store's own folder: not the event log, and not a file of that name
    /// elsewhere (a guard, green before the code and after). Since item 227 a refusal is kept to tell, as any Delete that
    /// deleted nothing is (red at that item's first commit, by those two lines).
    func testDeleteRefusesAnyOtherFile() async throws {
        let store = EventStore()
        store.add(event(1))
        store.drainIOForTesting()
        let log = try logURL()
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path))
        let refusedLog = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(refusedLog, .notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted], "kept to tell")
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.path), "the event log stays")
        let elsewhere = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try Data("x".utf8).write(to: elsewhere)
        let refusedElsewhere = await store.deleteSetAsideLog(SetAsideLog(url: elsewhere))
        XCTAssertEqual(refusedElsewhere, .notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted], "kept to tell")
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "not in the store's folder: it stays")
    }

    /// Its screen offers Delete behind the approved confirmation, deletes through the store, and leaves for the Event Log.
    /// Since item 232 the PIN pad comes first, built with no leave for a face or finger (the tests of the screen laid out
    /// are below; these lines are the pad's as written).
    func testItsScreenDeletesBehindTheConfirmation() throws {
        let screen = try source("Malinois/Views/SetAsideLogView.swift")
        XCTAssertTrue(screen.contains("PINEntryView(title: SetAsideLogWords.deletePINTitle) {"), "the pad, PIN only")
        XCTAssertFalse(screen.contains("allowBiometrics"), "nothing on the screen allows a face or finger")
        XCTAssertTrue(screen.contains(".confirmationDialog(SetAsideLogWords.deleteTitle"))
        XCTAssertTrue(screen.contains("Text(SetAsideLogWords.deleteMessage)"))
        XCTAssertTrue(screen.contains("Button(SetAsideLogWords.deleteButton, role: .destructive)"))
        // The confirmation's own button runs the delete: the laid-out tests press the dialog's action through a Debug
        // hook, not the button iOS draws, so this line is what holds the button to it (Codex's look at round nine).
        XCTAssertTrue(screen.contains("Button(SetAsideLogWords.deleteButton, role: .destructive, action: delete)"),
                      "the confirmation's button deletes")
        XCTAssertTrue(screen.contains("await engine.deleteSetAsideLog(log)"), "through the engine, which writes the entry (item 234)")
        let views = Self.root.appendingPathComponent("Malinois/Views")
        for file in try FileManager.default.contentsOfDirectory(atPath: views.path) where file.hasSuffix(".swift") {
            XCTAssertFalse(try source("Malinois/Views/" + file).contains("eventStore.deleteSetAsideLog"),
                           "\(file) deletes through the store, which writes no entry")
        }
        XCTAssertTrue(screen.contains("dismiss()"))
    }

    // MARK: - Delete says what it left (item 227's DS-5; the owner, 2026-11-10: "2")
    //
    // The full review of 1.12 (87): where Delete cannot tell which photos and clips are only the log's own, it removes the
    // log and rightly leaves them (ADR 0078's decision 3), and its screen closed as after a whole delete. Now the store
    // answers what happened, and the Event Log, where that screen leaves for, says so until the owner dismisses it.
    // Written before the fix, red at that commit, one test for each place the answer is decided; the tests below of a
    // log that cannot be read and of a linked media folder are red there too, by their new answers.

    /// The notices' words. A whole delete has none.
    func testTheDeleteNoticesAreTheOwnersApprovedOnes() {
        XCTAssertNil(SetAsideLogWords.deleteNotice(for: .deleted))
        XCTAssertEqual(SetAsideLogWords.deleteNotice(for: .deletedMediaLeft),
                       SetAsideLogWords.DeleteNotice(title: Self.leftTitle, message: Self.leftMessage))
        XCTAssertEqual(SetAsideLogWords.deleteNotice(for: .notDeleted),
                       SetAsideLogWords.DeleteNotice(title: Self.notDeletedTitle, message: "Nothing was deleted."))
    }

    /// The event log on disk cannot be read, so Malinois cannot tell which of the log's photos are only its own: the log
    /// goes, the photo stays, and the answer says so.
    func testDeleteSaysThePhotosStayedWhenTheEventLogOnDiskCannotBeRead() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        store.drainIOForTesting()
        try Data("not a log".utf8).write(to: try logURL())
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "the photo stays")
    }

    /// A capture still being saved has a record that cannot be read: the same answer.
    func testDeleteSaysThePhotosStayedWhenACapturesRecordCannotBeRead() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("not a record".utf8).write(to: attachments.appendingPathComponent("\(UUID().uuidString).json"))
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "the photo stays")
    }

    /// Another set-aside log cannot be read, so it may name the photo too: the same answer, where the photo stayed
    /// without a word.
    func testDeleteSaysThePhotosStayedWhenAnotherSetAsideLogCannotBeRead() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let other = log.deletingLastPathComponent().appendingPathComponent("events.corrupt-1762500000.json")
        try Data("sealed".utf8).write(to: other)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: other.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path) }
        XCTAssertNil(try? Data(contentsOf: other), "the test's other log cannot be read")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "and so does the other log")
    }

    /// The store's own folder cannot be listed, so whether another set-aside log names the photo is not known: the same
    /// answer.
    func testDeleteSaysThePhotosStayedWhenTheStoresFolderCannotBeListed() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let root = log.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertNil(try? fm.contentsOfDirectory(atPath: root.path), "the test's folder cannot be listed")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays")
    }

    /// The media folder cannot be listed, so what the log names there is not known: the same answer.
    func testDeleteSaysThePhotosStayedWhenTheMediaFolderCannotBeListed() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let media = photo.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: media.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: media.path) }
        XCTAssertNil(try? fm.contentsOfDirectory(atPath: media.path), "the test's media folder cannot be listed")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
    }

    /// Item 228 (Codex-7): nothing in the store's folder can be looked at (the folder cannot be searched), so whether
    /// the log is there is not known. That is not a log already gone: nothing is deleted, and the answer says so. It
    /// was answered as deleted, with nothing to tell.
    func testDeleteOfALogThatCannotBeLookedAtDeletesNothingAndSaysSo() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let bytes = try Data(contentsOf: log)
        let root = log.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: root.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try fm.attributesOfItem(atPath: log.path), "the test's log cannot be looked at")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        XCTAssertEqual(deleted, .notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted])
        XCTAssertEqual(try? Data(contentsOf: log), bytes, "the log stays as it was")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "and so does its photo")
    }

    /// Item 228 (Codex-8): the photo the log names cannot be looked at (its folder cannot be searched), so whether it is
    /// a photo of the log's is not known: the log goes, the photo stays, and the answer says so. Where the folder could
    /// still be listed, the photo was passed over as if it were no file, and the delete counted as a whole one. That
    /// the folder can be listed is not asserted: it can on the iOS 27.0 simulator (Codex's run; this test fails there
    /// without the fix), it cannot on macOS, and where it cannot the listing's own guard gives the same answer.
    func testDeleteSaysThePhotosStayedWhenAPhotoCannotBeLookedAt() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let media = photo.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: media.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: media.path) }
        XCTAssertThrowsError(try fm.attributesOfItem(atPath: photo.path), "the test's photo cannot be looked at")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: media.path)
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays")
    }

    /// Item 229 (Codex-9): the event log's name is a link, and the file it leads to cannot be reached (its folder cannot
    /// be searched), as only a restore of an edited backup makes it. That is not "no event log": the linked log still
    /// names the photo, so the set-aside log goes, the photo stays, and the answer says so. The check followed the
    /// link, took its failure for "no file", and the photo went with the log. The link is there before the store
    /// starts, as after a restore: the launch reads no log through it, and leaves it.
    func testDeleteKeepsAPhotoWhenTheEventLogIsALinkThatCannotBeFollowed() async throws {
        let fm = FileManager.default
        let name = "\(UUID().uuidString).jpg"
        let elsewhere = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let linked = elsewhere.appendingPathComponent("events.json")
        let bytes = try JSONEncoder().encode([recorded(name, minute: 2)])
        try bytes.write(to: linked)
        let live = try logURL()
        try fm.createSymbolicLink(at: live, withDestinationURL: linked)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: elsewhere.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: elsewhere.path) }
        XCTAssertFalse(fm.fileExists(atPath: live.path), "the test's link cannot be followed")
        XCTAssertTrue(isLink(live), "and it is there")

        let store = EventStore()
        store.drainIOForTesting()
        XCTAssertTrue(store.events.isEmpty, "the launch read no log")
        XCTAssertTrue(isLink(live), "and left the link")
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = store.mediaDirectory
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let photo = media.appendingPathComponent(name)
        try Data([0xFF, 0xD8, 0x01]).write(to: photo)
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(name, minute: 1)]).write(to: log)
        store.refreshSetAsideLogs()

        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: elsewhere.path)
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the set-aside log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo the linked log names stays")
        XCTAssertEqual(try? Data(contentsOf: linked), bytes, "and the linked log is as it was")
    }

    /// Item 229: Delete reads no event log through a link, even one that can be followed (the launch still does: BACKLOG
    /// item 224). Here the linked log is empty, so read through the link it would name no photo, and the photo would
    /// go with the set-aside log: Delete cannot tell what is named on disk, leaves the photo and says so.
    func testDeleteReadsNoEventLogThroughALink() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let linked = scratch.appendingPathComponent("an-empty-log.json")
        try Data("[]".utf8).write(to: linked)
        let live = try logURL()
        try? fm.removeItem(at: live)
        try fm.createSymbolicLink(at: live, withDestinationURL: linked)
        XCTAssertEqual(try? Data(contentsOf: live), Data("[]".utf8), "the test's link can be followed")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays")
    }

    /// Item 229, Codex-9's twin: the folder of captures still being saved is a link that cannot be followed. That is not
    /// "no capture being saved": one of them may name the photo, so the answer is the same. Its check followed the link
    /// too.
    func testDeleteKeepsAPhotoWhenTheCapturesFolderIsALinkThatCannotBeFollowed() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let elsewhere = scratch.appendingPathComponent("elsewhere", isDirectory: true)
        let target = elsewhere.appendingPathComponent("MediaAttachments", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try? fm.removeItem(at: attachments)
        try fm.createSymbolicLink(at: attachments, withDestinationURL: target)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: elsewhere.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: elsewhere.path) }
        XCTAssertFalse(fm.fileExists(atPath: attachments.path), "the test's link cannot be followed")
        XCTAssertTrue(isLink(attachments), "and it is there")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: elsewhere.path)
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays")
    }

    /// A guard, green before the fix and after: with nothing under the event log's name and nothing under the captures'
    /// folder's (a log just set aside, and no new event yet), nothing else names the photo, and it goes with the log.
    func testDeleteWithNoEventLogAndNoCapturesFolderRemovesThePhotoOnlyItNames() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        for name in ["events.json", "MediaAttachments"] {
            try? fm.removeItem(at: root.appendingPathComponent(name))
            XCTAssertThrowsError(try fm.attributesOfItem(atPath: root.appendingPathComponent(name).path), "no \(name) here")
        }
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertFalse(fm.fileExists(atPath: photo.path), "and the photo only it names")
    }

    /// A guard, green before the fix and after: the captures' folder is there, a real folder with nothing waiting in it,
    /// as on a phone that has saved a capture before. No capture names the photo, and it goes with the log.
    func testDeleteWithAnEmptyCapturesFolderRemovesThePhotoOnlyItNames() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let attachments = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("MediaAttachments")
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: attachments.path), [], "the test's folder has nothing waiting")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertFalse(fm.fileExists(atPath: photo.path), "and the photo only it names")
    }

    /// The photo only the log names cannot be removed (its folder takes no changes): the log goes, the photo is still
    /// there, and the answer says so, where the failure was dropped.
    func testDeleteSaysAPhotoStayedWhenItCouldNotBeRemoved() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let media = photo.deletingLastPathComponent()
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: media.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: media.path) }
        XCTAssertFalse(fm.createFile(atPath: media.appendingPathComponent("probe").path, contents: Data()),
                       "the test's media folder takes no changes")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo could not be removed")
    }

    /// A guard, green before the fix and after: with the media folder gone (the store makes it again, empty, whenever it
    /// is asked for) there is nothing to leave, and nothing to tell.
    func testDeleteWithNoMediaFolderHasNothingToTell() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        try FileManager.default.removeItem(at: photo.deletingLastPathComponent())
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the log goes")
    }

    /// A guard, green before the fix and after: a log whose photos the event log names too goes alone, as its
    /// confirmation says ("only it names"), and there is nothing to tell.
    func testDeleteOfALogWhosePhotosOthersNameHasNothingToTell() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        var live = event(4)
        live.mediaFilename = photo.lastPathComponent
        store.add(live)
        store.drainIOForTesting()
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "the event log's photo stays")
    }

    /// A guard, green before the fix and after: a log that names no photo or clip on the phone goes alone, with another
    /// log's photo beside it untouched, and there is nothing to tell.
    func testDeleteOfALogThatNamesNoPhotoHasNothingToTell() async throws {
        let (store, other, photo) = try storeWithALogNamingAPhoto()
        let log = other.deletingLastPathComponent().appendingPathComponent("events.corrupt-1762500000.json")
        try JSONEncoder().encode([event(2)]).write(to: log)
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path), "the other log's photo stays")
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path), "and so does the other log")
    }

    /// A Delete that deleted nothing is told too. A whole delete after it takes nothing away: what was to tell stays until
    /// the owner dismisses it.
    func testADeleteThatDeletedNothingIsToldUntilTheOwnerDismissesIt() async throws {
        let fm = FileManager.default
        let (store, log, _) = try storeWithALogNamingAPhoto()
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(1)]).write(to: another)
        let linkLog = log.deletingLastPathComponent().appendingPathComponent("events.corrupt-1762500000.json")
        try fm.createSymbolicLink(at: linkLog, withDestinationURL: another)
        let refused = await store.deleteSetAsideLog(SetAsideLog(url: linkLog))
        XCTAssertEqual(refused, .notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted])
        try fm.removeItem(at: linkLog)   // a link under a set-aside log's name keeps every photo (item 218)
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted], "a whole delete takes nothing away")
        store.setAsideDeletionWasTold(.notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [], "the owner dismissed it")
    }

    /// Each kind is kept once, in the order it happened, and dismissing one leaves the other: a second Delete that left
    /// its photos adds nothing, and one that deleted nothing is told beside it, where one answer took the other's place.
    func testEachKindOfAnswerIsKeptOnceUntilItIsDismissed() async throws {
        let fm = FileManager.default
        let (store, first, _) = try storeWithALogNamingAPhoto()
        let root = first.deletingLastPathComponent()
        let second = root.appendingPathComponent("events.corrupt-1762510000.json")
        try fm.copyItem(at: first, to: second)
        try Data("not a log".utf8).write(to: try logURL())   // neither Delete can tell which photos are only its log's
        let left = await store.deleteSetAsideLog(SetAsideLog(url: first))
        let leftAgain = await store.deleteSetAsideLog(SetAsideLog(url: second))
        XCTAssertEqual([left, leftAgain], [.deletedMediaLeft, .deletedMediaLeft])
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft], "once")
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(1)]).write(to: another)
        let linkLog = root.appendingPathComponent("events.corrupt-1762500000.json")
        try fm.createSymbolicLink(at: linkLog, withDestinationURL: another)
        let refused = await store.deleteSetAsideLog(SetAsideLog(url: linkLog))
        XCTAssertEqual(refused, .notDeleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft, .notDeleted], "both, in order")
        store.setAsideDeletionWasTold(.deletedMediaLeft)
        XCTAssertEqual(store.setAsideDeletionsToTell, [.notDeleted], "the other stays")
    }

    /// A second Delete of a log already gone (asked twice, the first still under way when the second was) finds nothing
    /// under its name: it has nothing to tell, and takes nothing from what the first left to tell. It said the log
    /// "couldn't be deleted".
    func testASecondDeleteOfALogAlreadyGoneTellsNothing() async throws {
        let (store, log, _) = try storeWithALogNamingAPhoto()
        store.drainIOForTesting()
        try Data("not a log".utf8).write(to: try logURL())
        let first = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(first, .deletedMediaLeft)
        let second = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(second, .deleted, "the log is gone, as asked")
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft], "the first Delete's answer is still to tell")
    }

    /// The Event Log after a Delete that had to leave the photos, laid out: it says so, and it does so even with nothing
    /// else to list, where it showed "No events".
    func testTheEventLogSaysWhenADeletedLogsPhotosMayHaveStayed() async throws {
        let (store, log, _) = try storeWithALogNamingAPhoto()
        store.drainIOForTesting()
        try Data("not a log".utf8).write(to: try logURL())
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft)
        XCTAssertTrue(store.setAsideLogs.isEmpty && store.events.isEmpty, "nothing else to list")
        let shown = try shownOnScreen(eventLog(of: store)).shown
        XCTAssertTrue(shown.contains(Self.leftTitle), "\(shown)")
        XCTAssertTrue(shown.contains(Self.leftMessage), "\(shown)")
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft], "leaving the Event Log does not dismiss it")
    }

    /// The Event Log after a Delete that deleted nothing, laid out above an event: it says so.
    func testTheEventLogSaysWhenASetAsideLogCouldNotBeDeleted() async throws {
        let fm = FileManager.default
        let store = EventStore()
        store.add(event(1))
        store.drainIOForTesting()
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(2)]).write(to: another)
        let linkLog = try logURL().deletingLastPathComponent().appendingPathComponent("events.corrupt-1762500000.json")
        try fm.createSymbolicLink(at: linkLog, withDestinationURL: another)
        let refused = await store.deleteSetAsideLog(SetAsideLog(url: linkLog))
        XCTAssertEqual(refused, .notDeleted)
        let shown = try shownOnScreen(eventLog(of: store)).shown
        XCTAssertTrue(shown.contains(Self.notDeletedTitle), "\(shown)")
        XCTAssertTrue(shown.contains("Nothing was deleted."), "\(shown)")
    }

    /// The control: after a whole delete the Event Log, laid out the same way, has no notice.
    func testTheEventLogSaysNothingAfterAWholeDelete() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        store.add(event(1))
        store.drainIOForTesting()
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path), "the photo only it named went")
        let shown = try shownOnScreen(eventLog(of: store)).shown
        XCTAssertFalse(shown.contains(Self.leftTitle) || shown.contains(Self.notDeletedTitle), "\(shown)")
    }

    /// The notice goes when the owner presses its OK, on the Event Log laid out for real: the row leaves the screen, and
    /// the store has nothing left to tell.
    func testTheEventLogsNoticeGoesWhenTheOwnerDismissesIt() async throws {
        let (store, log, _) = try storeWithALogNamingAPhoto()
        store.drainIOForTesting()
        try Data("not a log".utf8).write(to: try logURL())
        _ = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        let recorder = OnScreenRecorder()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIHostingController(rootView: eventLog(of: store).environment(\.onScreenRecorder, recorder))
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        let pressed = "OK: " + Self.leftTitle
        let offered = await settles { recorder.shown.contains(Self.leftTitle) && recorder.actions[pressed] != nil }
        XCTAssertTrue(offered, "the notice and its OK are on the screen: \(recorder.shown)")
        recorder.actions[pressed]?()
        let gone = await settles { !recorder.shown.contains(Self.leftTitle) }
        XCTAssertTrue(gone, "the notice left the screen: \(recorder.shown)")
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
    }

    // MARK: - Nothing live on a set-aside record (item 213: Fable's fable-1, and the path inventory of its shape)

    /// A set-aside record never asks iCloud when its phone was last heard from, so its screen has no "Last heard from"
    /// row, which would say "Checking iCloud" for good (fable-1).
    func testASetAsideRecordShowsNoLastHeardRow() {
        XCTAssertFalse(Heartbeat.showsLastHeard(for: otherPhonesArm(.synced), pro: true, setAside: true))
    }

    /// A set-aside record never uploads: its iCloud badge says "Synced when set aside" if it was backed up before the log
    /// was set aside and "Local only" otherwise, never "Syncing…", and no hold applies to it. Not "iCloud synced", which
    /// reads as checked now: the screen never asks iCloud about a set-aside record (item 227's DS-2).
    func testASetAsideRecordsBadgeSaysWhereItIs() {
        XCTAssertEqual(CloudSyncState.synced.badge(held: false, setAside: true), "Synced when set aside")
        XCTAssertEqual(CloudSyncState.pending.badge(held: false, setAside: true), "Local only")
        XCTAssertEqual(CloudSyncState.localOnly.badge(held: false, setAside: true), "Local only")
        XCTAssertEqual(CloudSyncState.synced.badge(held: true, setAside: true), "Synced when set aside", "no hold applies")
    }

    /// A set-aside record's badge is grey whatever it says: green would read as a state checked now (item 227's DS-2). The
    /// two screens that draw it, read from the source tree.
    func testASetAsideRecordsBadgeIsGrey() throws {
        let row = try source("Malinois/Views/EventLogView.swift")
        XCTAssertTrue(row.contains("if setAside { return .secondary }"), "the row")
        let detail = try source("Malinois/Views/EventDetailView.swift")
        XCTAssertTrue(detail.contains("if setAside { return .secondary }"), "the event's screen")
    }

    /// The guard: a record of the event log keeps its "Last heard from" row and its badge as before.
    func testARecordOfTheLogKeepsItsBadgeAndLastHeard() {
        XCTAssertTrue(Heartbeat.showsLastHeard(for: otherPhonesArm(.pending), pro: true, setAside: false))
        XCTAssertEqual(CloudSyncState.pending.badge(held: false, setAside: false), "Syncing…")
        XCTAssertEqual(CloudSyncState.synced.badge(held: false, setAside: false), "iCloud synced")
        XCTAssertEqual(CloudSyncState.localOnly.badge(held: false, setAside: false), "Local only")
        XCTAssertEqual(CloudSyncState.pending.badge(held: true, setAside: false), "Local only", "a held upload")
    }

    /// The screens use them: for a set-aside record the event's screen asks for neither a heartbeat nor a hold, and its
    /// iCloud row says where the record is; the set-aside log's rows do the same, with no hold note, and are told whether
    /// the event log also has the record (item 214).
    func testTheScreensAskNothingLiveOfASetAsideRecord() throws {
        let detail = try source("Malinois/Views/EventDetailView.swift")
        XCTAssertEqual(detail.components(separatedBy: "Heartbeat.showsLastHeard(for: current, pro: entitlements.proActive, "
                                         + "setAside: setAside)").count - 1, 2, "the read and the row")
        XCTAssertTrue(detail.contains("guard !setAside, entitlements.proActive else { return nil }"), "no hold reason")
        XCTAssertTrue(detail.contains("current.cloudSyncState.badge(held: holdReason != nil, setAside: setAside)"))
        let row = try source("Malinois/Views/EventLogView.swift")
        XCTAssertTrue(row.contains("guard !setAside, entitlements.proActive else { return nil }"), "no hold note")
        XCTAssertTrue(row.contains("event.cloudSyncState.badge(held: holdReason != nil, setAside: setAside)"))
        let screen = try source("Malinois/Views/SetAsideLogView.swift")
        XCTAssertTrue(screen.contains("EventRow(event: record, setAside: true, alsoInLog: alsoInLog)"))
    }

    // MARK: - No iCloud badge on a set-aside record the event log also has (item 214's fable-4)

    /// A set-aside record the event log also has shows no iCloud badge on the set-aside log's screens: its copy there keeps
    /// the state the file froze, often "waiting to upload" for a record the journal brought back, while the event log's
    /// row for it, which the mark "Also in your event log" points to, has the badge that is true now.
    func testNoICloudBadgeOnASetAsideRecordTheEventLogAlsoHas() {
        XCTAssertFalse(CloudSyncState.showsBadge(setAside: true, alsoInLog: true))
    }

    /// The guard: every other record keeps its badge, a set-aside record only that log has and every record of the event
    /// log.
    func testEveryOtherRecordKeepsItsICloudBadge() {
        XCTAssertTrue(CloudSyncState.showsBadge(setAside: true, alsoInLog: false), "a set-aside record only that log has")
        XCTAssertTrue(CloudSyncState.showsBadge(setAside: false, alsoInLog: false), "a record of the event log")
        XCTAssertTrue(CloudSyncState.showsBadge(setAside: false, alsoInLog: true), "a record of the event log, however asked")
    }

    /// The set-aside log's screen, laid out with a store whose event log has one of its records, uploaded since: that row
    /// shows the mark and no badge, while the row of a record only the set-aside log has keeps its badge. The two records
    /// were frozen in different states, so the test can tell which row lost its badge and which has the mark (item 215's
    /// fable-8: when both read "Local only", the mark and the missing badge could move to the wrong row unseen).
    func testTheSetAsideScreenShowsNoBadgeOnARowTheEventLogAlsoHas() async throws {
        let rig = makeScreenRig()
        var onlyThere = event(1)
        onlyThere.cloudSyncState = .synced   // its frozen badge reads "Synced when set aside"
        let inBoth = event(2)                // frozen waiting to upload: "Local only", were its badge shown
        var uploaded = inBoth
        uploaded.cloudSyncState = .synced
        rig.store.add(uploaded)
        rig.store.drainIOForTesting()
        // The record the event log also has comes last, so its mark shows only once both rows are laid out.
        let log = try setAsideLog([onlyThere, inBoth])
        let screen = try await shownOnScreen(screenOf(NavigationStack { SetAsideLogView(log: log) }, rig),
                                             until: { $0.contains(SetAsideLogWords.alsoInLog) && $0.contains(Self.syncedThen) })
        let shown = screen.shown
        XCTAssertEqual(shown.filter { $0 == SetAsideLogWords.alsoInLog }.count, 1, "\(shown)")
        XCTAssertEqual(shown.filter { $0 == Self.syncedThen }.count, 1, "the record only the set-aside log has: \(shown)")
        XCTAssertFalse(shown.contains("iCloud synced"), "no badge here says what iCloud has now: \(shown)")
        XCTAssertFalse(shown.contains("Local only"), "the record the event log also has shows no badge: \(shown)")
        // The mark is under the next row, not under the badge's own: a whole row lies between them, where a mark in the
        // badge's row would sit a few points below it.
        let badge = try XCTUnwrap(screen.frames[Self.syncedThen])
        let mark = try XCTUnwrap(screen.frames[SetAsideLogWords.alsoInLog])
        XCTAssertGreaterThan(mark.minY - badge.maxY, 2 * badge.height, "the mark is under the other row: \(badge), \(mark)")
    }

    /// The event's screen of a set-aside record the event log also has shows no iCloud row; that of a record only the
    /// set-aside log has, laid out the same way, shows its own.
    func testTheEventScreenOfASetAsideRecordTheEventLogAlsoHasShowsNoBadge() throws {
        let rig = makeScreenRig()
        let onlyThere = event(1), inBoth = event(2)
        var uploaded = inBoth
        uploaded.cloudSyncState = .synced
        rig.store.add(uploaded)
        rig.store.drainIOForTesting()
        let alone = try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: onlyThere, setAside: true) }, rig)).shown
        XCTAssertTrue(alone.contains("Local only"), "the screen is laid out: \(alone)")
        let both = try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: inBoth, setAside: true) }, rig)).shown
        XCTAssertTrue(both.filter(Self.badges.contains).isEmpty, "\(both)")
    }

    /// The guard: the event's screen of a set-aside record only that log has keeps its badge, "Synced when set aside" for
    /// one backed up before its log was set aside (item 227's DS-2: it read "iCloud synced") and "Local only" otherwise.
    func testTheEventScreenOfASetAsideRecordOnlyThereKeepsItsBadge() throws {
        let rig = makeScreenRig()
        var backedUp = event(3)
        backedUp.cloudSyncState = .synced
        let waiting = event(4)
        let ofBackedUp = try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: backedUp, setAside: true) }, rig)).shown
        XCTAssertTrue(ofBackedUp.contains(Self.syncedThen), "\(ofBackedUp)")
        XCTAssertFalse(ofBackedUp.contains("iCloud synced"), "\(ofBackedUp)")
        XCTAssertTrue(try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: waiting, setAside: true) }, rig))
            .shown.contains("Local only"))
    }

    // MARK: - A folder or a link is not a file (item 218's Codex-1; the owner, 2026-11-09: "as you recommend, wording approved")
    //
    // Codex's look at all of 1.12: a set-aside log's list, Share and Delete took whatever had the right name. Only an edited
    // backup restored to the phone can put a folder or a link there, and the app already refuses both for an event's own
    // photo and clip (item 190's deepseek-5). Written before the fix, red at that commit, each beside an ordinary-file
    // control: the tests above, and the plain files below.

    /// Only a plain file named like a set-aside log is one: a folder or a link under such a name is not listed, so it has
    /// no row, no notice on Home, no Share and no Delete.
    func testAFolderOrALinkNamedLikeASetAsideLogIsNotListed() throws {
        try Data("x".utf8).write(to: scratch.appendingPathComponent("events.corrupt-1762520000.json"))
        try folder(scratch.appendingPathComponent("events.corrupt-1762510000.json"))
        let another = scratch.appendingPathComponent("another-file.txt")
        try Data("another file's bytes".utf8).write(to: another)
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("events.corrupt-1762500000.json"),
                                                   withDestinationURL: another)
        XCTAssertEqual(SetAsideLog.all(in: scratch).map(\.id), ["events.corrupt-1762520000.json"])
    }

    /// A link is not read as a set-aside log either: one unreadable part, not the records of the file it points to.
    func testALinkIsNotReadAsASetAsideLog() throws {
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(1), event(2)]).write(to: another)
        let link = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: another)
        XCTAssertEqual(SetAsideLog.read(SetAsideLog(url: link)), SetAsideLog.Reading(records: [], unreadable: 1))
    }

    /// Share reads no link: a link named like a set-aside log shares nothing, where it sent the bytes of the file the link
    /// points to under the log's name.
    func testShareTakesNoLinkForTheLog() throws {
        let fm = FileManager.default
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(1)]).write(to: another)
        let link = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: another)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertNil(try SetAsideLogShare.folder(of: SetAsideLog(url: link), mediaDirectory: media, in: out))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: out.path), [], "nothing is written for it")
        XCTAssertNil(try SetAsideLogShare.zip(of: SetAsideLog(url: link), mediaDirectory: media, temporaryDirectory: out))
    }

    /// Share takes no photo or clip through a `Media` that is a link to another folder: the file and its README alone.
    func testShareTakesNothingThroughALinkedMediaFolder() throws {
        let fm = FileManager.default
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: elsewhere.appendingPathComponent(named))
        let media = scratch.appendingPathComponent("Media")
        try fm.createSymbolicLink(at: media, withDestinationURL: elsewhere)
        let log = try setAsideLog([recorded(named, minute: 1)])
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let shared = try XCTUnwrap(SetAsideLogShare.folder(of: log, mediaDirectory: media, in: out))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: shared.path).sorted(), ["README.txt", log.id], "no Media in it")
    }

    /// Share copies a photo or clip only when it is a plain file: not a folder under a photo's name, which went with
    /// everything in it, and not a link.
    func testShareCopiesNoFolderOrLinkUnderAPhotosName() throws {
        let fm = FileManager.default
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let plain = "\(UUID().uuidString).jpg", aFolder = "\(UUID().uuidString).jpg", aLink = "\(UUID().uuidString).mov"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(plain))
        try folder(media.appendingPathComponent(aFolder))
        let another = scratch.appendingPathComponent("another-file.txt")
        try Data("another file's bytes".utf8).write(to: another)
        try fm.createSymbolicLink(at: media.appendingPathComponent(aLink), withDestinationURL: another)
        var both = recorded(aFolder, minute: 2)
        both.secondaryMediaFilename = aLink
        let log = try setAsideLog([recorded(plain, minute: 1), both])
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let shared = try XCTUnwrap(SetAsideLogShare.folder(of: log, mediaDirectory: media, in: out))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: shared.appendingPathComponent("Media").path), [plain])
    }

    /// Delete takes neither a folder nor a link for a set-aside log: both stay, where the folder went with everything in
    /// it and the link was removed after the file it points to was read for the names of photos to delete.
    func testDeleteTakesNoFolderOrLinkForTheLog() async throws {
        let fm = FileManager.default
        let store = EventStore()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folderLog = root.appendingPathComponent("events.corrupt-1762510000.json")
        let inside = try folder(folderLog)
        let another = scratch.appendingPathComponent("another-file.json")
        try JSONEncoder().encode([event(1)]).write(to: another)
        let linkLog = root.appendingPathComponent("events.corrupt-1762500000.json")
        try fm.createSymbolicLink(at: linkLog, withDestinationURL: another)

        let deletedFolder = await store.deleteSetAsideLog(SetAsideLog(url: folderLog))
        XCTAssertEqual(deletedFolder, .notDeleted)
        XCTAssertTrue(fm.fileExists(atPath: inside.path), "the folder stays, with what is in it")
        let deletedLink = await store.deleteSetAsideLog(SetAsideLog(url: linkLog))
        XCTAssertEqual(deletedLink, .notDeleted)
        XCTAssertTrue(isLink(linkLog), "the link stays")
        XCTAssertTrue(fm.fileExists(atPath: another.path), "and so does the file it points to")
    }

    /// The control: a plain file that cannot be read is still a set-aside log, and Delete removes it, alone. What it named
    /// is not known, so its photos and clips may still be on the phone, and the answer says so (item 227's DS-5).
    func testDeleteStillRemovesAPlainLogThatCannotBeRead() async throws {
        let fm = FileManager.default
        let store = EventStore()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try Data("sealed".utf8).write(to: log)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: log.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: log.path) }
        XCTAssertNil(try? Data(contentsOf: log), "the test's file cannot be read")
        XCTAssertEqual(SetAsideLog.all(in: root).map(\.id), [log.lastPathComponent], "and is listed")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft, "the log goes, and what it named is not known")
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path))
    }

    /// With `Media` a link to another folder, Delete removes the log alone: nothing in that folder goes, where the files
    /// the log's bytes name were removed through the link.
    func testDeleteRemovesNothingThroughALinkedMediaFolder() async throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: elsewhere.appendingPathComponent(named))
        let media = root.appendingPathComponent("Media")
        try fm.createSymbolicLink(at: media, withDestinationURL: elsewhere)   // before a store makes the folder
        let store = EventStore()
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(named, minute: 1)]).write(to: log)

        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deletedMediaLeft, "the log itself goes, and nothing is looked at through the link")
        XCTAssertEqual(store.setAsideDeletionsToTell, [.deletedMediaLeft])
        XCTAssertFalse(fm.fileExists(atPath: log.path))
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.appendingPathComponent(named).path), "nothing goes through the link")
        XCTAssertTrue(isLink(media), "the test's link is still one")
    }

    /// Delete removes a photo or clip only when it is a plain file: a folder under a photo's name stays, with what is in
    /// it, while the plain file only the log names still goes.
    func testDeleteRemovesNoFolderUnderAPhotosName() async throws {
        let fm = FileManager.default
        let store = EventStore()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = store.mediaDirectory
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let plain = "\(UUID().uuidString).jpg", aFolder = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(plain))
        let inside = try folder(media.appendingPathComponent(aFolder))
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(plain, minute: 1), recorded(aFolder, minute: 2)]).write(to: log)

        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted, "a folder under a photo's name is no photo of the log's")
        XCTAssertFalse(fm.fileExists(atPath: media.appendingPathComponent(plain).path), "the photo only it named goes")
        XCTAssertTrue(fm.fileExists(atPath: inside.path), "a folder under a photo's name stays, with what is in it")
    }

    // The same shape in two older paths (Claude's inventory for the fix): the launch's sweep and the removal behind the
    // limits removed a name under `Media` without looking at what was there.

    /// The launch's sweep removes nothing through a `Media` that is a link to another folder. A guard, green before the
    /// fix too where Foundation's own listing of a folder by URL lists nothing through a link (the Mac's, probed
    /// 2026-11-09); the fix makes that the store's own rule, whatever a system's listing does.
    func testTheSweepRemovesNothingThroughALinkedMediaFolder() throws {
        let fm = FileManager.default
        try JSONEncoder().encode([event(1)]).write(to: try logURL())   // a log that reads, so the launch sweeps
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let old = try oldFile(in: elsewhere)
        let media = root.appendingPathComponent("Media")
        try fm.createSymbolicLink(at: media, withDestinationURL: elsewhere)   // before a store makes the folder
        let store = EventStore()
        store.drainIOForTesting()
        XCTAssertTrue(fm.fileExists(atPath: old.path), "nothing goes through the link")
        XCTAssertTrue(isLink(media), "the test's link is still one")
    }

    /// The sweep takes an old file nothing names, as before, and no folder under a photo's name, which went with
    /// everything in it.
    func testTheSweepRemovesNoFolderUnderAPhotosName() throws {
        let fm = FileManager.default
        try JSONEncoder().encode([event(1)]).write(to: try logURL())   // a log that reads, so the launch sweeps
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let plain = try oldFile(in: media)
        let aFolder = media.appendingPathComponent("\(UUID().uuidString).jpg")
        let inside = try folder(aFolder)
        try age(aFolder)   // after its file went in, which gave the folder a new date
        let store = EventStore()
        store.drainIOForTesting()
        XCTAssertFalse(fm.fileExists(atPath: plain.path), "the sweep still takes an old file nothing names")
        XCTAssertTrue(fm.fileExists(atPath: inside.path), "a folder under a photo's name stays, with what is in it")
    }

    /// The removal behind the limits removes nothing through a `Media` that is a link to another folder.
    func testTheLimitRemovesNothingThroughALinkedMediaFolder() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: elsewhere.appendingPathComponent(named))
        let media = root.appendingPathComponent("Media")
        try fm.createSymbolicLink(at: media, withDestinationURL: elsewhere)   // before a store makes the folder
        let (store, oldest) = try storeWhoseOldestRowNames(named)
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == oldest }, "the limit removed the row")
        XCTAssertTrue(fm.fileExists(atPath: elsewhere.appendingPathComponent(named).path), "nothing goes through the link")
        XCTAssertTrue(isLink(media), "the test's link is still one")
    }

    /// The removal behind the limits takes a removed row's plain file, as before, and no folder under a photo's name,
    /// which went with everything in it.
    func testTheLimitRemovesNoFolderUnderAPhotosName() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let plain = "\(UUID().uuidString).mov", aFolder = "\(UUID().uuidString).jpg"
        try Data([0x00, 0x01]).write(to: media.appendingPathComponent(plain))
        let inside = try folder(media.appendingPathComponent(aFolder))
        let (store, oldest) = try storeWhoseOldestRowNames(aFolder, plain)
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == oldest }, "the limit removed the row")
        XCTAssertFalse(fm.fileExists(atPath: media.appendingPathComponent(plain).path), "its plain file still goes")
        XCTAssertTrue(fm.fileExists(atPath: inside.path), "a folder under a photo's name stays, with what is in it")
    }

    /// The search for the photos a set-aside log may name reads plain files only. It still opened every entry named
    /// like a set-aside log, whole and through a link (a no-notes look at 1.12's change by a subagent, 2026-11-10; the
    /// shape of item 218's Codex-1 on a path its inventory had called safe). A link under such a name is not read:
    /// like an entry that cannot be read, it keeps every name. Read through, it kept only the names its target had,
    /// and the file queue read whatever the link led to. Written before the fix, red at that commit.
    func testTheSearchForNamedPhotosReadsNothingThroughALink() throws {
        let fm = FileManager.default
        let root = try logURL().deletingLastPathComponent()
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg", other = "\(UUID().uuidString).jpg"
        let target = elsewhere.appendingPathComponent("a-log.json")
        try Data("[{\"mediaFilename\":\"\(named)\"}]".utf8).write(to: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("events.corrupt-1762520000.json"), withDestinationURL: target)
        XCTAssertEqual(EventStore.mediaNamesSetAsideLogsMayReference([named, other], in: root), [named, other],
                       "a link is not read: every name is kept")
    }

    /// The same through the store: while a link is named like a set-aside log, the limit removes its oldest row and
    /// keeps the row's photo, as it does while a set-aside log cannot be read. Read through the link, whose target
    /// names nothing, the photo went. Written before the fix, red at that commit.
    func testTheLimitKeepsAPhotoWhileALinkIsNamedLikeASetAsideLog() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let elsewhere = scratch.appendingPathComponent("Elsewhere", isDirectory: true)
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("a-log.json")
        try Data("[]".utf8).write(to: target)
        try fm.createSymbolicLink(at: root.appendingPathComponent("events.corrupt-1762520000.json"), withDestinationURL: target)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(named))
        let (store, oldest) = try storeWhoseOldestRowNames(named)
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == oldest }, "the limit removed the row")
        XCTAssertTrue(fm.fileExists(atPath: media.appendingPathComponent(named).path), "its photo is kept: the link is not read")
        XCTAssertEqual(try Data(contentsOf: target), Data("[]".utf8), "and what the link leads to is as it was")
    }

    // MARK: - A set-aside record's screen takes no photo through a linked media folder (item 226's Codex-5)
    //
    // Codex's look at 1.12's three rounds of fixes: ADR 0078's decision 5 has "the screen's reading" among what takes
    // "nothing through a media folder that is a link", and the screen of a set-aside record showed its photo and clip
    // through one: the file was asked whether it is a plain file, the folder was not asked whether it is a folder. Share
    // and Delete of a set-aside log asked already. The owner, 2026-11-10: "yes, it is" (Claude's choice (a): the
    // set-aside record's screen; a live event's screen, its Share and its upload are as they were). Written before the
    // fix, red at that commit, each beside a real folder as its control.

    /// What the event's screen shows of a set-aside record, for both cameras: nothing through a `Media` that is a link
    /// to another folder, where the files the record names are.
    func testTheScreenOfASetAsideRecordTakesNoFileThroughALinkedMediaFolder() throws {
        let fixture = try recordWithItsFiles(underALinkedMediaFolder: true)
        let store = EventStore()
        let shown = EventDetailView.shownMedia(of: fixture.record, in: store, setAside: true)
        XCTAssertNil(shown.primary, "the photo is not taken through the link")
        XCTAssertNil(shown.secondary, "nor the second camera's clip")
        XCTAssertNil(store.setAsideMediaURL(for: fixture.record))
        XCTAssertNil(store.setAsideSecondaryMediaURL(for: fixture.record))
        XCTAssertTrue(isLink(fixture.media), "the test's link is still one")
    }

    /// The control: through a real `Media` the screen of a set-aside record shows both files, and a name with nothing
    /// under it yet keeps its URL, as a live event's does.
    func testTheScreenOfASetAsideRecordShowsItsFilesInARealMediaFolder() throws {
        let fixture = try recordWithItsFiles(underALinkedMediaFolder: false)
        let store = EventStore()
        var shown = EventDetailView.shownMedia(of: fixture.record, in: store, setAside: true)
        XCTAssertEqual(shown.primary?.lastPathComponent, fixture.record.mediaFilename)
        XCTAssertEqual(shown.secondary?.lastPathComponent, fixture.record.secondaryMediaFilename)
        try FileManager.default.removeItem(at: try XCTUnwrap(shown.primary))
        shown = EventDetailView.shownMedia(of: fixture.record, in: store, setAside: true)
        XCTAssertEqual(shown.primary?.lastPathComponent, fixture.record.mediaFilename, "a name with no file yet keeps its URL")
        XCTAssertFalse(isLink(fixture.media), "the control's folder is a real one")
    }

    /// The screen itself, laid out: under a linked `Media` it shows the record's thumbnail with the words for a photo
    /// that is not on the phone, as it does where the file is missing.
    func testTheLaidOutScreenOfASetAsideRecordShowsOnlyItsThumbnailUnderALinkedMediaFolder() throws {
        let fixture = try recordWithItsFiles(underALinkedMediaFolder: true, secondCamera: false)
        let rig = makeScreenRig()
        let shown = try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: fixture.record, setAside: true) }, rig)).shown
        XCTAssertTrue(shown.contains(EvidenceMediaView.thumbnailOnly), "the thumbnail, with its words: \(shown)")
        XCTAssertTrue(shown.contains("Local only"), "the screen is laid out: \(shown)")
        XCTAssertTrue(isLink(fixture.media), "the test's link is still one")
    }

    /// The control: under a real `Media` with the photo in it, the laid-out screen does not say the photo is missing.
    func testTheLaidOutScreenOfASetAsideRecordShowsItsPhotoInARealMediaFolder() throws {
        let fixture = try recordWithItsFiles(underALinkedMediaFolder: false, secondCamera: false)
        let rig = makeScreenRig()
        let shown = try shownOnScreen(screenOf(NavigationStack { EventDetailView(event: fixture.record, setAside: true) }, rig)).shown
        XCTAssertFalse(shown.contains(EvidenceMediaView.thumbnailOnly), "the photo is on the phone: \(shown)")
        XCTAssertTrue(shown.contains("Local only"), "the screen is laid out: \(shown)")
    }

    // MARK: - A name written with a JSON escape (item 230; the owner, 2026-11-11: "fit that too")

    /// A guard, green before the fix and after: a name is found in a log's bytes as written, another name is not, and a
    /// log with no `\u` escape, as the app writes one, is searched in that one form only.
    func testANameIsFoundInALogsBytesAsWritten() throws {
        let name = "\(UUID().uuidString).jpg", other = "\(UUID().uuidString).jpg"
        let bytes = try JSONEncoder().encode([recorded(name, minute: 1)])
        let forms = SetAsideLog.searchForms(of: bytes)
        XCTAssertEqual(forms, [bytes], "no escape: the file as written, once")
        XCTAssertTrue(SetAsideLog.names(name, in: forms))
        XCTAssertFalse(SetAsideLog.names(other, in: forms))
    }

    /// A set-aside log is searched for a photo's name, not decoded, while its screen decodes its records. A name written
    /// with a JSON escape for one of its letters, as only an edited backup writes it, was on the screen and not in the
    /// search.
    func testANameWrittenWithAnEscapeIsFound() throws {
        let name = "\(UUID().uuidString).jpg"
        let bytes = try withAnEscape(for: name, in: JSONEncoder().encode([recorded(name, minute: 1)]))
        XCTAssertNil(bytes.range(of: Data(name.utf8)), "the test's log does not have the name as written")
        XCTAssertEqual(try JSONDecoder().decode([Event].self, from: bytes).map(\.mediaFilename), [name], "and it decodes to it")
        XCTAssertTrue(SetAsideLog.names(name, in: SetAsideLog.searchForms(of: bytes)))
        let upper = Data(try XCTUnwrap(String(data: bytes, encoding: .utf8)).replacingOccurrences(of: "\\u002d", with: "\\u002D").utf8)
        XCTAssertNotEqual(upper, bytes, "the same escape with an upper-case digit")
        XCTAssertTrue(SetAsideLog.names(name, in: SetAsideLog.searchForms(of: upper)))
    }

    /// A guard, green before the fix and after: an escaped backslash before a "u" is a backslash and a "u", not the
    /// start of an escape, so the text after it is not the name. The name here begins with a letter, whose escape does
    /// not end in the letter itself, and the escape stands where the name begins, so that reading it as one would
    /// give the whole name.
    func testAnEscapedBackslashBeforeAUIsNotAnEscape() throws {
        let name = "A3F2A9C1-0B7D-4E5F-8A6B-1C2D3E4F5A6B.jpg"
        let bytes = Data(("[{\"mediaFilename\":\"\\\\u0041" + name.dropFirst() + "\"}]").utf8)
        XCTAssertNil(bytes.range(of: Data(name.utf8)), "the test's log does not have the name as written")
        let decoded = try JSONDecoder().decode([[String: String]].self, from: bytes)
        XCTAssertEqual(decoded.first?["mediaFilename"], "\\u0041" + name.dropFirst(), "it decodes to a backslash, a u and the rest")
        XCTAssertFalse(SetAsideLog.names(name, in: SetAsideLog.searchForms(of: bytes)))
    }

    /// A guard, green before the fix and after: an escape of a character no file name has is left as written. The
    /// escapes are put together here from a backslash and the rest, and the bytes are checked for one: written out in
    /// this file they reached it as the characters themselves, and the test could not fail (chain m's first run).
    func testAnEscapeOfAnotherCharacterIsLeftAsWritten() {
        let backslash = "\\"
        let bytes = Data(("[{\"note\":\"caf" + backslash + "u00e9 " + backslash + "u2028\"}]").utf8)
        XCTAssertNotNil(bytes.range(of: Data((backslash + "u").utf8)), "the test's bytes have an escape")
        XCTAssertEqual(SetAsideLog.searchForms(of: bytes).last, bytes)
    }

    /// Another set-aside log names the photo with an escape: its record shows the photo, so Delete of this log leaves
    /// it. The search of the other log's bytes missed the name, and the photo went.
    func testDeleteKeepsAPhotoAnotherSetAsideLogNamesWithAnEscape() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let name = photo.lastPathComponent
        let other = try XCTUnwrap(EventStore.rootOverrideForTesting).appendingPathComponent("events.corrupt-1762500000.json")
        try withAnEscape(for: name, in: JSONEncoder().encode([recorded(name, minute: 5)])).write(to: other)
        XCTAssertNil(try Data(contentsOf: other).range(of: Data(name.utf8)), "the other log does not have the name as written")
        XCTAssertEqual(SetAsideLog.read(SetAsideLog(url: other)).records.map(\.mediaFilename), [name], "and its screen reads it")
        store.refreshSetAsideLogs()
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo the other log names stays")
        XCTAssertTrue(fm.fileExists(atPath: other.path), "and so does the other log")
    }

    /// The log itself names its photo with an escape, and nothing else names it: its record shows the photo, and the
    /// photo goes with the log. It stayed, with the delete counted as a whole one.
    func testDeleteRemovesAPhotoItsLogNamesWithAnEscape() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let name = photo.lastPathComponent
        try withAnEscape(for: name, in: Data(contentsOf: log)).write(to: log)
        XCTAssertNil(try Data(contentsOf: log).range(of: Data(name.utf8)), "the log does not have the name as written")
        XCTAssertEqual(SetAsideLog.read(SetAsideLog(url: log)).records.map(\.mediaFilename), [name], "and its screen reads it")
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertFalse(fm.fileExists(atPath: photo.path), "and the photo only it names")
    }

    /// The limit's removal of a row's photo asks the same search (item 120's V1, live since 1.8): a photo a set-aside
    /// log names with an escape is kept.
    func testTheLimitKeepsAPhotoASetAsideLogNamesWithAnEscape() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(named))
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try withAnEscape(for: named, in: JSONEncoder().encode([recorded(named, minute: 1)])).write(to: log)
        XCTAssertNil(try Data(contentsOf: log).range(of: Data(named.utf8)), "the set-aside log does not have the name as written")
        let (store, oldest) = try storeWhoseOldestRowNames(named)
        store.add(Event(startDate: Date(), endDate: Date(), triggeredSensors: [.touch], cloudSyncState: .pending))
        store.drainIOForTesting()
        XCTAssertFalse(store.events.contains { $0.id == oldest }, "the limit removed the row")
        XCTAssertTrue(fm.fileExists(atPath: media.appendingPathComponent(named).path), "its photo is kept: a set-aside log names it")
    }

    /// Share's folder has the photo its log names with an escape, as the log's screen shows it.
    func testShareCarriesAPhotoItsLogNamesWithAnEscape() throws {
        let fm = FileManager.default
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let named = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(named))
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try withAnEscape(for: named, in: JSONEncoder().encode([recorded(named, minute: 1)])).write(to: file)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: media, in: out))
        XCTAssertTrue(fm.fileExists(atPath: folder.appendingPathComponent("Media").appendingPathComponent(named).path),
                      "the photo its record names is in the folder")
    }

    // MARK: - A set-aside log names a file only by a name the store gives (item 231, Codex-10; the owner, 2026-11-11: "a, wording approved")
    //
    // Codex's look at round seven: the search of a set-aside log reads a character as written or as its unicode escape,
    // and Delete, Share and the set-aside record's screen took names the store never gives: any name with a UUID before
    // its last dot, or any plain file name. For such a name two spellings do not protect the same photo: a quote
    // written with its unicode escape in one set-aside log and with its short escape in another; an accented letter as
    // one character and as two. Both screens showed the photo, and Delete of one log took it. The store has only ever
    // given a photo or clip a UUID in capitals and ".jpg" or ".mov", and for such a name the search reads every
    // spelling JSON has. So that is the one rule for what a set-aside log names (`EventStore.isStoredMediaName`): its
    // screen shows, its Share carries and its Delete removes no file under another name. Written before the fix, red at
    // that commit; the escapes are put together from a backslash and the rest, as item 230's are.

    /// The form: a UUID as `UUID().uuidString` writes it, and ".jpg" or ".mov", byte for byte, and no other name.
    func testOnlyANameTheStoreGivesIsOne() throws {
        let uuid = "A3F2A9C1-0B7D-4E5F-8A6B-1C2D3E4F5A6B"
        XCTAssertTrue(EventStore.isStoredMediaName(uuid + ".jpg"))
        XCTAssertTrue(EventStore.isStoredMediaName(uuid + ".mov"))
        XCTAssertTrue(EventStore.isStoredMediaName(UUID().uuidString + ".jpg"), "as the store writes a photo's")
        XCTAssertTrue(EventStore.isStoredMediaName(UUID().uuidString + ".mov"), "as the store writes a clip's")
        let tab = String(Unicode.Scalar(UInt8(9))), lineEnd = String(Unicode.Scalar(UInt8(10)))
        let accented = String(Unicode.Scalar(UInt8(0xE9)))
        let inTwo = "e" + String(try XCTUnwrap(Unicode.Scalar(UInt32(0x301))))
        let others: [(name: String, what: String)] = [
            (uuid.lowercased() + ".jpg", "a UUID in lower case"),
            (uuid + ".JPG", "an extension in capitals"),
            (uuid + ".MOV", "an extension in capitals"),
            (uuid + ".jpeg", "another extension"),
            (uuid + ".png", "another extension of three letters"),
            (uuid + ".jp", "a short extension"),
            (uuid, "no extension"),
            (uuid + ".", "a dot and no extension"),
            (uuid + ".jpg.jpg", "two extensions"),
            (uuid + ".j\"pg", "a quote"),
            (uuid + ".j" + tab + "pg", "a tab"),
            (uuid + ".j\\pg", "a backslash"),
            (uuid + ".jp" + accented, "an accented letter"),
            (uuid + ".jp" + inTwo, "an accented letter in two characters"),
            (String(uuid.dropLast()) + ".jpg", "a short UUID"),
            (uuid + "0.jpg", "a long UUID"),
            (uuid.replacingOccurrences(of: "-", with: "") + ".jpg", "no hyphens"),
            ("A3F2A9C10-B7D-4E5F-8A6B-1C2D3E4F5A6B.jpg", "a hyphen out of place"),
            ("G3F2A9C1-0B7D-4E5F-8A6B-1C2D3E4F5A6B.jpg", "a letter no UUID has"),
            (uuid + ".jpg ", "a space after it"),
            (" " + uuid + ".jpg", "a space before it"),
            (uuid + ".jpg" + lineEnd, "a line end after it"),
            ("x/" + uuid + ".jpg", "a path"),
            ("", "nothing"),
            (".jpg", "an extension alone"),
            ("photo.jpg", "another name"),
        ]
        for other in others {
            XCTAssertFalse(EventStore.isStoredMediaName(other.name), "\(other.what): \(other.name.debugDescription)")
        }
    }

    /// A guard, green before the fix and after, and what the rule rests on: a name the store gives is found in a
    /// set-aside log however JSON writes it. Each of its characters is written as itself or as its unicode escape, with
    /// the escape's digits in either case: each character alone, then all of them, then three hundred mixes. Each time
    /// the app's own decoder reads the name back, and the search finds it.
    func testANameTheStoreGivesIsFoundHoweverJSONWritesIt() throws {
        let backslash = "\\"
        func escaped(_ scalar: Unicode.Scalar, capitals: Bool) -> String {
            let digits = String(scalar.value, radix: 16, uppercase: capitals)
            return backslash + "u" + String(repeating: "0", count: 4 - digits.count) + digits
        }
        func check(_ name: String, _ written: String, _ what: String) throws {
            let bytes = Data(("[{\"mediaFilename\":\"" + written + "\"}]").utf8)
            let read = try StoredJSON.decode([[String: String]].self, from: bytes)
            XCTAssertEqual(read.first?["mediaFilename"], name, "the decoder reads the name: \(what)")
            XCTAssertTrue(SetAsideLog.names(name, in: SetAsideLog.searchForms(of: bytes)), "the search finds it: \(what)")
        }
        for name in ["A3F2A9C1-0B7D-4E5F-8A6B-1C2D3E4F5A6B.jpg", "0E9D8C7B-6A5F-4E3D-2C1B-0A9F8E7D6C5B.mov"] {
            XCTAssertTrue(EventStore.isStoredMediaName(name))
            let scalars = Array(name.unicodeScalars)
            for capitals in [false, true] {
                for index in scalars.indices {
                    let written = scalars.enumerated().map { $0 == index ? escaped($1, capitals: capitals) : String($1) }.joined()
                    try check(name, written, "character \(index) as an escape")
                }
                try check(name, scalars.map { escaped($0, capitals: capitals) }.joined(), "every character as an escape")
            }
            var state: UInt64 = 0x2026_1111
            for round in 0..<300 {
                let written = scalars.map { scalar -> String in
                    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                    switch (state >> 33) % 3 {
                    case 0: return escaped(scalar, capitals: false)
                    case 1: return escaped(scalar, capitals: true)
                    default: return String(scalar)
                    }
                }.joined()
                try check(name, written, "mix \(round)")
            }
        }
    }

    /// A guard, green before the fix and after: a record written in another encoding is not read. Foundation's decoder
    /// takes UTF-16 and UTF-32; the app's own (`StoredJSON.decode`) refuses them, and a set-aside log's reader goes by
    /// UTF-8 bytes. So no screen shows a name that the search, which looks for UTF-8 bytes, cannot find. Twice: the
    /// record as the encoder writes it, which the decoder's check for control characters refuses in those encodings,
    /// and the same record with an escape in every string, which goes to its check of escapes.
    func testARecordInAnotherEncodingIsNotRead() throws {
        let name = "A3F2A9C1-0B7D-4E5F-8A6B-1C2D3E4F5A6B.jpg"
        let plain = try XCTUnwrap(String(data: JSONEncoder().encode([recorded(name, minute: 1)]), encoding: .utf8))
        XCTAssertFalse(plain.contains("\\"), "the test's record has no escape of its own")
        XCTAssertFalse(plain.contains("\"\""), "nor an empty string, which could take none")
        let escaped = withAnEscapeInEveryString(plain)
        XCTAssertNotEqual(escaped, plain)
        let encodings: [String.Encoding] = [.utf16LittleEndian, .utf16BigEndian, .utf16, .utf32LittleEndian, .utf32BigEndian]
        for (text, what) in [(plain, "as the encoder writes it"), (escaped, "with an escape in every string")] {
            XCTAssertEqual(SetAsideLog.reading(Data(text.utf8)).records.map(\.mediaFilename), [name], "in UTF-8 the record is read, \(what)")
            for encoding in encodings {
                let bytes = try XCTUnwrap(text.data(using: encoding))
                XCTAssertNil(bytes.range(of: Data(name.utf8)), "the test's bytes do not have the name in UTF-8: \(encoding), \(what)")
                XCTAssertEqual(SetAsideLog.reading(bytes).records.count, 0, "no record is read: \(encoding), \(what)")
                XCTAssertThrowsError(try StoredJSON.decode([Event].self, from: bytes), "the log's own decoder refuses it: \(encoding), \(what)")
            }
            // One record in UTF-16 inside a list in UTF-8, as the reader would cut it out of one.
            let record = try XCTUnwrap(String(text.dropFirst().dropLast()).data(using: .utf16LittleEndian))
            var mixed = Data("[".utf8)
            mixed.append(record)
            mixed.append(Data("]".utf8))
            XCTAssertEqual(SetAsideLog.reading(mixed).records.count, 0, "nor a record in UTF-16 inside a list in UTF-8, \(what)")
            XCTAssertThrowsError(try StoredJSON.decode(Event.self, from: record), "the record's own decoder refuses it, \(what)")
        }
    }

    /// Codex-10 as Codex ran it: a photo under a name with a quote in its extension. One set-aside log writes the quote
    /// with its unicode escape, another with its short escape. Neither names the photo, by the rule, so Delete of the
    /// first leaves it. The first log's spelling was found, the other's was not, and the photo went.
    func testDeleteLeavesAPhotoTwoLogsWriteDifferentlyUnderANameTheStoreNeverGives() async throws {
        let backslash = "\\", quote = "\""
        try await assertDeleteLeavesAPhoto(
            withExtension: "j" + quote + "pg",
            deletedLogWrites: { $0.replacingOccurrences(of: quote, with: backslash + "u0022") },
            otherLogWrites: { $0.replacingOccurrences(of: quote, with: backslash + quote) })
    }

    /// The same for the other characters Codex and Claude probed: a tab and a backslash, each with its unicode escape
    /// in the deleted log and its short escape in the other; and an accented letter, as written in the deleted log and
    /// with a unicode escape for each character that is not a plain one in the other.
    func testDeleteLeavesAPhotoWhateverEscapeTheOtherLogWritesItsNameWith() async throws {
        let backslash = "\\"
        let tab = String(Unicode.Scalar(UInt8(9)))
        try await assertDeleteLeavesAPhoto(
            withExtension: "j" + tab + "pg",
            deletedLogWrites: { $0.replacingOccurrences(of: tab, with: backslash + "u0009") },
            otherLogWrites: { $0.replacingOccurrences(of: tab, with: backslash + "t") })
        try await assertDeleteLeavesAPhoto(
            withExtension: "j" + backslash + "pg",
            deletedLogWrites: { $0.replacingOccurrences(of: backslash, with: backslash + "u005c") },
            otherLogWrites: { $0.replacingOccurrences(of: backslash, with: backslash + backslash) })
        try await assertDeleteLeavesAPhoto(
            withExtension: "jp" + String(Unicode.Scalar(UInt8(0xE9))),
            deletedLogWrites: { $0 },
            otherLogWrites: { written in
                written.unicodeScalars.map { scalar in
                    let digits = String(scalar.value, radix: 16)
                    return scalar.isASCII ? String(scalar) : backslash + "u" + String(repeating: "0", count: 4 - digits.count) + digits
                }.joined()
            })
    }

    /// A spelling no reader of escapes would close: an accented letter as one character in one set-aside log and as two
    /// in the other, both as written. The bytes differ, the decoded names are equal, and the file system opens the one
    /// file by either. The deleted log writes the name as the media folder lists it; the other writes its other form.
    func testDeleteLeavesAPhotoWhoseNameTwoLogsWriteInDifferentForms() async throws {
        try await assertDeleteLeavesAPhoto(
            withExtension: "jp" + String(Unicode.Scalar(UInt8(0xE9))),
            deletedLogWrites: { $0 },
            otherLogWrites: { written in
                let composed = written.precomposedStringWithCanonicalMapping
                return Array(composed.utf8) == Array(written.utf8) ? written.decomposedStringWithCanonicalMapping : composed
            })
    }

    /// A file under a name the store never gives, which only the deleted log names, as written: in lower case, with
    /// another extension, with the extension in capitals, with none. It is not the log's, by the rule, and stays; the
    /// photo the log names by a name the store gives goes with it. Each went: any name with a UUID before its last
    /// dot was taken for one of the store's.
    func testDeleteRemovesNoFileUnderANameTheStoreNeverGives() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let media = store.mediaDirectory
        let others = [lowerCaseUUID() + ".jpg", UUID().uuidString + ".jpeg", UUID().uuidString + ".JPG", UUID().uuidString]
        for name in others { try Data([0xFF, 0xD8, 0x02]).write(to: media.appendingPathComponent(name)) }
        let records = [recorded(photo.lastPathComponent, minute: 1)] + others.enumerated().map { recorded($0.element, minute: $0.offset + 2) }
        try JSONEncoder().encode(records).write(to: log)
        let bytes = try Data(contentsOf: log)
        for name in others { XCTAssertNotNil(bytes.range(of: Data(name.utf8)), "the log has the name as written: \(name)") }
        store.refreshSetAsideLogs()
        let deleted = await store.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(deleted, .deleted)
        XCTAssertEqual(store.setAsideDeletionsToTell, [])
        XCTAssertFalse(fm.fileExists(atPath: log.path), "the log goes")
        XCTAssertFalse(fm.fileExists(atPath: photo.path), "and the photo it names by a name the store gives")
        for name in others {
            XCTAssertTrue(fm.fileExists(atPath: media.appendingPathComponent(name).path), "a file under another name stays: \(name)")
        }
    }

    /// The set-aside record's screen shows no file under a name the store never gives, for either camera, though each
    /// file is in a real media folder. A live event's screen reads as it did (the owner's ruling of 2026-11-10 for a
    /// live event's screen, its Share and its upload stands).
    func testTheScreenOfASetAsideRecordShowsNoFileUnderANameTheStoreNeverGives() throws {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = root.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var record = event(1)
        record.mediaFilename = UUID().uuidString + ".j\"pg"
        record.secondaryMediaFilename = lowerCaseUUID() + ".mov"
        for name in [record.mediaFilename, record.secondaryMediaFilename].compactMap({ $0 }) {
            try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(name))
        }
        let store = EventStore()
        let shown = EventDetailView.shownMedia(of: record, in: store, setAside: true)
        XCTAssertNil(shown.primary, "no photo under a name with a quote in it")
        XCTAssertNil(shown.secondary, "no clip under a name in lower case")
        XCTAssertNil(store.setAsideMediaURL(for: record))
        XCTAssertNil(store.setAsideSecondaryMediaURL(for: record))
        let live = EventDetailView.shownMedia(of: record, in: store, setAside: false)
        XCTAssertEqual(live.primary?.lastPathComponent, record.mediaFilename, "a live event's screen reads as it did")
        XCTAssertEqual(live.secondary?.lastPathComponent, record.secondaryMediaFilename, "for the second camera too")
        XCTAssertFalse(isLink(media), "the media folder is a real one")
    }

    /// Share's folder has no file under a name the store never gives, though the log's bytes have each name as written;
    /// the photo the log names by a name the store gives is there.
    func testShareCarriesNoFileUnderANameTheStoreNeverGives() throws {
        let fm = FileManager.default
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let named = UUID().uuidString + ".jpg"
        let others = [lowerCaseUUID() + ".jpg", UUID().uuidString + ".jpeg", UUID().uuidString]
        for name in [named] + others { try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(name)) }
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode(([named] + others).enumerated().map { recorded($0.element, minute: $0.offset + 1) }).write(to: file)
        let bytes = try Data(contentsOf: file)
        for name in others { XCTAssertNotNil(bytes.range(of: Data(name.utf8)), "the log has the name as written: \(name)") }
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: media, in: out))
        let carried = try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("Media").path)
        XCTAssertEqual(carried, [named], "the photo under the store's name, and no other")
    }

    // MARK: - Delete asks for the Malinois PIN (item 232, Codex 1 of the second full review; the owner, 2026-11-11: "as you recommend, wording approved")

    private static let deletePad = "Enter PIN to delete this log"
    private static let confirmation = "Delete this set-aside log?"
    /// What a test presses the confirmation's Delete by, and its Cancel.
    private static let confirmDelete = "Delete: Delete this set-aside log?"
    private static let cancelConfirmation = "Cancel: Delete this set-aside log?"

    /// The pad's title, in the owner's approved words.
    func testTheDeletePadsTitleIsTheOwnersApprovedOne() {
        XCTAssertEqual(SetAsideLogWords.deletePINTitle, Self.deletePad)
    }

    // Delete's steps, apart from any screen: each rule, whatever the screen is told and in whatever order.

    /// Delete opens the PIN pad and not the confirmation; the right PIN closes the pad, and the confirmation opens only
    /// once the pad has gone; and after a confirmation the owner cancels, Delete opens the pad again.
    func testDeletesStepsAskForThePINFirstEveryTime() {
        var steps = SetAsideLogDeleteSteps()
        steps.deletePressed()
        XCTAssertTrue(steps.askingPIN, "the pad")
        XCTAssertFalse(steps.confirming, "and no confirmation before the PIN")
        steps.pinWasEntered()
        XCTAssertFalse(steps.askingPIN, "the right PIN closes the pad")
        XCTAssertFalse(steps.confirming, "and the confirmation waits for the pad to go")
        steps.padHasGone()
        XCTAssertTrue(steps.confirming, "the confirmation, after the PIN")
        steps.confirming = false   // the dialog's Cancel
        steps.deletePressed()
        XCTAssertTrue(steps.askingPIN, "the pad again")
        XCTAssertFalse(steps.confirming)
    }

    /// No PIN, no confirmation: a pad the owner cancels opens none, and neither does a pad's going on its own.
    func testDeletesStepsOpenNoConfirmationWithoutThePIN() {
        var cancelled = SetAsideLogDeleteSteps()
        cancelled.deletePressed()
        cancelled.padWasCancelled()
        XCTAssertFalse(cancelled.askingPIN, "Cancel closes the pad")
        cancelled.padHasGone()
        XCTAssertFalse(cancelled.confirming, "a cancelled pad opens no confirmation")
        var none = SetAsideLogDeleteSteps()
        none.padHasGone()
        XCTAssertFalse(none.confirming, "a pad's going with no entry opens none")
    }

    /// One entry opens one confirmation: once the owner has cancelled it, the pad's going told once more opens no
    /// second one, and neither does a pad cancelled at the next Delete.
    func testDeletesStepsUseAnEntryOnce() {
        var steps = SetAsideLogDeleteSteps()
        steps.deletePressed()
        steps.pinWasEntered()
        steps.padHasGone()
        XCTAssertTrue(steps.confirming, "the fixture: the entry's own confirmation")
        steps.confirming = false   // the dialog's Cancel
        steps.padHasGone()   // the pad's going, told once more
        XCTAssertFalse(steps.confirming, "one entry opened a second confirmation")
        steps.deletePressed()
        steps.padWasCancelled()
        steps.padHasGone()
        XCTAssertFalse(steps.confirming, "the earlier entry opened a confirmation at the next Delete")
    }

    /// An entry that no pad's closing took up is dropped at the next Delete: were iOS not to say that the pad had gone,
    /// the entry would otherwise wait, and a pad cancelled later would open the confirmation.
    func testDeletesStepsDropAnEntryNoClosingTookUp() {
        var steps = SetAsideLogDeleteSteps()
        steps.deletePressed()
        steps.pinWasEntered()   // and the screen is never told that the pad has gone
        steps.deletePressed()
        steps.padWasCancelled()
        steps.padHasGone()
        XCTAssertFalse(steps.confirming, "an entry for an earlier Delete opened a confirmation")
    }

    /// The PIN entered on a pad that is no longer asked for (cancelled, and not yet off the screen) is not taken.
    func testDeletesStepsTakeNoEntryOnAPadNoLongerAskedFor() {
        var steps = SetAsideLogDeleteSteps()
        steps.deletePressed()
        steps.padWasCancelled()
        steps.pinWasEntered()
        steps.padHasGone()
        XCTAssertFalse(steps.confirming, "an entry after Cancel opened a confirmation")
        var never = SetAsideLogDeleteSteps()
        never.pinWasEntered()
        never.padHasGone()
        XCTAssertFalse(never.confirming, "an entry with no pad asked for opened a confirmation")
    }

    /// When Malinois goes to the background the pad closes, an entry not yet used is dropped, and a confirmation closes.
    func testDeletesStepsCloseWhenMalinoisLeavesTheScreen() {
        var pad = SetAsideLogDeleteSteps()
        pad.deletePressed()
        pad.malinoisLeftTheScreen()
        XCTAssertFalse(pad.askingPIN, "the pad closes")
        var entered = SetAsideLogDeleteSteps()
        entered.deletePressed()
        entered.pinWasEntered()
        entered.malinoisLeftTheScreen()
        entered.padHasGone()
        XCTAssertFalse(entered.confirming, "an entry made as Malinois left opened a confirmation")
        var confirming = SetAsideLogDeleteSteps()
        confirming.deletePressed()
        confirming.pinWasEntered()
        confirming.padHasGone()
        XCTAssertTrue(confirming.confirming, "the fixture: the confirmation is up")
        confirming.malinoisLeftTheScreen()
        XCTAssertFalse(confirming.confirming, "the confirmation closes")
    }

    /// Codex 1 of the second full review of 1.12: with the owner's Face ID or Touch ID unlock on, a face or finger opens
    /// the Event Log, and a set-aside log's Delete asked for a confirmation only, so a face or finger could delete the log
    /// and its photos and clips, where SECURITY.md says one opens read surfaces only. The log's screen laid out for real:
    /// Delete opens the PIN pad, not the confirmation, and deletes nothing. Written before the fix, red at that commit.
    func testDeleteOnTheScreenOpensThePINPadAndNotTheConfirmation() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        _ = await deleteOpensThePad(screen)
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "no confirmation before the PIN: \(screen.recorder.shown)")
        XCTAssertNil(screen.recorder.actions[Self.confirmDelete], "and nothing to confirm with")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")
    }

    /// A wrong PIN leaves the pad standing, opens no confirmation and deletes nothing. The entry is typed on the pad
    /// itself; the pad shows its ✓ only after an entry it refused (item 108).
    func testAWrongPINOnDeletesPadOpensNoConfirmation() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        XCTAssertNil(screen.recorder.actions["PIN key ✓"], "a pad that submits by itself, before any entry")
        try await typeOnThePad("0000", of: screen)
        let refused = await settles(within: 10) { screen.recorder.actions["PIN key ✓"] != nil }
        XCTAssertTrue(refused, "the pad checked the entry and refused it")
        try await Task.sleep(for: .seconds(1))   // a confirmation, were one to open, opens once the pad is gone
        XCTAssertTrue(screen.recorder.shown.contains(Self.deletePad), "the pad stands: \(screen.recorder.shown)")
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "no confirmation: \(screen.recorder.shown)")
        XCTAssertNil(screen.recorder.actions[Self.confirmDelete], "and nothing to confirm with")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")
    }

    /// The right PIN closes the pad and opens the confirmation, which deletes nothing by being open; its Delete removes
    /// the log and the photo only it names, as before.
    func testTheRightPINOpensTheConfirmationAndItsDeleteRemovesTheLog() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        try await typeOnThePad(Self.pin, of: screen)
        let confirming = await settles(within: 10) {
            screen.recorder.shown.contains(Self.confirmation) && screen.recorder.actions[Self.confirmDelete] != nil
        }
        XCTAssertTrue(confirming, "the confirmation is up after the PIN: \(screen.recorder.shown)")
        XCTAssertFalse(screen.recorder.shown.contains(Self.deletePad), "the pad is gone: \(screen.recorder.shown)")
        XCTAssertTrue(exists(log) && exists(photo), "the PIN alone deletes nothing")
        guard confirming else { return }
        screen.recorder.actions[Self.confirmDelete]?()
        let deleted = await settles(within: 10) { !self.exists(log) && !self.exists(photo) }
        XCTAssertTrue(deleted, "the confirmation's Delete removes the log and the photo only it names")
        let closed = await settles(within: 10) { !screen.recorder.shown.contains(Self.confirmation) }
        XCTAssertTrue(closed, "and the confirmation is gone: \(screen.recorder.shown)")
        let unlisted = await settles(within: 10) { store.setAsideLogs.isEmpty }
        XCTAssertTrue(unlisted, "the list no longer has it")
        let entered = await settles(within: 10) { self.deletionEntries(in: store).count == 1 }
        XCTAssertTrue(entered, "the screen's Delete leaves its status entry (item 234): \(store.events.map(\.sensorSummary))")
    }

    /// A pad the owner cancels opens no confirmation and deletes nothing, and Delete asks for the PIN again.
    func testACancelledPadOpensNoConfirmationAndDeleteAsksAgain() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        let cancel = try XCTUnwrap(screen.recorder.actions["Cancel: " + Self.deletePad], "the pad has no Cancel")
        cancel()
        let closed = await settles(within: 10) { self.padIsGone(screen) }
        XCTAssertTrue(closed, "the pad closed: \(screen.recorder.shown)")
        try await Task.sleep(for: .seconds(1))   // a confirmation, were one to open, opens once the pad is gone
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "no confirmation: \(screen.recorder.shown)")
        XCTAssertNil(screen.recorder.actions[Self.confirmDelete], "and nothing to confirm with")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")
        let again = await deleteOpensThePad(screen)
        XCTAssertTrue(again, "Delete asks for the PIN again")
    }

    /// One entry of the PIN opens one confirmation. After a confirmation the owner cancels, nothing is deleted and
    /// Delete asks for the PIN again; a pad cancelled then opens no confirmation: the earlier entry is not kept.
    func testAPINEnteredOnceIsNotKeptForTheNextDelete() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        try await typeOnThePad(Self.pin, of: screen)
        let confirming = await settles(within: 10) { screen.recorder.actions[Self.cancelConfirmation] != nil }
        XCTAssertTrue(confirming, "the confirmation is up after the PIN: \(screen.recorder.shown)")
        guard confirming else { return }
        screen.recorder.actions[Self.cancelConfirmation]?()
        let cancelled = await settles(within: 10) { !screen.recorder.shown.contains(Self.confirmation) }
        XCTAssertTrue(cancelled, "the confirmation closed: \(screen.recorder.shown)")
        XCTAssertTrue(exists(log) && exists(photo), "a cancelled confirmation deletes nothing")

        guard await deleteOpensThePad(screen) else { return }
        let cancel = try XCTUnwrap(screen.recorder.actions["Cancel: " + Self.deletePad], "the pad has no Cancel")
        cancel()
        let closed = await settles(within: 10) { self.padIsGone(screen) }
        XCTAssertTrue(closed, "the pad closed: \(screen.recorder.shown)")
        try await Task.sleep(for: .seconds(1))   // a confirmation, were one to open, opens once the pad is gone
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "the earlier entry opened a confirmation: \(screen.recorder.shown)")
        XCTAssertNil(screen.recorder.actions[Self.confirmDelete], "and nothing to confirm with")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")
    }

    /// Delete's pad takes the PIN only: with the owner's Face ID or Touch ID unlock on, it offers no face or finger. Read
    /// from what an offer does first on the real path (ADR 0056): with the unlock on and no enrolment on record, a pad
    /// that may offer one turns the unlock off and says why. The control, such a pad, does both; Delete's pad leaves the
    /// unlock as the owner set it and shows no such caption.
    func testDeletesPadOffersNoFaceOrFinger() async throws {
        try setThePIN()
        let settings = AppSettings()
        defer {
            settings.biometricUnlock = false
            BiometricBinding.canEvaluateForTesting = nil
            BiometricBinding.stateForTesting = nil
            KeychainService.wipeStalePINData()
        }
        BiometricBinding.canEvaluateForTesting = true
        BiometricBinding.stateForTesting = { Data("enrolled".utf8) }
        KeychainService.clearEnrolledBiometricState()
        let unbound = BiometricKind.current.bindingCaption(for: .unbound)
        settings.biometricUnlock = true
        let control = try shownOnScreen(PINEntryView(title: "Control", allowBiometrics: true, onSuccess: {}, onCancel: {})
            .environmentObject(settings)).shown
        XCTAssertTrue(control.contains(unbound), "the control: a pad that may offer a face or finger says why it does not: \(control)")
        XCTAssertFalse(settings.biometricUnlock, "the control: and turns the unlock off")

        settings.biometricUnlock = true
        let (store, log, _) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store, settings: settings)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        try await Task.sleep(for: .milliseconds(500))   // a pad makes its offer as it appears
        XCTAssertFalse(screen.recorder.shown.contains(unbound), "Delete's pad made an offer: \(screen.recorder.shown)")
        XCTAssertTrue(settings.biometricUnlock, "the unlock is as the owner set it: Delete's pad made no offer")
    }

    /// What a PIN opened does not outlive Malinois's time on screen (Home's rule for the Event Log itself): when Malinois
    /// goes to the background, Delete's pad closes, and so does a confirmation the PIN had opened, with nothing deleted;
    /// back on screen, Delete asks for the PIN again. Only the background does it: under Control Centre the pad stands.
    func testDeletesPadAndConfirmationCloseWhenMalinoisLeavesTheScreen() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        screen.phase.value = .inactive   // Control Centre, or a call's banner, over Malinois
        try await Task.sleep(for: .seconds(1))
        XCTAssertFalse(padIsGone(screen), "the pad stands while Malinois is only covered: \(screen.recorder.shown)")
        screen.phase.value = .background
        let padClosed = await settles(within: 10) { self.padIsGone(screen) }
        XCTAssertTrue(padClosed, "the pad closed with Malinois off screen: \(screen.recorder.shown)")
        guard padClosed else { return }

        screen.phase.value = .active
        guard await deleteOpensThePad(screen) else { return }
        try await typeOnThePad(Self.pin, of: screen)
        let confirming = await settles(within: 10) {
            screen.recorder.shown.contains(Self.confirmation) && screen.recorder.actions[Self.confirmDelete] != nil
        }
        XCTAssertTrue(confirming, "the confirmation is up after the PIN: \(screen.recorder.shown)")
        guard confirming else { return }
        screen.phase.value = .background
        let confirmationClosed = await settles(within: 10) {
            !screen.recorder.shown.contains(Self.confirmation) && screen.recorder.actions[Self.confirmDelete] == nil
        }
        XCTAssertTrue(confirmationClosed, "the confirmation closed with Malinois off screen: \(screen.recorder.shown)")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")

        screen.phase.value = .active
        let again = await deleteOpensThePad(screen)
        XCTAssertTrue(again, "back on screen, Delete asks for the PIN again")
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "and no confirmation stands: \(screen.recorder.shown)")
    }

    /// The PIN entered just as Malinois leaves the screen opens no confirmation: the pad takes a moment to go, and the
    /// confirmation waits for it, so the entry is dropped with the pad. The last digit, and the background at once.
    func testAPINEnteredAsMalinoisLeavesTheScreenOpensNoConfirmation() async throws {
        try setThePIN()
        defer { KeychainService.wipeStalePINData() }
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let screen = try deleteScreen(of: log, store: store)
        defer { screen.close() }
        guard await deleteOpensThePad(screen) else { return }
        try await typeOnThePad(String(Self.pin.dropLast()), of: screen)
        let last = try XCTUnwrap(screen.recorder.actions["PIN key \(Self.pin.suffix(1))"], "the pad has no key for the last digit")
        last()
        screen.phase.value = .background
        let closed = await settles(within: 10) { self.padIsGone(screen) }
        XCTAssertTrue(closed, "the pad closed, the PIN entered: \(screen.recorder.shown)")
        try await Task.sleep(for: .seconds(1))   // a confirmation, were one to open, opens once the pad is gone
        XCTAssertFalse(screen.recorder.shown.contains(Self.confirmation), "a confirmation opened off screen: \(screen.recorder.shown)")
        XCTAssertNil(screen.recorder.actions[Self.confirmDelete], "and nothing to confirm with")
        XCTAssertTrue(exists(log) && exists(photo), "nothing is deleted")
    }

    /// The ZIP's README says which photos and clips the ZIP has (DS-1 of the second full review; the owner, 2026-11-11:
    /// "wording approved"): those the log names that were still on the iPhone when it was shared. A log that names two
    /// photos, one of them no longer on the phone: the ZIP has the one, and its README does not say it has both.
    func testTheReadmeSaysTheZIPHasThePhotosStillOnTheIPhone() throws {
        let media = scratch.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let onThePhone = "\(UUID().uuidString).jpg", gone = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(onThePhone))
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(onThePhone, minute: 1), recorded(gone, minute: 2)]).write(to: file)
        let out = scratch.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let folder = try XCTUnwrap(SetAsideLogShare.folder(of: SetAsideLog(url: file), mediaDirectory: media, in: out))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Media").path), [onThePhone],
                       "the ZIP has the photo still on the phone, and not the other")
        let readme = try String(contentsOf: folder.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("with the photos and clips it names that were still on the iPhone when it was shared."),
                      "the README says which photos and clips the ZIP has: \(readme)")
        XCTAssertFalse(readme.contains("with the photos and clips it names. "), "and no longer that it has every one: \(readme)")
    }

    // MARK: - A Delete leaves a status entry (item 234's A1, the third full review; the owner, 2026-11-11: "1", "wording approved also")

    private static let setAsideAt = Date(timeIntervalSince1970: 1_762_520_000)   // the helper's log, by its name

    /// The entry's words: the owner's approved two, then Claude's for what those do not cover; the row's icon; and the
    /// row showing the whole sentence, where a status entry's row has one line.
    func testTheDeletedEntrysWordsAreTheOwnersApprovedOnes() {
        let at = Date(timeIntervalSince1970: 1_762_520_700)
        let when = "\(at.formatted(.dateTime.month(.abbreviated).day())), \(at.formatted(date: .omitted, time: .shortened))"
        func words(_ deleted: Event.SetAsideDeleted) -> String? {
            Event.setAsideDeletedSummary(kind: Event.setAsideDeletedKind(deleted))
        }
        XCTAssertEqual(words(.init(setAsideAt: at, records: 37, mediaRemoved: 4, mediaLeft: false)),
                       "A set-aside log from \(when) was deleted: 37 records, 4 photos and clips")
        XCTAssertEqual(words(.init(setAsideAt: at, records: 37, mediaRemoved: 0, mediaLeft: true)),
                       "A set-aside log from \(when) was deleted: 37 records; its photos and clips were left on this iPhone")
        XCTAssertEqual(words(.init(setAsideAt: at, records: 37, mediaRemoved: 2, mediaLeft: true)),
                       "A set-aside log from \(when) was deleted: 37 records, 2 photos and clips; others were left on this iPhone")
        XCTAssertEqual(words(.init(setAsideAt: at, records: nil, mediaRemoved: 0, mediaLeft: true)),
                       "A set-aside log from \(when) was deleted; its photos and clips were left on this iPhone")
        XCTAssertEqual(words(.init(setAsideAt: nil, records: 1, mediaRemoved: 1, mediaLeft: false)),
                       "A set-aside log was deleted: 1 record, 1 photo or clip")
        XCTAssertEqual(words(.init(setAsideAt: at, records: 0, mediaRemoved: 0, mediaLeft: false)),
                       "A set-aside log from \(when) was deleted: 0 records, 0 photos and clips")
        let kind = Event.setAsideDeletedKind(.init(setAsideAt: at, records: 37, mediaRemoved: 4, mediaLeft: false))
        let entry = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: kind)
        XCTAssertEqual(entry.sensorSummary, "A set-aside log from \(when) was deleted: 37 records, 4 photos and clips",
                       "the Event Log's row")
        XCTAssertEqual(EventRow.placeholderIcon(for: kind), "trash")
        XCTAssertNil(EventRow.summaryLineLimit(for: entry), "the row shows the whole sentence: its numbers are at its end")
        let disarm = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "disarmed")
        XCTAssertEqual(EventRow.summaryLineLimit(for: disarm), 1, "the control: another status entry keeps its one line")
    }

    /// The kind carries its numbers and reads only what it writes: a kind of the sort that is not as written is no
    /// entry of a Delete, and shows as any status entry this version does not know.
    func testTheDeletedKindReadsOnlyWhatItWrites() {
        let at = Date(timeIntervalSince1970: 1_762_520_700)
        let whole = Event.SetAsideDeleted(setAsideAt: at, records: 37, mediaRemoved: 4, mediaLeft: false)
        XCTAssertEqual(Event.setAsideDeletedKind(whole), "setAsideDeleted.1762520700.37.4.0")
        XCTAssertEqual(Event.setAsideDeleted(kind: "setAsideDeleted.1762520700.37.4.0"), whole)
        let left = Event.SetAsideDeleted(setAsideAt: nil, records: nil, mediaRemoved: 0, mediaLeft: true)
        XCTAssertEqual(Event.setAsideDeletedKind(left), "setAsideDeleted.-.-.0.1")
        XCTAssertEqual(Event.setAsideDeleted(kind: "setAsideDeleted.-.-.0.1"), left)
        XCTAssertEqual(Event.setAsideDeletedKind(.init(setAsideAt: at, records: 2_000_000, mediaRemoved: -3, mediaLeft: false)),
                       "setAsideDeleted.1762520700.1000000.0.0", "counts are held to what a kind may carry")
        let malformed = ["setAsideDeleted", "setAsideDeleted.", "setAsideDeleted.1762520700.37.4", "setAsideDeleted.1762520700.37.4.0.0",
                         "setAsideDeleted.1762520700.37.4.2", "setAsideDeleted.1762520700.37.4.", "setAsideDeleted.-1.37.4.0",
                         "setAsideDeleted.1762520700.-1.4.0", "setAsideDeleted.1762520700.37.-4.0", "setAsideDeleted.01762520700.37.4.0",
                         "setAsideDeleted.1762520700.037.4.0", "setAsideDeleted.1762520700.37.+4.0", "setAsideDeleted.32503680001.37.4.0",
                         "setAsideDeleted.1762520700.1000001.4.0", "setAsideDeleted.1762520700.37.1000001.0", "setAsideDeleted.x.37.4.0",
                         "setAsideDeleted.1762520700.37.4.0 ", "setasidedeleted.1762520700.37.4.0", "setAsideDeleted.1762520700.37.-.0",
                         "setAsideDeleted.99999999999999999999.37.4.0", "disarmed"]
        for kind in malformed {
            XCTAssertNil(Event.setAsideDeleted(kind: kind), kind)
            XCTAssertNil(Event.setAsideDeletedSummary(kind: kind), kind)
        }
        let unknown = Event(startDate: at, endDate: at, triggeredSensors: [], stateChange: "setAsideDeleted.1762520700.37.4")
        XCTAssertEqual(unknown.sensorSummary, "Status entry this version of Malinois does not recognize")
    }

    /// The app's Delete is the engine's: it removes the log and the photo only it names, and writes one status entry
    /// that says so, with its numbers. Before item 234 a Delete left no record, where a disarm, a settings change and a
    /// PIN change each leave one.
    func testTheEnginesDeleteWritesAStatusEntryWithItsNumbers() async throws {
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let engine = engine(on: store)
        let before = store.events.count
        let outcome = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(outcome, .deleted)
        XCTAssertFalse(exists(log) || exists(photo), "the log and the photo only it named are gone")
        XCTAssertEqual(deletionEntries(in: store).count, 1, "one status entry: \(store.events.map(\.sensorSummary))")
        XCTAssertEqual(store.events.count, before + 1)
        let entry = try XCTUnwrap(deletionEntries(in: store).first)
        XCTAssertEqual(entry.stateChange.flatMap(Event.setAsideDeleted(kind:)),
                       Event.SetAsideDeleted(setAsideAt: Self.setAsideAt, records: 1, mediaRemoved: 1, mediaLeft: false))
        XCTAssertFalse(entry.isMirrored, "this phone's own entry, signed and uploaded as its others are")
        XCTAssertTrue(entry.sensorSummary.hasSuffix("was deleted: 1 record, 1 photo or clip"), entry.sensorSummary)
    }

    /// Where the Delete had to leave the log's photos (here another set-aside log cannot be read, so it may name the
    /// photo too), the entry says that they were left. Not the event log made unreadable, as the store's own tests of
    /// this answer do: the engine writes that file, and its entry is one such write.
    func testTheEntryOfADeleteThatLeftThePhotosSaysSo() async throws {
        let fm = FileManager.default
        let (store, log, photo) = try storeWithALogNamingAPhoto()
        let other = log.deletingLastPathComponent().appendingPathComponent("events.corrupt-1762500000.json")
        try Data("sealed".utf8).write(to: other)
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: other.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: other.path) }
        XCTAssertNil(try? Data(contentsOf: other), "the test's other log cannot be read")
        let engine = engine(on: store)
        let outcome = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(outcome, .deletedMediaLeft)
        XCTAssertFalse(exists(log), "the log went")
        XCTAssertTrue(exists(photo), "the photo was left")
        let entry = try XCTUnwrap(deletionEntries(in: store).first, "no status entry: \(store.events.map(\.sensorSummary))")
        XCTAssertEqual(entry.stateChange.flatMap(Event.setAsideDeleted(kind:)),
                       Event.SetAsideDeleted(setAsideAt: Self.setAsideAt, records: 1, mediaRemoved: 0, mediaLeft: true))
        XCTAssertTrue(entry.sensorSummary.hasSuffix("was deleted: 1 record; its photos and clips were left on this iPhone"),
                      entry.sensorSummary)
    }

    /// No entry where nothing was deleted, and none for a log that was gone already: one Delete, one entry.
    func testNoEntryIsWrittenWhenNothingWasDeletedOrTheLogWasGoneAlready() async throws {
        let (store, log, _) = try storeWithALogNamingAPhoto()
        let engine = engine(on: store)
        let elsewhere = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try Data("x".utf8).write(to: elsewhere)
        let refused = await engine.deleteSetAsideLog(SetAsideLog(url: elsewhere))
        XCTAssertEqual(refused, .notDeleted)
        XCTAssertEqual(deletionEntries(in: store).count, 0, "nothing was deleted: no entry")
        let first = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(first, .deleted)
        XCTAssertEqual(deletionEntries(in: store).count, 1, "the Delete's entry")
        let again = await engine.deleteSetAsideLog(SetAsideLog(url: log))
        XCTAssertEqual(again, .deleted, "a log already gone is what was asked")
        XCTAssertEqual(deletionEntries(in: store).count, 1, "and it has no second entry")
    }

    /// The store's own answer, which the entry is made from: whether this call removed the log, the records it had and
    /// the photos and clips that went.
    func testTheStoresDeleteReportsWhatItDid() async throws {
        let (store, log, _) = try storeWithALogNamingAPhoto()
        let report = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        XCTAssertEqual(report, SetAsideLogDeletionReport(outcome: .deleted, removedLog: true, records: 1, mediaRemoved: 1))
        let again = await store.deleteSetAsideLogReporting(SetAsideLog(url: log))
        XCTAssertEqual(again, SetAsideLogDeletionReport(outcome: .deleted, removedLog: false, records: nil, mediaRemoved: 0),
                       "gone already: this call removed nothing")
    }

    // MARK: - Helpers

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

    /// The PIN the tests of Delete's pad set.
    private static let pin = "4821"

    /// A PIN in the Keychain, alone there: the pad then submits by itself at four digits (item 106). The Keychain is
    /// every test's, so each test that calls this wipes the PIN's data when it ends.
    private func setThePIN() throws {
        KeychainService.wipeStalePINData()
        try XCTSkipUnless(KeychainService.setPIN(Self.pin), "Keychain unavailable")
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Malinois on screen or in the background, as a test says, for a screen laid out in a test's window.
    private final class TestPhase: ObservableObject {
        @Published var value: ScenePhase = .active
    }

    /// Gives `content` the phase a test sets, where the app's scene gives its own.
    private struct InPhase<Content: View>: View {
        @ObservedObject var phase: TestPhase
        let content: Content
        var body: some View { content.environment(\.scenePhase, phase.value) }
    }

    /// A set-aside log's screen laid out in a window, as the Event Log opens it.
    private struct DeleteScreen {
        let recorder: OnScreenRecorder
        let phase: TestPhase
        let host: UIViewController
        let window: UIWindow

        /// Whatever the screen still has up goes with it.
        @MainActor func close() {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    /// The screen of the set-aside log at `log`, laid out in a window with what the app gives it: the store, and the
    /// settings a PIN pad reads.
    private func deleteScreen(of log: URL, store: EventStore, settings: AppSettings = AppSettings()) throws -> DeleteScreen {
        let recorder = OnScreenRecorder()
        let phase = TestPhase()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        let screen = NavigationStack { InPhase(phase: phase, content: SetAsideLogView(log: SetAsideLog(url: log))) }
            .environmentObject(store).environmentObject(engine).environmentObject(entitlements).environmentObject(settings)
            .environment(\.onScreenRecorder, recorder)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: screen)
        window.rootViewController = host
        window.isHidden = false
        return DeleteScreen(recorder: recorder, phase: phase, host: host, window: window)
    }

    /// Presses the screen's Delete, once nothing stands over the screen (a pad or a dialog that is closing still does),
    /// and waits for the PIN pad with its keys: whether it opened. Fails the test when the screen offers no Delete or no
    /// pad opens.
    private func deleteOpensThePad(_ screen: DeleteScreen, file: StaticString = #filePath, line: UInt = #line) async -> Bool {
        let offered = await settles(within: 10) {
            screen.recorder.actions[SetAsideLogWords.deleteButton] != nil && self.padIsGone(screen)
                && screen.host.presentedViewController == nil
        }
        XCTAssertTrue(offered, "the screen offers Delete, with nothing over it: \(screen.recorder.shown)", file: file, line: line)
        screen.recorder.actions[SetAsideLogWords.deleteButton]?()
        let up = await settles(within: 10) {
            screen.recorder.shown.contains(Self.deletePad) && screen.recorder.actions["PIN key 1"] != nil
        }
        XCTAssertTrue(up, "Delete opens the PIN pad: \(screen.recorder.shown)", file: file, line: line)
        return up
    }

    /// No pad of Delete's on the screen: neither its title nor a key nor its Cancel.
    private func padIsGone(_ screen: DeleteScreen) -> Bool {
        !screen.recorder.shown.contains(Self.deletePad) && screen.recorder.actions["PIN key 1"] == nil
            && screen.recorder.actions["Cancel: " + Self.deletePad] == nil
    }

    /// Types `digits` on the pad the screen has up, key by key, as a finger does.
    private func typeOnThePad(_ digits: String, of screen: DeleteScreen) async throws {
        for digit in digits {
            let key = try XCTUnwrap(screen.recorder.actions["PIN key \(digit)"], "the pad has no key \(digit)")
            key()
            try await Task.sleep(for: .milliseconds(50))   // the pad draws the digit before the next
        }
    }

    /// A photo named a UUID and `ext`, a name the store never gives, and two set-aside logs whose records name it: the
    /// first writes the extension, as the media folder lists it, through `deleted`, the second through `other` (two
    /// JSON spellings of it). Each log's record decodes to the photo's name; the search finds the name in the first
    /// log and not in the second. After Delete of the first, the photo is still there, the other log is as it was,
    /// and the delete has nothing to tell.
    private func assertDeleteLeavesAPhoto(withExtension ext: String, deletedLogWrites deleted: (String) -> String,
                                          otherLogWrites other: (String) -> String, line: UInt = #line) async throws {
        let fm = FileManager.default
        let store = EventStore()
        store.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = store.mediaDirectory
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        let uuid = UUID().uuidString
        let photo = try XCTUnwrap(EventStore.mediaFile(named: uuid + "." + ext, in: media), line: line)
        try Data([0xFF, 0xD8, 0x01]).write(to: photo)
        let listed = try XCTUnwrap(try fm.contentsOfDirectory(atPath: media.path).first { $0.hasPrefix(uuid) }, line: line)
        XCTAssertEqual(listed, uuid + "." + ext, "the media folder lists the photo under its name", line: line)
        let listedExtension = String(listed.dropFirst(uuid.count + 1))
        let first = root.appendingPathComponent("events.corrupt-1762520000.json")
        let second = root.appendingPathComponent("events.corrupt-1762500000.json")
        let firstBytes = try log(naming: uuid, extensionWritten: deleted(listedExtension), minute: 1)
        let secondBytes = try log(naming: uuid, extensionWritten: other(listedExtension), minute: 2)
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        for file in [first, second] {
            XCTAssertEqual(SetAsideLog.read(SetAsideLog(url: file)).records.map(\.mediaFilename), [listed],
                           "each log's record decodes to the photo's name", line: line)
        }
        XCTAssertTrue(SetAsideLog.names(listed, in: SetAsideLog.searchForms(of: firstBytes)),
                      "the search finds the name in the log to delete", line: line)
        XCTAssertFalse(SetAsideLog.names(listed, in: SetAsideLog.searchForms(of: secondBytes)),
                       "and not in the other log, which writes it another way", line: line)
        store.refreshSetAsideLogs()
        let outcome = await store.deleteSetAsideLog(SetAsideLog(url: first))
        XCTAssertEqual(outcome, .deleted, line: line)
        XCTAssertEqual(store.setAsideDeletionsToTell, [], line: line)
        XCTAssertFalse(fm.fileExists(atPath: first.path), "the log goes", line: line)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes, "the other log is as it was", line: line)
        XCTAssertTrue(fm.fileExists(atPath: photo.path), "the photo stays: \(listed.debugDescription)", line: line)
    }

    /// `json` with the first character of every string written as its unicode escape, so that each string has one. For
    /// text with no escape of its own, as the encoder writes the test's record.
    private func withAnEscapeInEveryString(_ json: String) -> String {
        let backslash = "\\"
        var written = ""
        var opening = true
        var first = false
        for scalar in json.unicodeScalars {
            if scalar == "\"" {
                first = opening
                opening.toggle()
                written.unicodeScalars.append(scalar)
            } else {
                if first, scalar.isASCII {
                    let digits = String(scalar.value, radix: 16)
                    written += backslash + "u" + String(repeating: "0", count: 4 - digits.count) + digits
                } else {
                    written.unicodeScalars.append(scalar)
                }
                first = false
            }
        }
        return written
    }

    /// A UUID's text in lower case that is not also its text in capitals: one with a letter in it. A UUID of digits
    /// alone, which is rare, reads the same either way, and would be a name the store gives.
    private func lowerCaseUUID() -> String {
        var uuid = UUID().uuidString
        while uuid.lowercased() == uuid { uuid = UUID().uuidString }
        return uuid.lowercased()
    }

    /// A set-aside log of one record whose photo's name is `uuid`, a dot and `written`, put into the encoder's bytes
    /// as given: a JSON spelling of an extension.
    private func log(naming uuid: String, extensionWritten written: String, minute: Int) throws -> Data {
        let placeholder = uuid + ".jpg"
        let text = try XCTUnwrap(String(data: JSONEncoder().encode([recorded(placeholder, minute: minute)]), encoding: .utf8))
        XCTAssertTrue(text.contains(placeholder), "the encoder wrote the name as given")
        return Data(text.replacingOccurrences(of: placeholder, with: uuid + "." + written).utf8)
    }

    /// `log`'s bytes with `name` written as only an edited backup writes it: its first hyphen as a JSON `\u` escape. Not
    /// its first character: the escape of a digit ends in that digit, so the name would still be there as written.
    private func withAnEscape(for name: String, in log: Data) throws -> Data {
        let hyphen = try XCTUnwrap(name.firstIndex(of: "-"))
        let written = String(name[..<hyphen]) + "\\u002d" + String(name[name.index(after: hyphen)...])
        let text = try XCTUnwrap(String(data: log, encoding: .utf8))
        XCTAssertTrue(text.contains(name), "the test's log names it as written first")
        return Data(text.replacingOccurrences(of: name, with: written).utf8)
    }

    /// A record that names a photo and, with `secondCamera`, the second camera's clip, with a thumbnail the screen can
    /// show; and its files, in a `Media` under the store's root that is a real folder or, `underALinkedMediaFolder`, a
    /// link to another folder where the files are. Made before any store, which would make the folder itself.
    private func recordWithItsFiles(underALinkedMediaFolder linked: Bool, secondCamera: Bool = true) throws -> (record: Event, media: URL) {
        let fm = FileManager.default
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appendingPathComponent("Media")
        let folder = linked ? scratch.appendingPathComponent("Elsewhere", isDirectory: true) : media
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if linked { try fm.createSymbolicLink(at: media, withDestinationURL: folder) }
        var record = event(1)
        record.mediaFilename = "\(UUID().uuidString).jpg"
        record.secondaryMediaFilename = secondCamera ? "\(UUID().uuidString).mov" : nil
        record.thumbnailData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            .jpegData(withCompressionQuality: 0.8) { context in
                UIColor.gray.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            }
        for name in [record.mediaFilename, record.secondaryMediaFilename].compactMap({ $0 }) {
            try Data([0xFF, 0xD8, 0x01]).write(to: folder.appendingPathComponent(name))
        }
        return (record, media)
    }

    /// A folder at `url` with one file in it, which is returned: what an edited backup can put where a file belongs.
    @discardableResult
    private func folder(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let inside = url.appendingPathComponent("inside.txt")
        try Data("not the app's to remove".utf8).write(to: inside)
        return inside
    }

    /// Whether what is at `url` is a link, read as the app's own rule reads it: its own attributes, never followed.
    private func isLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// A file named as the store names a photo, in `folder`, old enough for the launch's sweep.
    private func oldFile(in folder: URL) throws -> URL {
        let file = folder.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0x01]).write(to: file)
        try age(file)
        return file
    }

    /// Makes what is at `url` three days old: the sweep leaves anything younger than a day.
    private func age(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86_400)], ofItemAtPath: url.path)
    }

    /// A store whose log is at the incident limit, its oldest row naming `media` and `secondary`: the next record added
    /// has the limit take that row, and the removal behind it take the row's photos and clips (as item 187's test of a
    /// name outside the media folder sets it up).
    private func storeWhoseOldestRowNames(_ media: String, _ secondary: String? = nil) throws -> (store: EventStore, oldest: UUID) {
        let now = Date()
        var held = (0..<EventStore.maxIncidentEvents).map { index in
            let at = now.addingTimeInterval(-Double(index + 1))
            return Event(startDate: at, endDate: at, triggeredSensors: [.motion], cloudSyncState: .synced)
        }
        held[held.count - 1].mediaFilename = media
        held[held.count - 1].secondaryMediaFilename = secondary
        try JSONEncoder().encode(held).write(to: try logURL())
        return (EventStore(), held[held.count - 1].id)
    }

    /// The Event Log's notice after a Delete that left the log's photos and clips, and the title of the one after a Delete
    /// that deleted nothing (item 227's DS-5).
    private static let leftTitle = "Set-aside log deleted"
    private static let leftMessage = "Its photos and clips may still be on this iPhone: Malinois couldn't tell which were only "
        + "this log's, or couldn't remove them. Any that no record names are cleared later, once no set-aside log is kept."
    private static let notDeletedTitle = "The set-aside log couldn't be deleted"

    /// A store with one set-aside log in its folder, which names one photo on the phone that nothing else names. The
    /// store's launch work is over before the files are written, so nothing of it meets what a test puts there.
    private func storeWithALogNamingAPhoto() throws -> (store: EventStore, log: URL, photo: URL) {
        let store = EventStore()
        store.drainIOForTesting()
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let media = store.mediaDirectory
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let name = "\(UUID().uuidString).jpg"
        try Data([0xFF, 0xD8, 0x01]).write(to: media.appendingPathComponent(name))
        let log = root.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode([recorded(name, minute: 1)]).write(to: log)
        store.refreshSetAsideLogs()
        return (store, log, media.appendingPathComponent(name))
    }

    /// Lets the main run loop turn until `condition` holds, three seconds at most, or `seconds` (a screen that opens or
    /// closes over another takes longer); whether it came to hold.
    private func settles(within seconds: Int = 3, _ condition: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(seconds))
        while !condition(), clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// The Event Log on `store`, with an engine and the free tier, as item 168's tests lay it out.
    private func eventLog(of store: EventStore) -> some View {
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return NavigationStack { EventLogView() }
            .environmentObject(store).environmentObject(engine).environmentObject(cloud).environmentObject(entitlements)
    }

    /// A set-aside record's badge when it was backed up before its log was set aside (item 227's DS-2).
    private static let syncedThen = "Synced when set aside"

    /// Every word an iCloud badge can have.
    private static let badges = ["iCloud synced", "Local only", "Syncing…", syncedThen]

    private struct ScreenRig {
        let store: EventStore
        let engine: MonitoringEngine
        let entitlements: ProEntitlements
    }

    /// A store, an engine and the free tier, for laying out the set-aside screens: on the free tier no upload hold applies
    /// to any record, so a badge's words depend on the record alone.
    private func makeScreenRig() -> ScreenRig {
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return ScreenRig(store: store, engine: engine, entitlements: entitlements)
    }

    private func screenOf<V: View>(_ view: V, _ rig: ScreenRig) -> some View {
        view.environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
    }

    /// A set-aside log of `records`, written in the test's own folder.
    private func setAsideLog(_ records: [Event]) throws -> SetAsideLog {
        let file = scratch.appendingPathComponent("events.corrupt-1762520000.json")
        try JSONEncoder().encode(records).write(to: file)
        return SetAsideLog(url: file)
    }

    /// An arm record from another phone, as an iCloud copy brings it.
    private func otherPhonesArm(_ state: CloudSyncState) -> Event {
        Event(startDate: Date(), endDate: Date(), triggeredSensors: [], cloudSyncState: state, stateChange: "armed",
              sourceDevice: "iPhone Air")
    }

    /// A record that names `media` as its photo.
    private func recorded(_ media: String, minute: Int) -> Event {
        var record = event(minute)
        record.mediaFilename = media
        return record
    }

    private func event(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 11, 7, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }

    /// The store's log in the test's own folder, made first: `TestIsolation` only names the folder, and a store makes it
    /// when it first touches its files, so a damaged log written before any store has started needs it made here, as
    /// `Item73RegressionTests` does (chain c's first red run, 2026-11-07: without it the write threw).
    private func logURL() throws -> URL {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("events.json")
    }

    /// A damaged `file` beside the log, with the set-aside names of this second and the next few taken (the test cannot
    /// know the second the store reads): after a launch the file is set aside under a name of its own, as it was, and is
    /// no longer in its place.
    private func assertSetAsideUnderANameOfItsOwn(_ file: String, namedFrom prefix: String, line: UInt = #line) throws {
        let root = try logURL().deletingLastPathComponent()
        let now = Int(Date().timeIntervalSince1970)
        let taken = (now...(now + 5)).map { root.appendingPathComponent("\(prefix)\($0).json") }
        for url in taken { try Data("an earlier one".utf8).write(to: url) }
        let damaged = Data("damaged".utf8)
        try damaged.write(to: root.appendingPathComponent(file))

        let store = EventStore()
        store.drainIOForTesting()
        for url in taken {
            XCTAssertEqual(try Data(contentsOf: url), Data("an earlier one".utf8), "the earlier ones are as they were", line: line)
        }
        let all = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(prefix) }
        let new = all.filter { name in !taken.contains { $0.lastPathComponent == name } }
        XCTAssertEqual(new.count, 1, "one more set aside: \(all)", line: line)
        if let name = new.first {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(name)), damaged, "the file as it was", line: line)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path),
                       "and it is no longer in its place, where no later write would have replaced it", line: line)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
    }
}
