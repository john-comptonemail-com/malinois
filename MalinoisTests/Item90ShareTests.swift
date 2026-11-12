//
//  Item90ShareTests.swift
//  MalinoisTests
//
//  BACKLOG item 90, phase 4: Share with the evidence bundle (the owner's rulings of 2026-10-31; ADR 0067). The sheet
//  opens at once with the sentence and the media still on the phone, as before, and, for a record this phone signed, the
//  bundle as one more item: made only when the owner picks where to send it, so a share cancelled spends no signature;
//  made once however often it is asked for; removed once the sheet is gone, and none made after. A bundle that cannot be
//  made is left out. The launch hands the exporter the signer and the media folder, and clears the bundles a share left
//  behind. Written before the code, red at that commit (against compile-only stubs). The device check's diagnostic of
//  2026-10-31 added two, red before their fix: iOS asks a sheet's items as soon as it opens, so only the sheet's
//  operation for a destination picked makes the bundle, and Copy takes none; and the first sheet a screen opened never
//  carried the bundle, so the screen is laid out for real and Share pressed.
//

import SwiftUI
import Synchronization
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item90ShareTests: XCTestCase {

    nonisolated private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Item90Share-\(UUID().uuidString)")
    private var file: EvidenceSignatureFile { EvidenceSignatureFile(url: folder.appendingPathComponent(EvidenceSignatureFile.name)) }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: - The bundle as an item of the sheet

    func testTheBundleIsMadeOnceWhenADestinationIsPickedAndRemovedWhenTheShareIsOver() throws {
        let made = Counter()
        let placeholder = folder.appendingPathComponent("Malinois evidence 2026-10-31 0926.zip")
        let item = EvidenceBundleItem(placeholder: placeholder) { [folder] in
            made.add()
            return try? standInBundle(in: folder)
        }
        XCTAssertEqual(item.placeholderItem as? URL, placeholder, "the sheet sees a file to come")
        XCTAssertEqual(made.count, 0, "nothing made while the sheet only opens")
        let zip = try XCTUnwrap(item.item as? URL, "made once a destination is picked")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(item.item as? URL, zip)
        XCTAssertEqual(item.activityViewController(sheet(), itemForActivityType: .mail) as? URL, zip)
        XCTAssertEqual(made.count, 1, "made once")
        item.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.deletingLastPathComponent().path), "its folder removed")
        XCTAssertNil(item.madeBundle(), "none after the share is over")
        XCTAssertEqual(made.count, 1)
    }

    func testABundleThatCannotBeMadeIsLeftOutAndTheRestGoesAsBefore() {
        let placeholder = folder.appendingPathComponent("Malinois evidence 2026-10-31 0926.zip")
        let item = EvidenceBundleItem(placeholder: placeholder) { nil }
        XCTAssertEqual(item.item as? URL, placeholder, "the item the sheet's operation must have: its placeholder")
        XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: .airDrop), "left out")
        item.finish()
    }

    func testAShareCancelledMakesNothingAndSpendsNoSignature() {
        let made = Counter()
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) {
            made.add()
            return nil
        }
        item.finish()   // the sheet closed with no destination picked
        XCTAssertNil(item.madeBundle())
        XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: .mail))
        XCTAssertEqual(made.count, 0)
    }

    /// Regression, from the device check of 2026-10-31: iOS asks every item once any destination is picked, Save Video
    /// among them, which keeps only the clip; the bundle was made for it all the same, a signature spent on a ZIP thrown
    /// away. Copy too, since the diagnostic's round: a ZIP on the clipboard is of little use.
    func testADestinationThatTakesNoFileGetsNoBundleAndSpendsNoSignature() throws {
        let made = Counter()
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) { [folder] in
            made.add()
            return try? standInBundle(in: folder)
        }
        let withoutFiles: [UIActivity.ActivityType] = [.saveToCameraRoll, .print, .assignToContact, .copyToPasteboard]
        for destination in withoutFiles {
            XCTAssertNil(item.madeBundle(for: destination), "the sheet's operation, for \(destination.rawValue)")
            XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: destination), destination.rawValue)
        }
        XCTAssertEqual(made.count, 0, "Save Image or Save Video, Print, Assign to Contact, Copy: no bundle made")
        let zip = try XCTUnwrap(item.madeBundle(for: .airDrop), "AirDrop takes it")
        XCTAssertEqual(item.activityViewController(sheet(), itemForActivityType: .airDrop) as? URL, zip)
        XCTAssertEqual(item.madeBundle(for: nil), zip, "a destination iOS does not name (Save to Files, another app's)")
        for destination in withoutFiles {
            XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: destination), "\(destination.rawValue), made")
        }
        XCTAssertEqual(made.count, 1)
        item.finish()
    }

    /// Regression, from the device check's diagnostic of 2026-10-31: iOS asks a sheet's items as soon as it opens, on
    /// the main thread and before any destination is picked (Copy's, on the phone); that ask made the bundle, a signature
    /// spent on every sheet left standing, with the main thread held while it was made. Only the sheet's operation, once
    /// a destination is picked, makes it; the sheet's own asks get a bundle already made, or nothing.
    func testTheSheetsOwnAskMakesNoBundle() throws {
        let made = Counter()
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) { [folder] in
            made.add()
            return try? standInBundle(in: folder)
        }
        for destination: UIActivity.ActivityType? in [.airDrop, .mail, nil] {
            XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: destination), destination?.rawValue ?? "none named")
        }
        XCTAssertEqual(made.count, 0, "nothing made before the sheet's operation runs")
        let zip = try XCTUnwrap(item.madeBundle(for: .mail), "Mail picked: the sheet's operation makes it")
        XCTAssertEqual(item.activityViewController(sheet(), itemForActivityType: .mail) as? URL, zip, "then its ask gets it")
        XCTAssertEqual(made.count, 1)
        item.finish()
    }

    /// Item 220's defect 1 (an outside reading of 1.11's public source; the owner, 2026-11-09: into 1.12): a making that
    /// does not end holds the share for its limit and no longer. The making signs through App Attest, whose calls have
    /// no deadline of their own, and the wait for it had none either: a call that never answered held the sheet's thread
    /// for good, and the main thread with it at the sheet's next ask. Past the limit the share goes on without the
    /// bundle, the event's screen is told so, and a bundle that arrives late is removed at once. Written before the fix,
    /// red at that commit against a limit the item did not yet keep. The stand-in's making ends when the test lets it,
    /// so nothing here rests on how fast the test's machine is; and by itself after a while, so the red run ends too.
    func testAMakingThatDoesNotEndHoldsTheShareForItsLimitOnly() async throws {
        let release = TestFlag(), ended = TestFlag(), madeLate = TestFlag()
        let late = folder.appendingPathComponent("late", isDirectory: true)
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip"), limit: 0.2) { [late] in
            let byItself = Date().addingTimeInterval(5)
            while !release.value, Date() < byItself { try? await Task.sleep(nanoseconds: 20_000_000) }
            let zip = try? standInBundle(in: late)
            madeLate.value = zip != nil
            ended.value = true
            return zip
        }
        // A destination picked: the sheet asks on a thread of its own.
        let asked: (bundle: URL?, makingHadEnded: Bool) = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let bundle = item.madeBundle(for: .airDrop)
                continuation.resume(returning: (bundle, ended.value))
            }
        }
        XCTAssertNil(asked.bundle, "no bundle for this share")
        XCTAssertFalse(asked.makingHadEnded, "the share went on at the limit, before the making ended")
        XCTAssertEqual(item.madeForTheDestination, false, "the event's screen says the share went without it")
        XCTAssertNil(item.activityViewController(sheet(), itemForActivityType: .airDrop), "and the sheet's own ask leaves it out")
        // The making ends now: the bundle that arrives after the limit is removed at once.
        release.value = true
        let deadline = Date().addingTimeInterval(5)
        while !ended.value, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(madeLate.value, "the stand-in made its bundle, after the limit")
        func left() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: late.path)) ?? [] }
        while !left().isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(left(), [], "the late bundle's folder is gone")
        item.finish()
    }

    /// The other order, which no test of the item can stage: the making ends just as the limit runs out, its bundle
    /// already here when the waiter gives up. Whichever of the two comes second removes the bundle, and it is no longer
    /// given. Of the holder alone; written with the fix, for its undo check.
    func testABundleIsRemovedByWhicheverOfTheMakingAndTheWaiterComesSecond() throws {
        // The waiter gave up first, as in the test above.
        let afterTheLimit = try standInBundle(in: folder.appendingPathComponent("after", isDirectory: true))
        let gaveUpFirst = EvidenceBundleItem.Made()
        gaveUpFirst.giveUp()
        gaveUpFirst.arrive(afterTheLimit)
        XCTAssertFalse(FileManager.default.fileExists(atPath: afterTheLimit.deletingLastPathComponent().path), "removed as it arrives")
        XCTAssertNil(gaveUpFirst.url)
        // The making first, by a moment.
        let justInTime = try standInBundle(in: folder.appendingPathComponent("before", isDirectory: true))
        let arrivedFirst = EvidenceBundleItem.Made()
        arrivedFirst.arrive(justInTime)
        XCTAssertEqual(arrivedFirst.url, justInTime, "kept while a waiter may still take it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: justInTime.path))
        arrivedFirst.giveUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: justInTime.deletingLastPathComponent().path), "removed when the waiter gives up")
        XCTAssertNil(arrivedFirst.url, "and no longer given")
    }

    /// An item waits a minute at most for its making unless a test gives it another limit. Share's own item is made
    /// without one: `testOnlyARecordThisPhoneSignedHasABundleToShare` reads the limit of the item Share offers.
    func testAnItemWaitsAMinuteAtMostUnlessATestSaysOtherwise() {
        XCTAssertEqual(EvidenceBundleItem.makingLimit, 60)
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) { nil }
        XCTAssertEqual(item.limit, EvidenceBundleItem.makingLimit)
    }

    func testTheItemMakesTheRealBundleOnlyOnceADestinationIsPicked() async throws {
        let (signer, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        let exporter = EvidenceExporter(signer: signer, mediaDirectory: folder, temporaryDirectory: folder.appendingPathComponent("tmp"))
        let item = EvidenceBundleItem(placeholder: folder.appendingPathComponent(EvidenceExporter.bundleName(for: record) + ".zip")) {
            try? await exporter.bundle(of: record, log: [record])
        }
        XCTAssertEqual(signatures(), 1, "only the record's, while the sheet only opens")
        // A destination picked: the sheet asks on a thread of its own.
        let asked = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: item.item as? URL) }
        }
        let zip = try XCTUnwrap(asked)
        XCTAssertEqual(zip.lastPathComponent, EvidenceExporter.bundleName(for: record) + ".zip")
        XCTAssertEqual(try Data(contentsOf: zip).prefix(2), Data("PK".utf8))
        XCTAssertEqual(signatures(), 2, "the export statement, signed then")
        item.finish()
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.deletingLastPathComponent().path))
    }

    // MARK: - Share on the event's screen, laid out for real

    /// Regression, from the device check's diagnostic of 2026-10-31: the first sheet Share opened on an event's screen
    /// was built from the screen as it was first drawn, before Share had the bundle ready, and never carried it; the
    /// sheets after it did. And iOS asks a sheet's items as soon as it opens. The screen laid out in a window and Share
    /// pressed twice: each sheet carries a bundle of its own, and neither, left standing, signs an export statement; a
    /// destination picked in the first (its operation run, as iOS would) signs one, and the bundle's folder goes with
    /// the sheet.
    func testOnTheScreenEachSheetCarriesTheBundleAndOneLeftStandingSignsNothing() async throws {
        TestIsolation.setUp(folderPrefix: "Item90ShareScreen")
        defer { TestIsolation.tearDown() }
        let (signer, _) = try makeSigner()
        await signer.certifyIfNeeded(records: [])
        let record = trip(1)
        await signer.logWritten(generation: 1, events: [record])
        let exporter = EvidenceExporter(signer: signer, mediaDirectory: folder, temporaryDirectory: folder.appendingPathComponent("tmp"))
        let settings = AppSettings()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let store = EventStore()
        store.add(record)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        let recorder = OnScreenRecorder()
        let screen = NavigationStack { EventDetailView(event: record) }
            .environmentObject(store).environmentObject(engine).environmentObject(entitlements)
            .environment(\.evidenceExporter, exporter).environment(\.onScreenRecorder, recorder)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: screen)
        window.rootViewController = host
        window.isHidden = false
        defer {
            host.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
        }
        try await waitUntil("Share on the screen") { recorder.actions["Share evidence"] != nil }
        var bundles: [EvidenceBundleItem] = []
        for sheet in 1...2 {
            // Pressed until a sheet opens: a press while the last one is still closing opens nothing.
            try await waitUntil("sheet \(sheet) open", pressing: recorder.actions["Share evidence"]) {
                recorder.shared.count == sheet && host.presentedViewController != nil
            }
            let bundle = try XCTUnwrap(recorder.shared[sheet - 1].last as? EvidenceBundleItem, "sheet \(sheet) carries the bundle")
            XCTAssertFalse(bundles.contains { $0 === bundle }, "sheet \(sheet), a bundle of its own")
            bundles.append(bundle)
            try await Task.sleep(for: .seconds(1))   // the asks iOS makes of a sheet as it opens
            XCTAssertEqual(signatures(), sheet, "sheet \(sheet), left standing: no export statement signed")
            if sheet == 1 {
                // AirDrop picked: the sheet's operation, on a thread of its own.
                let made = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async { continuation.resume(returning: bundle.madeBundle(for: .airDrop)) }
                }
                let zip = try XCTUnwrap(made)
                XCTAssertEqual(signatures(), 2, "the export statement, signed for the destination picked")
                host.dismiss(animated: false)
                try await waitUntil("sheet 1's bundle gone with it") {
                    !FileManager.default.fileExists(atPath: zip.deletingLastPathComponent().path)
                }
            } else {
                host.dismiss(animated: false)
            }
            try await waitUntil("sheet \(sheet) closed") { host.presentedViewController == nil }
        }
    }

    // MARK: - What Share sends

    func testShareSendsTheSentenceTheMediaStillOnThePhoneAndTheBundle() throws {
        let photo = folder.appendingPathComponent("photo.jpg")
        try Data("a photo".utf8).write(to: photo)
        let gone = folder.appendingPathComponent("clip.mov")   // removed by the storage cap
        let bundle = EvidenceBundleItem(placeholder: folder.appendingPathComponent("Malinois evidence.zip")) { nil }
        let items = EventDetailView.shareItems(sentence: "Motion detected", media: [photo, gone, nil], bundle: bundle)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.first as? String, "Motion detected")
        XCTAssertEqual(items.dropFirst().first as? URL, photo)
        XCTAssertTrue((items.last as? EvidenceBundleItem) === bundle, "the bundle last")
        let unsigned = EventDetailView.shareItems(sentence: "Motion detected", media: [photo], bundle: nil)
        XCTAssertEqual(unsigned.count, 2, "a record with no signature shares as before")
        XCTAssertEqual(unsigned.last as? URL, photo)
    }

    func testOnlyARecordThisPhoneSignedHasABundleToShare() async throws {
        let (signer, keys) = try makeSigner()
        let before = trip(1)
        var mirrored = trip(2)
        mirrored.sourceDevice = "Owner's iPad"
        let signed = trip(3)
        await signer.certifyIfNeeded(records: [before.id])   // in the log when the key was certified: never signed
        await signer.logWritten(generation: 1, events: [signed, mirrored, before])
        let beforeAnswer = await signer.hasSignature(of: before.id)
        let mirroredAnswer = await signer.hasSignature(of: mirrored.id)
        let signedAnswer = await signer.hasSignature(of: signed.id)
        XCTAssertEqual([beforeAnswer, mirroredAnswer, signedAnswer], [false, false, true])
        // The app's next launch, before the log's first write: from the file.
        let relaunched = EvidenceSigner(file: file, keys: keys, mediaDirectory: folder, app: "1.10 (81)", retryAfter: 0)
        let afterRelaunch = await relaunched.hasSignature(of: signed.id)
        XCTAssertTrue(afterRelaunch)
        // What Share offers: a bundle for the signed record only, and none without an exporter (a test's screen).
        let log = [signed, mirrored, before]
        let exporter = EvidenceExporter(signer: signer, mediaDirectory: folder, temporaryDirectory: folder)
        let offered = await EvidenceBundleItem.forShare(of: signed, log: log, exporter: exporter)
        XCTAssertEqual(offered?.placeholderItem as? URL, folder.appendingPathComponent(EvidenceExporter.bundleName(for: signed) + ".zip"))
        XCTAssertEqual(offered?.limit, EvidenceBundleItem.makingLimit, "and it waits for its making a minute at most (item 220's defect 1)")
        let forBefore = await EvidenceBundleItem.forShare(of: before, log: log, exporter: exporter)
        let forMirrored = await EvidenceBundleItem.forShare(of: mirrored, log: log, exporter: exporter)
        let withoutExporter = await EvidenceBundleItem.forShare(of: signed, log: log, exporter: nil)
        XCTAssertNil(forBefore)
        XCTAssertNil(forMirrored)
        XCTAssertNil(withoutExporter)
    }

    // MARK: - The launch

    func testTheLaunchHandsTheExporterTheSignerAndTheMediaFolder() {
        TestIsolation.setUp(folderPrefix: "Item90ShareLaunch")
        defer { TestIsolation.tearDown() }
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        XCTAssertTrue(services.evidenceExporter.signer === services.evidenceSigning.signer, "the signer that signs the log")
        XCTAssertEqual(services.evidenceExporter.mediaDirectory, services.eventStore.mediaDirectory)
        XCTAssertEqual(services.evidenceExporter.temporaryDirectory, FileManager.default.temporaryDirectory)
        withExtendedLifetime(services.evidenceSigning) {}
    }

    func testTheLaunchClearsTheBundlesAShareLeftBehind() throws {
        let manager = FileManager.default
        let left = folder.appendingPathComponent("MalinoisExport-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: left, withIntermediateDirectories: true)
        try Data("PK".utf8).write(to: left.appendingPathComponent("Malinois evidence.zip"))
        // Not a bundle's: another name, a bundle's name without a UUID, a UUID after another name of the same length.
        let decoy = "Malinois-Clips-\(UUID().uuidString)"
        for kept in ["SomethingElse", "MalinoisExport-notes", decoy] {
            try manager.createDirectory(at: folder.appendingPathComponent(kept), withIntermediateDirectories: true)
        }
        EvidenceExporter.removeLeftovers(in: folder)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: folder.path).sorted(), [decoy, "MalinoisExport-notes", "SomethingElse"].sorted(),
                       "only the folders bundles are made in")
    }

    func testTheLaunchItselfClearsWhatAShareLeftInTheTemporaryFolder() async throws {
        TestIsolation.setUp(folderPrefix: "Item90ShareSweep")
        defer { TestIsolation.tearDown() }
        let left = FileManager.default.temporaryDirectory.appendingPathComponent("MalinoisExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        let services = MalinoisApp.makeServices(settings: AppSettings(), entitlements: ProEntitlements(resolvedAs: .free),
                                                relaySend: { _ in })
        var waited = 0
        while FileManager.default.fileExists(atPath: left.path), waited < 1_000 {   // the sweep runs in the background
            waited += 1
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "cleared at launch, within 10 seconds")
        withExtendedLifetime(services.evidenceSigning) {}
    }

    // MARK: - Helpers

    private func makeSigner() throws -> (EvidenceSigner, FakeKeyService) {
        let keys = FakeKeyService(chain: try TestAttestationChain())
        return (EvidenceSigner(file: file, keys: keys, mediaDirectory: folder, app: "1.10 (81)", retryAfter: 0), keys)
    }

    private func trip(_ minute: Int) -> Event {
        let start = TestApp.date(2026, 10, 31, 1, minute)
        return Event(startDate: start, endDate: start.addingTimeInterval(5), triggeredSensors: [.motion], motionTrace: [0.5, 1.5])
    }

    private func sheet() -> UIActivityViewController { UIActivityViewController(activityItems: [], applicationActivities: nil) }

    private func signatures() -> Int? { file.read()?.filter { $0.kind == .signature }.count }

    /// Lets the main run loop turn until `condition` holds, pressing `button`, when given, every half second meanwhile;
    /// stops the test after `timeout`.
    private func waitUntil(_ what: String, pressing button: (@MainActor () -> Void)? = nil, timeout: Duration = .seconds(10),
                           _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var nextPress = clock.now
        while !condition() {
            guard clock.now < deadline else { throw TimedOut(what: what) }
            if let button, clock.now >= nextPress {
                button()
                nextPress = clock.now.advanced(by: .milliseconds(500))
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private struct TimedOut: Error {
    let what: String
}

/// Counts calls from any thread.
private final class Counter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func add() { value.withLock { $0 += 1 } }
}

/// A stand-in for a bundle: a ZIP-named file in a folder of its own, as the exporter makes them. Off the main actor: the
/// item makes its bundle while the thread that asked waits.
private func standInBundle(in folder: URL) throws -> URL {
    let place = folder.appendingPathComponent("MalinoisExport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
    let zip = place.appendingPathComponent("Malinois evidence.zip")
    try Data("PK".utf8).write(to: zip)
    return zip
}
