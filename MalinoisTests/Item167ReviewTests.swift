//
//  Item167ReviewTests.swift
//  MalinoisTests
//
//  BACKLOG item 167: Codex's full top-to-bottom review of 1.8.2 (79) at b7221cb, ruled 2026-10-26 (the owner: "yes,
//  all as recommended, A1 as (a)"). A1: a warning the PIN pad's quiet window held back is shown once the typing stops
//  or the pad closes without a correct PIN. A2: a two-camera capture's download stays offered while a file it names is
//  not here, on every visit, and a file that cannot be stored here leaves the download incomplete. A3: a siren start
//  that fails without throwing is retried and reported like one that throws. Each written before its fix, red there.
//  Codex's look at the fixes (`b7221cb..0920241`): codex-5, a rear-only capture whose file is here still offered a
//  download; codex-6, a refused siren start left the audio session active after the alert; codex-4, a warning that came
//  up while the PIN pad was open was drawn under it, now shown above the pad (the owner's option 1, the armed time
//  kept). Red before their fixes too. Codex's look at those (`0920241..073e5d2`): codex-7, the offer counted the names
//  a record lists against the files here, so another camera's file stood in for a missing one. Red before its fix.
//  DeepSeek's look at that (`073e5d2..ce4c949`): deepseek-1, a record's list of its media named only the files its maker
//  still held, so a file that had landed and was still in iCloud could drop off it (the owner's option 1: the list
//  names what landed too). Red before its fix.
//

import CloudKit
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item167ReviewTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem167Review")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - A1 (codex-1 on b7221cb): a warning the PIN pad's quiet window held back

    /// The pad stays open and quiet long enough for a capture to end inside its quiet window, and for the check after.
    private static let padTiming: EngineTiming = {
        var t = EngineCharacterizationTests.fastTiming
        t.disarmActivityGrace = 4
        t.disarmEntryTimeout = 8
        t.disarmEntryCeiling = 20
        t.alertDuration = 3
        return t
    }()

    /// The quiet window ends well before the pad's own timeout.
    private static let quietTiming: EngineTiming = {
        var t = padTiming
        t.disarmActivityGrace = 2
        return t
    }()

    /// The owner's hold, in Alert mode: its press-down is a Touch trip, its still is held until the pad has opened 5 s
    /// into the hold, and it lands inside the pad's quiet window (20 s from the last keypress, or from the pad opening).
    private func captureEndingInsideTheQuietWindow(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.camera.holdStills = true
        rig.engine.noteDisarmCandidate()   // press-down opens the attribution window …
        rig.engine.reportTouch()           // … and is a Touch trip
        XCTAssertTrue(pump(until: { rig.camera.stills.count == 1 }, timeout: 3), "the still is asked for",
                      file: file, line: line)
        rig.engine.beginDisarmEntry()
        rig.camera.releaseStills()
        XCTAssertTrue(pump(until: {
            rig.engine.state == .armed
                && rig.store.events.contains { $0.triggeredSensors == [.touch] && $0.mediaFilename != nil }
        }, timeout: 3), "the capture ends with the pad open", file: file, line: line)
    }

    /// item 167's A1: the hold that opens the pad is itself a Touch trip, and its capture can end once the pad is open,
    /// inside the quiet window that holds a fresh warning back while the owner types. That warning was dropped: closing
    /// the pad without a PIN (Cancel, or its timeout) restored the screen and nothing else, and the incident never warned.
    func testAWarningThePadHeldBackShowsWhenThePadClosesWithoutAPIN() {
        let rig = makeRig(timing: Self.padTiming) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        XCTAssertFalse(rig.engine.alertActive, "held back while the owner may be typing")
        rig.engine.endDisarmEntry()   // Cancel, or the pad's timeout
        XCTAssertTrue(rig.engine.alertActive, "shown once the pad closed without a PIN")
        rig.engine.disarm()
    }

    /// item 167's A1: the quiet window ends 20 s after the last keypress, the rule that lets a new trip warn on an idle
    /// open pad. The warning it held back now shows then, the pad still open.
    func testAWarningThePadHeldBackShowsWhenTheQuietWindowEnds() {
        let rig = makeRig(timing: Self.quietTiming) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        XCTAssertFalse(rig.engine.alertActive, "held back while the owner may be typing")
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 5), "shown once the typing stopped")
        XCTAssertTrue(rig.engine.disarmEntryActive, "with the pad still open")
        rig.engine.disarm()
    }

    /// item 167's A1: each keypress starts the quiet window again, and the warning it held back waits for the new end.
    /// Written with the fix; red with the keypress's restart of the window's timer taken out (the undo check).
    func testAKeypressMovesTheEndOfTheQuietWindow() {
        let rig = makeRig(timing: Self.quietTiming) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        settle(1)
        rig.engine.noteDisarmActivity()   // a keypress 1 s in: the window now ends 2 s after it
        XCTAssertFalse(pump(until: { rig.engine.alertActive }, timeout: 1.5), "not at the first window's end")
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 2.5), "at the new one")
        XCTAssertTrue(rig.engine.disarmEntryActive, "with the pad still open")
        rig.engine.disarm()
    }

    /// item 167's A1: the warning waits while the owner may be typing, whatever repaints the screen meanwhile (a timer's
    /// answer that arrives just after a keypress). Written with the fix; red with the engine's check taken out.
    func testARepaintWhileTheOwnerTypesShowsNoWarning() {
        let rig = makeRig(timing: Self.padTiming) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        rig.engine.disarmPresentationChanged()   // a repaint inside the quiet window
        XCTAssertFalse(rig.engine.alertActive, "not while the owner may be typing")
        rig.engine.endDisarmEntry()
        XCTAssertTrue(rig.engine.alertActive, "still owed, and shown once the pad closed")
        rig.engine.disarm()
    }

    /// item 167's A1: the same for Alert mode's early warning during an Until clear clip, due 3 s into the clip: held
    /// back while the pad is in use, it now shows when the pad closes, the clip still recording.
    func testAnEarlyUntilClearWarningThePadHeldBackShowsWhenThePadCloses() {
        var timing = Self.padTiming
        timing.untilClearIdle = 4
        timing.untilClearWarningAfter = 0.3
        let rig = makeRig(timing: timing) { $0.responseMode = .alert; $0.captureMode = .untilClear; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.beginDisarmEntry()
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.camera.clips.count == 1 }, timeout: 3), "the clip starts")
        settle(1.2)   // past the warning time
        XCTAssertFalse(rig.engine.alertActive, "held back while the owner may be typing")
        rig.engine.endDisarmEntry()
        XCTAssertTrue(rig.engine.alertActive, "shown once the pad closed")
        XCTAssertEqual(rig.camera.clipEnds, 0, "while the clip still records")
        rig.engine.disarm()
    }

    /// Control: a correct PIN is the owner. The warning held back goes with the watch, and the next watch does not
    /// inherit it. Passes before and after the fix.
    func testACorrectPINClearsTheWarningThePadHeldBack() {
        let rig = makeRig(timing: Self.padTiming) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        rig.engine.disarm()   // the correct PIN
        settle(0.3)
        XCTAssertFalse(rig.engine.alertActive, "no warning after the owner's disarm")
        arm(rig)
        rig.engine.beginDisarmEntry()
        rig.engine.endDisarmEntry()
        XCTAssertFalse(rig.engine.alertActive, "and none owed into the next watch")
        rig.engine.disarm()
    }

    /// Control: Stealth shows no warning, held back or not. Passes before and after the fix.
    func testStealthOwesNoWarning() {
        let rig = makeRig(timing: Self.padTiming) { $0.responseMode = .stealth; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        captureEndingInsideTheQuietWindow(rig)
        rig.engine.endDisarmEntry()
        XCTAssertFalse(rig.engine.alertActive)
        rig.engine.disarm()
    }

    // MARK: - codex-4 on 0920241: a warning under the open pad

    private static let message = AppSettings.defaultAlertMessage
    private static let padTitle = "Enter PIN to disarm"
    private static let armedFor = "Armed for"
    private static let shortScreens = [CGSize(width: 375, height: 647),   // iPhone SE, below the status bar
                                       CGSize(width: 387, height: 645)]   // the iPhone Duo's outer display

    /// codex-4 on 0920241: the armed screen drew its warning only while the PIN pad was closed, so the warning the quiet
    /// window's end brought up came up under an open pad, ran out there unseen, and the pad's own timeout then found
    /// nothing owed. A warning that is up while the pad is open now shows above the pad, under the armed time (the
    /// owner's option 1, "as long as armed for isn't removed"). The real screen, live through the whole sequence.
    func testAWarningTheQuietWindowsEndBringsUpShowsAboveTheOpenPad() throws {
        var timing = Self.padTiming
        timing.disarmActivityGrace = 1.5
        timing.disarmEntryTimeout = 6   // the pad closes itself after the warning has run out
        timing.alertDuration = 1.5
        let rig = makeRig(timing: timing) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        try withArmedScreen(rig) { screen in
            captureEndingInsideTheQuietWindow(rig)
            XCTAssertFalse(screen.shown.contains(Self.message), "held back while the owner may be typing")
            XCTAssertTrue(pump(until: { screen.shown.contains(Self.message) }, timeout: 4.5),
                          "shown once the typing stopped, before the warning ran out")
            XCTAssertTrue(rig.engine.disarmEntryActive, "with the pad open")
            try assertTheWarningSitsBetweenTheArmedTimeAndThePad(screen)
            // On through the rest of the sequence (Codex's note on 073e5d2): the warning runs out, seen, the pad still
            // open; the pad closes itself; nothing owed is left to come back.
            XCTAssertTrue(pump(until: { !screen.shown.contains(Self.message) }, timeout: 3), "the warning runs out")
            XCTAssertTrue(rig.engine.disarmEntryActive, "the pad still open")
            XCTAssertTrue(pump(until: { !rig.engine.disarmEntryActive }, timeout: 5), "the pad closes itself")
            settle(0.3)
            XCTAssertFalse(rig.engine.alertActive, "nothing owed comes back")
            XCTAssertFalse(screen.shown.contains(Self.message))
        }
        rig.engine.disarm()
    }

    /// codex-4 on 0920241, older than item 167: a new trip's warning on an open pad nobody is typing on (an idle pad
    /// alerts normally, A-02) was drawn under the pad as well, and could run out there. It now shows above the pad.
    func testANewTripsWarningOnAnIdleOpenPadShowsAboveIt() throws {
        var timing = Self.padTiming
        timing.disarmActivityGrace = 0.5   // nobody types: the pad is idle half a second after it opens
        timing.alertDuration = 3
        let rig = makeRig(timing: timing) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        try withArmedScreen(rig) { screen in
            rig.engine.beginDisarmEntry()
            settle(0.8)
            rig.engine.handleTrip(.motion)
            XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 3), "the trip's warning is up")
            XCTAssertTrue(pump(until: { screen.shown.contains(Self.message) }, timeout: 2), "and shown, above the open pad")
            XCTAssertTrue(rig.engine.disarmEntryActive)
            try assertTheWarningSitsBetweenTheArmedTimeAndThePad(screen)
        }
        rig.engine.disarm()
    }

    /// codex-4 on 0920241: at the largest text size on the short screens, with the camera running, the warning above
    /// the open pad shows its whole default message, and the REC badge, the armed time and the warning all sit above
    /// the pad's title; a message of the owner's own at its longest (300 characters) keeps to four lines there, the
    /// pad's title still on screen below it.
    func testTheWarningAboveThePadFitsAShortScreenAtTheLargestTextSize() throws {
        var timing = Self.padTiming
        timing.disarmActivityGrace = 0.5
        timing.disarmEntryTimeout = 60
        timing.disarmEntryCeiling = 120
        timing.alertDuration = 60   // up through every layout
        let rig = makeRig(timing: timing) { $0.responseMode = .alert; $0.captureMode = .photo; $0.cameraPosition = .front }
        arm(rig)
        rig.engine.beginDisarmEntry()
        settle(0.8)
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.alertActive && rig.engine.state == .armed }, timeout: 3), "the warning is up")
        rig.camera.setRecordingActive(true)
        let largest = DynamicTypeSize.accessibility5
        for size in Self.shortScreens {
            try withArmedScreen(rig, size: size, textSize: largest) { screen in
                let warning = try assertTheWarningSitsBetweenTheArmedTimeAndThePad(screen, in: size)
                let needed = neededHeight(of: Self.message, width: warning.width)
                XCTAssertGreaterThanOrEqual(warning.height, needed.rounded(.up) - 4,
                                            "the warning is cut off at \(size): \(warning.height) tall, needs \(needed)")
                let title = try XCTUnwrap(screen.frames[Self.padTitle])
                let rec = try XCTUnwrap(screen.frames["REC"], "no REC badge at \(size), the camera running")
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(rec), "the REC badge is off screen at \(size): \(rec)")
                XCTAssertGreaterThanOrEqual(title.minY, rec.maxY - 0.5, "the REC badge lies over the title at \(size)")
            }
        }
        rig.settings.alertMessage = String(repeating: "Unauthorized access is being recorded. ", count: 9)
        let long = MonitoringEngine.sanitizedAlertMessage(rig.settings.alertMessage, fallback: AppSettings.defaultAlertMessage)
        XCTAssertEqual(long.count, 300, "the longest message the warning shows")
        let size = Self.shortScreens[0]
        try withArmedScreen(rig, size: size, textSize: largest) { screen in
            let warning = try XCTUnwrap(screen.frames[long], "no warning above the pad")
            XCTAssertLessThanOrEqual(warning.height, 4 * lineHeight() + 4, "the long message runs past four lines")
            let title = try XCTUnwrap(screen.frames[Self.padTitle], "no pad")
            XCTAssertGreaterThanOrEqual(title.minY, warning.maxY - 0.5, "the warning lies over the pad's title")
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(title), "the pad's title is off screen")
        }
        rig.engine.disarm()
    }

    /// `message` above the open pad, between the armed time above it and the pad's title below, on screen; the armed
    /// time and the pad are still shown. Returns the warning's frame.
    @discardableResult
    private func assertTheWarningSitsBetweenTheArmedTimeAndThePad(_ screen: OnScreenRecorder,
                                                                  message: String = AppSettings.defaultAlertMessage,
                                                                  in size: CGSize = CGSize(width: 402, height: 874),
                                                                  file: StaticString = #filePath,
                                                                  line: UInt = #line) throws -> CGRect {
        XCTAssertTrue(screen.shown.contains(message), "no warning on screen at \(size)", file: file, line: line)
        let warning = try XCTUnwrap(screen.frames[message], "no warning laid out at \(size)", file: file, line: line)
        XCTAssertTrue(screen.shown.contains(Self.armedFor), "the armed time is gone", file: file, line: line)
        XCTAssertTrue(screen.shown.contains(Self.padTitle), "the pad is gone", file: file, line: line)
        let armedFor = try XCTUnwrap(screen.frames[Self.armedFor], file: file, line: line)
        let title = try XCTUnwrap(screen.frames[Self.padTitle], file: file, line: line)
        XCTAssertGreaterThanOrEqual(warning.minY, armedFor.maxY - 0.5, "the warning lies over the armed time at \(size)",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(title.minY, warning.maxY - 0.5, "the warning lies over the pad's title at \(size)",
                                    file: file, line: line)
        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(warning), "the warning is off screen at \(size): \(warning)",
                      file: file, line: line)
        return warning
    }

    /// The warning line's font, as the armed screen sets it, at the largest size the warning uses.
    private func warningFont() -> UIFont {
        let category = UIContentSizeCategory(AlertMessageView.largestTextSize)
        let base = UIFont.preferredFont(forTextStyle: .subheadline,
                                        compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        return UIFont.systemFont(ofSize: base.pointSize, weight: .bold)
    }

    /// The height UIKit lays `text` out in, in the warning line's font, at `width`.
    private func neededHeight(of text: String, width: CGFloat) -> CGFloat {
        (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading],
                                        attributes: [.font: warningFont()], context: nil).height
    }

    private func lineHeight() -> CGFloat { warningFont().lineHeight }

    // MARK: - A2 (codex-2 on b7221cb): a partial two-camera download

    private static let offer = "Download full evidence from iCloud"
    private static let thumbnail = Data([0xFF, 0xD8, 0xFF])

    /// Another device's Both capture as this iPhone holds it: its record names the front and rear files it uploaded,
    /// and neither is here yet.
    private func bothCamerasFromAnotherDevice(_ id: UUID) -> Event {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return Event(id: id, startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                     thumbnailData: Self.thumbnail, primaryCamera: "front", secondaryCamera: "rear",
                     cloudSyncState: .synced, sourceDevice: "iPad", cloudRevision: 1, cloudMediaManifest: ["front", "rear"])
    }

    /// A still as iCloud hands it over: a file whose bytes start like a JPEG.
    private func stillFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisItem167-\(UUID().uuidString).jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// item 167's A2: another device's Both capture whose rear has not uploaded yet. The download brings the front, and
    /// iCloud answers for the rear that it holds no such record, so the fetch is complete: the offer went with the
    /// front's arrival, for good, though the rear lands later. After a fetch that could not check the rear, the offer
    /// lasted only while the screen stayed open. It now stands, on every visit, while a file the record names is not here.
    func testATwoCameraCaptureKeepsItsDownloadWhileAFileItNamesIsNotHere() throws {
        let rig = makeRig()
        for complete in [true, false] {
            let id = UUID()
            rig.store.merge([bothCamerasFromAnotherDevice(id)])
            let front = try stillFile()
            rig.engine.fullMediaFetchForTesting = { _, _ in
                CloudExfiltrator.FullMediaFetch(
                    media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)], complete: complete)
            }
            _ = Task { await rig.engine.downloadFullEvidence(for: id) }
            XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.mediaFilename != nil }, timeout: 5),
                          "complete \(complete): the front lands")
            let held = try XCTUnwrap(rig.store.events.first { $0.id == id })
            XCTAssertNil(held.secondaryMediaFilename, "complete \(complete): the rear is not here")
            XCTAssertTrue(try shownTexts(on: detail(held, rig)).contains(Self.offer),
                          "complete \(complete): a new visit still offers the download, for the rear")
        }
    }

    /// item 167's A2: a file iCloud gave that cannot be kept here (it fails to stage, or to store) was skipped, and the
    /// download still reported iCloud's completeness, as if nothing were left to get.
    func testAFileThatCannotBeKeptHereLeavesTheDownloadIncomplete() async throws {
        let rig = makeRig()
        let id = UUID()
        rig.store.merge([bothCamerasFromAnotherDevice(id)])
        let front = try stillFile()
        let rear = FileManager.default.temporaryDirectory
            .appendingPathComponent("MalinoisItem167-\(UUID().uuidString).jpg")   // never written: it cannot be staged
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front),
                                                    CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: true)
        }
        let download = await rig.engine.downloadFullEvidence(for: id)
        XCTAssertTrue(download.landed, "the front landed")
        XCTAssertFalse(download.complete, "the rear iCloud gave is not here: the download is not the whole capture")
    }

    /// item 167's A2, the other way a capture that came back is not kept: storing it here fails. Written with the fix;
    /// red with its guard taken out (the undo check).
    func testACaptureThatCannotBeStoredHereLeavesTheDownloadIncomplete() async throws {
        let rig = makeRig()
        let id = UUID()
        rig.store.merge([bothCamerasFromAnotherDevice(id)])
        let front = try stillFile()
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)],
                                            complete: true)
        }
        let media = rig.store.mediaDirectory
        let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: media.path)[.posixPermissions])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: media.path)   // nothing can be stored
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: media.path) }
        let download = await rig.engine.downloadFullEvidence(for: id)
        XCTAssertFalse(download.landed, "nothing was stored")
        XCTAssertFalse(download.complete, "the front iCloud gave is not here: the download is not the whole capture")
    }

    /// item 167's A2: a record holds two files at most, so a list naming more asks for no more than two (copies from
    /// another device carry each allowed name once, four at most). A control since codex-7's fix replaced the count cap
    /// it was written for: every name it lists is held, so it passes with or without the two-slot bound, whose own test
    /// is `testARecordWithBothItsFilesHereOffersNothingMore` (DeepSeek's deepseek-3 on ce4c949).
    func testARecordNamingMoreThanTwoFilesIsWholeWithTwo() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let both = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                         mediaFilename: "front.jpg", secondaryMediaFilename: "rear.jpg", primaryCamera: "front",
                         secondaryCamera: "rear", cloudSyncState: .synced, sourceDevice: "iPad", cloudRevision: 1,
                         cloudMediaManifest: ["front", "rear", "primary"])
        XCTAssertFalse(both.namesMediaNotHeldHere, "both files here")
        var one = both
        one.secondaryMediaFilename = nil
        XCTAssertTrue(one.namesMediaNotHeldHere, "one of two here")
    }

    /// Control: once every file the record names is here, a visit offers no download. Passes before and after the fix.
    func testTheOfferGoesOnceEveryFileTheRecordNamesIsHere() throws {
        let rig = makeRig()
        let id = UUID()
        rig.store.merge([bothCamerasFromAnotherDevice(id)])
        let front = try stillFile(), rear = try stillFile()
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front),
                                                    CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: true)
        }
        _ = Task { await rig.engine.downloadFullEvidence(for: id) }
        XCTAssertTrue(pump(until: {
            let held = rig.store.events.first { $0.id == id }
            return held?.mediaFilename != nil && held?.secondaryMediaFilename != nil
        }, timeout: 5), "both land")
        let held = try XCTUnwrap(rig.store.events.first { $0.id == id })
        XCTAssertFalse(try shownTexts(on: detail(held, rig)).contains(Self.offer))
    }

    /// Control: a camera whose capture failed promises no file. This iPhone's Both capture whose rear failed, and another
    /// device's that lists only its front, each with the front here: no offer. Passes before and after the fix.
    func testACameraThatCapturedNothingPromisesNoFile() throws {
        let rig = makeRig()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let failed = ["rear": CaptureFailureReason.cameraUnavailable.rawValue]
        let own = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                        mediaFilename: "front.jpg", thumbnailData: Self.thumbnail, primaryCamera: "front",
                        cloudSyncState: .synced, captureFailuresByCamera: failed)
        let mirrored = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                             mediaFilename: "front.jpg", thumbnailData: Self.thumbnail, primaryCamera: "front",
                             cloudSyncState: .synced, sourceDevice: "iPad", cloudRevision: 1,
                             captureFailuresByCamera: failed, cloudMediaManifest: ["front"])
        for event in [own, mirrored] {
            XCTAssertFalse(try shownTexts(on: detail(event, rig)).contains(Self.offer), "mirrored \(event.isMirrored)")
        }
    }

    // MARK: - codex-5 on 0920241: a rear-only capture whose file is here

    /// codex-5 on 0920241: a Both capture whose front failed keeps its rear in the second slot, and a copy from another
    /// device can list only its rear. With that file here, the detail screen still offered a download, since its first
    /// slot was empty, and a tap could only say nothing came back.
    func testARearOnlyCaptureWhoseFileIsHereOffersNoDownload() throws {
        let rig = makeRig()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let frontFailed = ["front": CaptureFailureReason.cameraUnavailable.rawValue]
        let own = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                        secondaryMediaFilename: "rear.jpg", secondaryCamera: "rear", cloudSyncState: .synced,
                        captureFailuresByCamera: frontFailed)
        XCTAssertFalse(try shownTexts(on: detail(own, rig)).contains(Self.offer), "this iPhone's own, its rear here")
        let id = UUID()
        rig.store.merge([Event(id: id, startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                               thumbnailData: Self.thumbnail, secondaryCamera: "rear", cloudSyncState: .synced,
                               sourceDevice: "iPad", cloudRevision: 1, captureFailuresByCamera: frontFailed,
                               cloudMediaManifest: ["rear"])])
        let listed = try XCTUnwrap(rig.store.events.first { $0.id == id })
        XCTAssertTrue(try shownTexts(on: detail(listed, rig)).contains(Self.offer), "another device's, its rear not here yet")
        let rear = try stillFile()
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: true)
        }
        _ = Task { await rig.engine.downloadFullEvidence(for: id) }
        XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.secondaryMediaFilename != nil }, timeout: 5),
                      "the rear lands, in its own slot")
        let held = try XCTUnwrap(rig.store.events.first { $0.id == id })
        XCTAssertNil(held.mediaFilename)
        XCTAssertFalse(try shownTexts(on: detail(held, rig)).contains(Self.offer), "a new visit, once the rear is here")
    }

    /// Control: a copy from a version before the list of uploaded media keeps the old rule, the offer standing while its
    /// first file is not here: what it holds in iCloud is unknown. Passes before and after the fix.
    func testACopyWithoutAListKeepsTheOldOffer() throws {
        let rig = makeRig()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let older = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                          thumbnailData: Self.thumbnail, cloudSyncState: .synced, sourceDevice: "iPad", cloudRevision: 1)
        XCTAssertTrue(try shownTexts(on: detail(older, rig)).contains(Self.offer), "nothing here")
        var rearHere = older
        rearHere.secondaryMediaFilename = "rear.jpg"
        rearHere.secondaryCamera = "rear"
        XCTAssertTrue(try shownTexts(on: detail(rearHere, rig)).contains(Self.offer), "its first file not here, as before")
    }

    // MARK: - codex-7 on 073e5d2: another camera's file standing in for a missing one

    /// codex-7 on 073e5d2: the offer counted the names a record lists against the files here, not which files they are.
    /// Another device's copy that holds only its rear, merged with a later revision that lists only its front (its maker
    /// re-uploaded after its storage limit removed both files and a download brought the front back), looked whole: one
    /// name, one file. A new visit offered no download, though the front was in iCloud. Each name is now matched to the
    /// file it stands for.
    func testAFileARecordNamesIsNotStoodInForByAnotherCamerasFile() throws {
        let rig = makeRig()
        let id = UUID()
        rig.store.merge([bothCamerasFromAnotherDevice(id)])   // revision 1: front and rear listed
        let rear = try stillFile()
        rig.engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "rear", camera: "rear", fileURL: rear)],
                                            complete: false)   // the front's fetch failed
        }
        _ = Task { await rig.engine.downloadFullEvidence(for: id) }
        XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.secondaryMediaFilename != nil }, timeout: 5),
                      "the rear lands")
        var later = bothCamerasFromAnotherDevice(id)
        later.cloudRevision = 2
        later.cloudMediaManifest = ["front"]   // a copy listing only its front, as a maker before deepseek-1's fix wrote it
        rig.store.merge([later])
        let merged = try XCTUnwrap(rig.store.events.first { $0.id == id })
        XCTAssertEqual(merged.cloudMediaManifest, ["front"], "the later revision's list")
        XCTAssertNotNil(merged.secondaryMediaFilename, "the rear downloaded here is kept")
        XCTAssertNil(merged.mediaFilename, "the front is not here")
        XCTAssertTrue(try shownTexts(on: detail(merged, rig)).contains(Self.offer), "a new visit offers the download, for the front")
        let front = try stillFile()
        var asked: [String]?
        rig.engine.fullMediaFetchForTesting = { _, names in
            asked = names
            return CloudExfiltrator.FullMediaFetch(
                media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)], complete: true)
        }
        _ = Task { await rig.engine.downloadFullEvidence(for: id) }
        XCTAssertTrue(pump(until: { rig.store.events.first { $0.id == id }?.mediaFilename != nil }, timeout: 5),
                      "the front lands, in its own slot")
        XCTAssertEqual(asked, ["front"], "the download asked iCloud for the names the merged list gives")
        let whole = try XCTUnwrap(rig.store.events.first { $0.id == id })
        XCTAssertFalse(try shownTexts(on: detail(whole, rig)).contains(Self.offer), "and the offer goes")
    }

    /// deepseek-1 on ce4c949, the list itself: it named only the files its maker held when it uploaded (codex-7's
    /// premise), so after the storage limit removed both files and a download brought the front back, the list iCloud
    /// got was the front's alone, though the rear had landed. It now also names what this phone knows landed, each name
    /// once; a file that never landed and is not held is still not named.
    func testARecordsListOfMediaNamesWhatLandedAsWellAsWhatIsHeld() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var partly = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                           mediaFilename: "front.jpg", thumbnailData: Self.thumbnail, primaryCamera: "front",
                           secondaryCamera: "rear", cloudSyncState: .pending)
        partly.uploadedMedia = ["front", "rear"]   // both landed before the limit took them
        XCTAssertEqual(partly.mediaManifest, ["front", "rear"])
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(partly.metadataJSON)) as? [String: Any])
        XCTAssertEqual(payload["media"] as? [String], ["front", "rear"], "the list iCloud gets")
        partly.uploadedMedia = ["front"]   // the rear never landed
        XCTAssertEqual(partly.mediaManifest, ["front"], "a file that never landed and is not held is not named")
    }

    /// deepseek-1 on ce4c949, the real path: a two-camera capture uploads in full (both files land), the storage limit
    /// removes both files, a download brings the front back (the rear's fetch fails), and the record this phone pushes
    /// next, as another device reads it, listed the front alone, so that device, or this one reinstalled, could never
    /// ask iCloud for the rear. It now lists both.
    func testACaptureTheLimitTrimmedAndPartlyBroughtBackStillListsWhatLanded() async throws {
        let (engine, cloud, store, capture) = try await twoCameraCaptureReadyToUpload()
        cloud.saveAttemptForTesting = { _ in }   // every record lands
        defer { cloud.saveAttemptForTesting = nil }
        await engine.uploadSnapshotForTesting(capture, throughSweep: false)
        let uploaded = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertEqual(Set(uploaded.uploadedMedia ?? []), ["front", "rear"], "both files landed")
        try await runTheByteLimit(on: store)
        XCTAssertNil(store.events.first { $0.id == capture.id }?.mediaFilename, "the limit took the files")
        store.mediaBudgetForTesting = nil
        let front = try stillFile()
        engine.fullMediaFetchForTesting = { _, _ in
            CloudExfiltrator.FullMediaFetch(media: [CloudExfiltrator.FetchedMedia(slot: "front", camera: "front", fileURL: front)],
                                            complete: false)   // the rear's fetch failed
        }
        defer { engine.fullMediaFetchForTesting = nil }
        let download = await engine.downloadFullEvidence(for: capture.id)
        XCTAssertTrue(download.landed, "the front comes back")
        let partly = try XCTUnwrap(store.events.first { $0.id == capture.id })
        XCTAssertNotNil(partly.mediaFilename)
        XCTAssertNil(partly.secondaryMediaFilename, "the rear does not")
        let copy = try XCTUnwrap(CloudExfiltrator.event(from:
            CloudExfiltrator.makeMetaRecord(partly, deviceName: "Desk phone", thumbnailURL: nil)))
        XCTAssertEqual(Set(copy.downloadManifest ?? []), ["front", "rear"],
                       "another device's download asks for the rear too, still in iCloud")
    }

    /// An engine whose uploads reach the save seam through every real step (the lease, the binding, the per-event queue,
    /// each record), and its store, with a two-camera capture on disk, registered and logged (item 166's rig).
    private func twoCameraCaptureReadyToUpload() async throws -> (engine: MonitoringEngine, cloud: CloudExfiltrator,
                                                                  store: EventStore, capture: Event) {
        let root = try XCTUnwrap(EventStore.rootOverrideForTesting)
        let enrollment = CloudEnrollment(file: root.appendingPathComponent("grant/state.json"), authenticate: { _ in true })
        let verified = await enrollment.enroll(account: "account-a", resolve: { "account-a" })
        XCTAssertTrue(verified, "a verified installation")
        let store = EventStore()
        let settings = AppSettings()
        settings.requireGuidedAccess = false
        let cloud = CloudExfiltrator(enrollment: enrollment)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: FakeCamera(), entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        engine.simulateConnectivityForTesting(online: true)
        try? await Task.sleep(for: .milliseconds(200))   // the launch sweep finds no identity and ends
        cloud.accountIdentityForTesting = { "account-a" }
        var capture = Event(startDate: Date().addingTimeInterval(-60), endDate: Date().addingTimeInterval(-59),
                            triggeredSensors: [.motion], cloudSyncState: .pending)
        capture.mediaFilename = UUID().uuidString + ".jpg"
        capture.primaryCamera = "front"
        capture.secondaryMediaFilename = UUID().uuidString + ".jpg"
        capture.secondaryCamera = "rear"
        capture.thumbnailData = Data([0xff, 0xd8, 0xff])
        try FileManager.default.createDirectory(at: store.mediaDirectory, withIntermediateDirectories: true)
        for name in [capture.mediaFilename, capture.secondaryMediaFilename].compactMap({ $0 }) {
            try Data(count: 100).write(to: store.mediaDirectory.appendingPathComponent(name))
        }
        enrollment.registerLocalEvent(capture)
        store.add(capture)
        return (engine, cloud, store, capture)
    }

    /// The byte limit run with a budget the capture's two files exceed: the next record's add starts its pass.
    private func runTheByteLimit(on store: EventStore) async throws {
        store.mediaBudgetForTesting = 10
        let now = Date()
        store.add(Event(startDate: now, endDate: now, triggeredSensors: [.touch]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !store.byteCapPruneIdleForTesting, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(store.byteCapPruneIdleForTesting, "the limit's pass ran")
        store.drainIOForTesting()
    }

    /// Control: a record holds two files at most, so with both its slots full no download can add one, whatever its list
    /// names (here a camera neither slot is labelled with). Passes before and after the fix; red with the fix's bound
    /// taken out (the undo check).
    func testARecordWithBothItsFilesHereOffersNothingMore() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let full = Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion],
                         mediaFilename: "first.jpg", secondaryMediaFilename: "rear.jpg", secondaryCamera: "rear",
                         cloudSyncState: .synced, sourceDevice: "iPad", cloudRevision: 1, cloudMediaManifest: ["front", "rear"])
        XCTAssertFalse(try shownTexts(on: detail(full, makeRig())).contains(Self.offer))
    }

    // MARK: - A3 (codex-3 on b7221cb): a siren start that fails without throwing

    /// item 167's A3: `AVAudioPlayer.play()` answers false for a start that failed without throwing, and the siren took
    /// it as started: no retry, and the owner's notice that it could not sound was cleared rather than raised.
    func testASirenStartThatFailsWithoutThrowingIsRetried() {
        let siren = SirenPlayer()
        siren.playFailuresForTesting = 1   // the first start answers false
        siren.start()
        defer { siren.stop() }
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 3), "retried, and sounding")
    }

    /// item 167's A3: a siren whose every start answers false uses up its attempts and is noted for the owner's notice.
    func testASirenThatNeverStartsIsNotedForTheOwner() {
        let siren = SirenPlayer()
        siren.playFailuresForTesting = 100
        siren.start()
        defer { siren.stop() }
        XCTAssertTrue(pump(until: { siren.activationExhausted }, timeout: 5), "noted, for the owner's notice")
        XCTAssertFalse(siren.isPlaying, "and silent")
    }

    // MARK: - codex-6 on 0920241: a refused start's audio session

    /// codex-6 on 0920241: a refused start throws before a player is kept, and the siren's stop released the audio
    /// session only through a player. After an alert whose every start was refused, the session stayed active, other
    /// apps' sound lowered (`.duckOthers`), while the watch went on; with Sound and the camera off nothing else releases
    /// it. The alert's own end now does.
    func testARefusedSirenReleasesItsAudioSessionWhenTheAlertEnds() {
        var timing = EngineCharacterizationTests.fastTiming
        timing.alertDuration = 3   // past the six attempts' 2 s
        let rig = makeRig(timing: timing) {
            $0.responseMode = .siren; $0.sirenRampUp = false
            $0.enabledSensors.remove(.audio); $0.enabledSensors.remove(.camera)
        }
        arm(rig)
        rig.engine.siren.playFailuresForTesting = 100   // every start refused
        rig.engine.handleTrip(.motion)
        XCTAssertTrue(pump(until: { rig.engine.alertActive }, timeout: 3), "the alert starts")
        XCTAssertTrue(pump(until: { !rig.engine.alertActive }, timeout: 8), "and ends")
        XCTAssertEqual(rig.engine.state, .armed, "the watch goes on")
        XCTAssertEqual(rig.engine.siren.sessionReleasesForTesting, 1, "the siren's audio session is released")
        rig.engine.disarm()
    }

    /// codex-6 on 0920241: a stop while a refused start's retry waits releases the session, once, and a later start that
    /// sounds is not undone by the stopped request.
    func testAStopDuringARefusedStartsRetryReleasesTheSessionAndSparesALaterStart() {
        let siren = SirenPlayer()
        siren.playFailuresForTesting = 1
        siren.start()   // refused; its retry waits 0.4 s
        siren.stop()
        XCTAssertEqual(siren.sessionReleasesForTesting, 1, "the refused start's session is released")
        siren.stop()
        XCTAssertEqual(siren.sessionReleasesForTesting, 1, "once")
        siren.start()   // a newer request, which sounds
        defer { siren.stop() }
        XCTAssertTrue(pump(until: { siren.isPlaying }, timeout: 2), "the newer request sounds")
        settle(0.6)   // the stopped request's retry has had its turn
        XCTAssertTrue(siren.isPlaying, "and still does")
        XCTAssertEqual(siren.sessionReleasesForTesting, 1, "nothing released its session")
    }

    // MARK: - Rig

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let entitlements: ProEntitlements
        let settings: AppSettings
    }

    private func makeRig(timing: EngineTiming = EngineCharacterizationTests.fastTiming,
                         _ configure: (AppSettings) -> Void = { _ in }) -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        configure(settings)
        let camera = FakeCamera()
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera, entitlements: entitlements, timing: timing))
        return Rig(engine: engine, camera: camera, store: store, entitlements: entitlements, settings: settings)
    }

    /// The real armed screen, live in a window of `size` (at the origin, safe areas ignored) for as long as `body`
    /// runs, so a test sees what it shows as the engine moves: the recorder holds what is on screen now, and where.
    private func withArmedScreen(_ rig: Rig, size: CGSize = CGSize(width: 402, height: 874),
                                 textSize: DynamicTypeSize = .large,
                                 _ body: (OnScreenRecorder) throws -> Void) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let recorder = OnScreenRecorder()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let screen = ArmedView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(CameraController())
            .environment(\.dynamicTypeSize, textSize)
            .environment(\.onScreenRecorder, recorder)
        let controller = UIHostingController(rootView: screen)
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        settle(0.3)
        try body(recorder)
    }

    /// Arms through grace (0 s), calibration and its review, to `.armed`.
    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "armed", file: file, line: line)
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

    private func settle(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private func detail(_ event: Event, _ rig: Rig) -> some View {
        NavigationStack { EventDetailView(event: event) }
            .environmentObject(rig.store)
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
    }

    /// The texts the reporting views of `view` show when it is laid out on a 17 Pro (item 82's pattern), read before
    /// the window closes.
    private func shownTexts<V: View>(on view: V) throws -> [String] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let recorder = OnScreenRecorder()
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let controller = UIHostingController(rootView: view.environment(\.onScreenRecorder, recorder))
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        controller.view.layoutIfNeeded()
        return recorder.shown
    }
}
