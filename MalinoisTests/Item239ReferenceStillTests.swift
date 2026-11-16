//
//  Item239ReferenceStillTests.swift
//  MalinoisTests
//
//  BACKLOG item 239 (1.13, item 240's list; ADR 0081; the owner, 2026-11-12: "D1-D3 and V1-V3 (a), wording approved"):
//  a slow Vision trip saves the view the slow check compared against. Each time Vision sets its reference, the camera's
//  next frame becomes a colour JPEG in memory; a slow trip's event is born naming it, and the store saves it; a quick
//  trip gets none; the disarm and a calibration drop it; it never goes to iCloud; the event's screen shows it with the
//  approved words. Its storage, signing and export are Item239StillStorageTests; the Mac verifiers', Item239VerifierTests.
//  Written before the code, red at that commit (against stubs that keep the old behaviour).
//

import CoreVideo
import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item239ReferenceStillTests: XCTestCase {

    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "MalinoisItem239")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    // MARK: - Vision asks for a still at each reference, and keeps only its own

    func testEachReferenceAsksForAStillAndKeepsOnlyItsOwn() throws {
        let asked = Asked()
        let (vision, first) = try watching(asked)
        // After a trip's response the reference is the view now: a new still is asked for, the one before goes.
        vision.rearmAndRebaseline()
        XCTAssertEqual(asked.numbers.count, 2, "the new reference asks for its own still")
        let second = try XCTUnwrap(asked.numbers.last)
        XCTAssertNotEqual(second, first.generation)
        XCTAssertNil(vision.referenceStill, "the earlier reference's still went with it")
        vision.ingest(Self.scene, still: Self.still(first.generation))   // late, for the earlier reference
        XCTAssertNil(vision.referenceStill, "a still of an earlier reference is refused")
        let current = Self.still(second)
        vision.ingest(Self.scene, still: current)
        XCTAssertEqual(vision.referenceStill, current, "the current reference's own still is kept")
    }

    /// Every way the detector sets its reference asks for a still: the calibration (above), the first frame when there
    /// is none, the end of a pause around a capture, a gap in the frames and the settle frames after them.
    func testEveryWayTheReferenceIsSetAsksForAStill() throws {
        let asked = Asked()
        let clock = SteadyClock()
        let vision = VisionMonitor()
        vision.uptimeForTesting = { clock.now }
        vision.onReferenceStillWanted = { asked.numbers.append($0) }
        vision.beginCalibration()
        vision.endCalibration()   // no frame came: no reference yet, and no still asked for
        XCTAssertEqual(asked.numbers, [], "no reference, no still")
        vision.start()
        vision.ingest(Self.scene)   // the first frame becomes the reference
        XCTAssertEqual(asked.numbers.count, 1, "the first frame set the reference")
        vision.suppress(for: 1)
        clock.now += 2
        vision.ingest(Self.scene)   // the pause ends: re-anchored
        XCTAssertEqual(asked.numbers.count, 2, "the end of a pause set it")
        for _ in 0..<VisionMonitor.settleFrames { vision.ingest(Self.scene) }   // each settle frame re-anchors
        XCTAssertEqual(asked.numbers.count, 2 + VisionMonitor.settleFrames, "each settle frame set it")
        clock.now += VisionMonitor.frameGapForResettle + 1
        vision.ingest(Self.scene)   // after a gap in the frames
        XCTAssertEqual(asked.numbers.count, 3 + VisionMonitor.settleFrames, "a gap set it")
        XCTAssertEqual(Set(asked.numbers).count, asked.numbers.count, "a new number each time")
    }

    func testTheDisarmAndACalibrationDropTheStill() throws {
        let asked = Asked()
        let (vision, held) = try watching(asked)
        vision.stop()   // the disarm
        XCTAssertNil(vision.referenceStill, "the disarm drops the still")
        vision.ingest(Self.scene, still: held)   // one the camera made before the disarm, delivered after it
        XCTAssertNil(vision.referenceStill, "and keeps none delivered late")
        let (again, _) = try watching(Asked())
        again.beginCalibration()
        XCTAssertNil(again.referenceStill, "a calibration drops it")
    }

    // MARK: - Only a slow trip keeps it for its event

    func testOnlyASlowTripKeepsTheStillForItsEvent() throws {
        let asked = Asked()
        let (vision, held) = try watching(asked)
        let trips = Asked()
        vision.onTrip = { _ in trips.numbers.append(1) }
        for step in 0..<120 where trips.numbers.isEmpty { vision.ingest(Self.dimmer(step / 2)) }   // a lamp turned up slowly
        XCTAssertEqual(trips.numbers.count, 1, "a slow change trips")
        XCTAssertEqual(vision.takeTripStill(), held, "a slow trip hands over the still of the reference it compared against")
        XCTAssertNil(vision.takeTripStill(), "once")

        let (quick, _) = try watching(Asked())
        let quickTrips = Asked()
        quick.onTrip = { _ in quickTrips.numbers.append(1) }
        quick.ingest(Self.handAcross)   // a sudden change
        XCTAssertEqual(quickTrips.numbers.count, 1, "a quick trip")
        XCTAssertNil(quick.takeTripStill(), "a quick trip keeps no still: its photo or clip shows the change")
    }

    /// A slow trip's still that no event took (its trip came during another capture, or in Test Sensors) goes with its
    /// reference, and with the disarm: no later event can take a still of a reference it did not compare against.
    func testATripsStillGoesWithItsReferenceAndWithTheDisarm() throws {
        let (vision, _) = try watching(Asked())
        try tripSlowly(vision)
        vision.rearmAndRebaseline()   // the view now becomes the reference
        XCTAssertNil(vision.takeTripStill(), "it went with its reference")
        let (other, _) = try watching(Asked())
        try tripSlowly(other)
        other.stop()
        XCTAssertNil(other.takeTripStill(), "the disarm drops it")
    }

    /// Only an event Vision tripped takes a still: one for other tripwires leaves it (`respond` asks for it only then).
    func testOnlyAnEventVisionTrippedTakesTheStill() {
        let held = Self.still(7)
        let taken = Asked()
        XCTAssertEqual(MonitoringTripResponder.visionReferenceStill(for: [.motion, .vision]) { taken.numbers.append(1); return held },
                       held)
        XCTAssertNil(MonitoringTripResponder.visionReferenceStill(for: [.motion, .touch]) { taken.numbers.append(2); return held })
        XCTAssertEqual(taken.numbers, [1], "not even asked for an event Vision did not trip")
    }

    // MARK: - The camera makes a still only when asked, with the frame it is of

    func testTheCameraMakesAStillOnlyWhenAskedAndHandsItOverWithItsFrame() async throws {
        let camera = CameraController()
        let delivered = Delivered()
        camera.onVisionFrame = { frame, still in delivered.items.append((frame, still)) }
        let red = try pixelBuffer(y: 81, cb: 90, cr: 240)   // red, as the camera's video range writes it
        for _ in 0..<CameraController.visionDecimation { camera.processVisionFrameForTesting(red) }
        let first = await eventually { delivered.items.count == 1 }
        XCTAssertTrue(first, "a frame handed over")
        XCTAssertNil(delivered.items.last?.1, "no still asked for: none made")

        camera.requestVisionStill(generation: 7)
        camera.requestVisionStill(generation: 8)   // a newer reference before the next frame: its still alone
        for _ in 0..<CameraController.visionDecimation { camera.processVisionFrameForTesting(red) }
        let second = await eventually { delivered.items.count == 2 }
        XCTAssertTrue(second)
        let still = try XCTUnwrap(delivered.items.last?.1, "the still asked for, in the same hand-over as its frame")
        XCTAssertEqual(still.generation, 8)
        let made = try decoded(still.jpeg)
        XCTAssertLessThanOrEqual(max(made.width, made.height), 640, "at most 640 pixels on its long side")
        XCTAssertGreaterThanOrEqual(max(made.width, made.height), 600, "not smaller than it needs to be")
        XCTAssertGreaterThan(made.red, made.green + 60, "in colour: \(made)")
        XCTAssertGreaterThan(made.red, made.blue + 60, "in colour: \(made)")

        for _ in 0..<CameraController.visionDecimation { camera.processVisionFrameForTesting(red) }
        let third = await eventually { delivered.items.count == 3 }
        XCTAssertTrue(third)
        XCTAssertNil(delivered.items.last?.1, "one still for each time one is asked for")
    }

    /// The still shows the view as the camera's photos do: turned by the photo connection's turn, less the tap's own.
    func testTheStillIsTurnedAsThePhotosAre() throws {
        let cases: [(CGFloat, Bool, CGImagePropertyOrientation)] = [
            (0, false, .up), (90, false, .right), (180, false, .down), (270, false, .left),
            (0, true, .upMirrored), (90, true, .leftMirrored), (180, true, .downMirrored), (270, true, .rightMirrored),
        ]
        for (angle, mirrored, expected) in cases {
            XCTAssertEqual(CameraController.stillOrientation(photoAngle: angle, photoMirrored: mirrored, tapAngle: 0, tapMirrored: false),
                           expected, "\(angle) \(mirrored)")
        }
        XCTAssertEqual(CameraController.stillOrientation(photoAngle: 90, photoMirrored: false, tapAngle: 90, tapMirrored: false), .up,
                       "a tap already turned as the photos are")
        let frame = try pixelBuffer(y: 81, cb: 90, cr: 240)
        let upright = try decoded(try XCTUnwrap(CameraController.referenceStillJPEG(from: frame, orientation: .up)))
        XCTAssertEqual([upright.width, upright.height], [640, 360])
        let turned = try decoded(try XCTUnwrap(CameraController.referenceStillJPEG(from: frame, orientation: .right)))
        XCTAssertEqual([turned.width, turned.height], [360, 640], "turned in its pixels, as a portrait photo shows")
    }

    // MARK: - The armed session: a slow trip's event is born with it, and the store saves it

    func testASlowTripsEventNamesTheStillAndTheStoreSavesIt() throws {
        let rig = makeRig()
        arm(rig)
        let held = try referenceStill(rig)
        XCTAssertEqual(try mediaFiles(rig.store), [], "nothing is written while armed")
        for step in 0..<120 where !visionTripped(rig) { rig.camera.onVisionFrame?(Self.dimmer(step / 2), nil) }
        XCTAssertTrue(pump(until: { self.visionEvent(rig)?.endDate != self.visionEvent(rig)?.startDate }, timeout: 3),
                      "the slow trip's event and its capture")
        let event = try XCTUnwrap(visionEvent(rig))
        let name = try XCTUnwrap(event.visionReferenceFilename, "the event names the still")
        XCTAssertTrue(EventStore.isStoredMediaName(name), "under a name of the store's own form: \(name)")
        XCTAssertEqual(event.visionReferenceTakenAt, held.takenAt, "with the time the camera took it")
        rig.store.drainIOForTesting()
        XCTAssertEqual(try Data(contentsOf: rig.store.mediaDirectory.appendingPathComponent(name)), held.jpeg,
                       "and the store saved it under that name")
        XCTAssertNil(vision(rig)?.takeTripStill(), "the event took it")
    }

    func testAQuickTripsEventHasNoStill() throws {
        let rig = makeRig()
        arm(rig)
        _ = try referenceStill(rig)
        rig.camera.onVisionFrame?(Self.handAcross, nil)
        XCTAssertTrue(pump(until: { self.visionEvent(rig)?.mediaFilename != nil }, timeout: 5), "the quick trip's event and its photo")
        let event = try XCTUnwrap(visionEvent(rig))
        XCTAssertNil(event.visionReferenceFilename)
        XCTAssertNil(event.visionReferenceTakenAt)
        rig.store.drainIOForTesting()
        XCTAssertEqual(try mediaFiles(rig.store), [try XCTUnwrap(event.mediaFilename)], "its photo alone")
    }

    func testTheDisarmDropsTheStillInMemory() throws {
        let rig = makeRig()
        arm(rig)
        _ = try referenceStill(rig)
        rig.engine.disarm()
        XCTAssertTrue(pump(until: { rig.engine.state == .disarmed }, timeout: 2))
        XCTAssertNil(vision(rig)?.referenceStill, "the disarm drops it")
    }

    // MARK: - Never to iCloud

    func testTheStillNeverGoesToICloud() throws {
        var event = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.vision], primaryCamera: "front")
        event.mediaFilename = UUID().uuidString + ".jpg"
        let name = UUID().uuidString + ".jpg"
        event.visionReferenceFilename = name
        event.visionReferenceTakenAt = Date().addingTimeInterval(-600)
        let payload = try XCTUnwrap(event.metadataJSON)
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertFalse(text.contains(name), "the payload never names the still")
        XCTAssertFalse(text.contains("visionReference"), "nor carries its time")
        XCTAssertEqual(event.mediaManifest, ["front"], "the list of uploaded files has the photo alone")
    }

    // MARK: - The event's screen

    func testTheEventsScreenShowsTheStillWithTheApprovedWords() throws {
        let rig = makeScreenRig()
        let start = Date()
        let record = try recordWithStill(rig.store, start: start, takenAt: start.addingTimeInterval(-3 * 60))
        rig.store.add(record)
        rig.store.drainIOForTesting()
        let caption = EventDetailView.visionReferenceCaption(takenAt: start.addingTimeInterval(-3 * 60), eventStart: start)
        let shown = try shownOnScreen(screen(NavigationStack { EventDetailView(event: record) }, rig)).shown
        XCTAssertTrue(shown.contains(caption), "\(shown)")
        XCTAssertTrue(shown.contains(EventDetailView.visionReferenceExplanation), "\(shown)")
        // A set-aside log's copy of the record shows it too, from the same file.
        let aside = try shownOnScreen(screen(NavigationStack { EventDetailView(event: record, setAside: true) }, rig)).shown
        XCTAssertTrue(aside.contains(caption), "\(aside)")
        XCTAssertTrue(aside.contains(EventDetailView.visionReferenceExplanation), "\(aside)")
    }

    func testTheWordsAreTheApprovedOnes() throws {
        XCTAssertEqual(EventDetailView.visionReferenceExplanation,
                       "Vision tripped on a slow change: over a third of the view had changed since then.")
        // At noon, so that a minute earlier is the same day whenever the test runs.
        let start = try XCTUnwrap(Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()))
        let taken = start.addingTimeInterval(-60)
        XCTAssertEqual(EventDetailView.visionReferenceCaption(takenAt: taken, eventStart: start),
                       "The view at \(taken.formatted(date: .omitted, time: .shortened)), which Vision compared against")
        // From an earlier day than the event: the day too, or the time alone would name the wrong one.
        let yesterday = start.addingTimeInterval(-86_400)
        XCTAssertEqual(EventDetailView.visionReferenceCaption(takenAt: yesterday, eventStart: start),
                       "The view at \(yesterday.formatted(date: .abbreviated, time: .shortened)), which Vision compared against")
    }

    /// The control: with no still on the phone (none taken, or its file not there), the screen says nothing of one.
    func testWithoutTheFileTheScreenShowsNoStill() throws {
        let rig = makeScreenRig()
        let start = Date()
        var record = try recordWithStill(rig.store, start: start, takenAt: start.addingTimeInterval(-60))
        let name = try XCTUnwrap(record.visionReferenceFilename)
        try FileManager.default.removeItem(at: rig.store.mediaDirectory.appendingPathComponent(name))
        rig.store.add(record)
        rig.store.drainIOForTesting()
        let missing = try shownOnScreen(screen(NavigationStack { EventDetailView(event: record) }, rig)).shown
        XCTAssertFalse(missing.contains(EventDetailView.visionReferenceExplanation), "no file, no still: \(missing)")
        XCTAssertTrue(missing.contains(CloudSyncState.pending.displayName), "the screen is laid out: \(missing)")
        record = Event(startDate: start, endDate: start, triggeredSensors: [.vision])
        let none = try shownOnScreen(screen(NavigationStack { EventDetailView(event: record) }, rig)).shown
        XCTAssertFalse(none.contains(EventDetailView.visionReferenceExplanation), "\(none)")
    }

    // MARK: - Helpers

    /// What a closure collected, read on the main actor.
    final class Asked { var numbers: [Int] = [] }
    final class Delivered { var items: [(VisionFrame, VisionStill?)] = [] }
    final class SteadyClock { var now: TimeInterval = 1_000 }

    private static let size = VisionFrame.width * VisionFrame.height
    static let scene = VisionFrame(luma: [UInt8](repeating: 100, count: size))
    static let handAcross = VisionFrame(luma: (0..<size).map { $0 % VisionFrame.width < VisionFrame.width / 2 ? UInt8(20) : UInt8(220) })

    /// The scene with two-fifths of the view `delta` brighter: a lamp on a dimmer, turned up a step every other frame,
    /// slowly enough that the quick check adapts and only the slow one sees the change.
    static func dimmer(_ delta: Int) -> VisionFrame {
        VisionFrame(luma: (0..<size).map { $0 < size * 2 / 5 ? UInt8(100 + delta) : UInt8(100) })
    }

    static func still(_ generation: Int) -> VisionStill {
        VisionStill(generation: generation, jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, UInt8(generation & 0xFF), 0xFF, 0xD9]),
                    takenAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(generation)))
    }

    /// A Vision monitor calibrated on the scene and watching, holding the still of its reference.
    private func watching(_ asked: Asked) throws -> (VisionMonitor, VisionStill) {
        let vision = VisionMonitor()
        vision.onReferenceStillWanted = { asked.numbers.append($0) }
        vision.beginCalibration()
        vision.ingest(Self.scene)
        vision.endCalibration()
        vision.start()
        let generation = try XCTUnwrap(asked.numbers.last, "the calibration set the reference: a still is asked for")
        let still = Self.still(generation)
        vision.ingest(Self.scene, still: still)
        XCTAssertEqual(vision.referenceStill, still, "the reference's still, in memory")
        return (vision, still)
    }

    /// The lamp turned up slowly until Vision trips.
    private func tripSlowly(_ vision: VisionMonitor, file: StaticString = #filePath, line: UInt = #line) throws {
        let trips = Asked()
        vision.onTrip = { _ in trips.numbers.append(1) }
        for step in 0..<120 where trips.numbers.isEmpty { vision.ingest(Self.dimmer(step / 2)) }
        XCTAssertEqual(trips.numbers.count, 1, "a slow change trips", file: file, line: line)
    }

    private struct Rig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
    }

    /// An engine with Vision on and the camera kept warm, on Pro's trial, capturing a photo as the other engine tests do
    /// (a new install's three-second clip would outlast the tests' waits: chain d's green run, 2026-11-12).
    private func makeRig() -> Rig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.captureMode = .photo
        settings.cameraReadiness = .instant
        settings.enabledSensors.insert(.vision)
        let camera = FakeCamera()
        let store = EventStore()
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: camera, entitlements: ProEntitlements(resolvedAs: .trial),
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, camera: camera, store: store)
    }

    private func arm(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed }, timeout: 5), "armed", file: file, line: line)
    }

    private func vision(_ rig: Rig) -> VisionMonitor? { rig.engine.monitors[.vision] as? VisionMonitor }

    /// The armed session's first frame sets Vision's reference; the camera's next brings its still.
    private func referenceStill(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> VisionStill {
        rig.camera.onVisionFrame?(Self.scene, nil)
        let generation = try XCTUnwrap(rig.camera.visionStillRequests.last, "the engine asked the camera for a still",
                                       file: file, line: line)
        let still = Self.still(generation)
        rig.camera.onVisionFrame?(Self.scene, still)
        XCTAssertEqual(vision(rig)?.referenceStill, still, "Vision keeps it", file: file, line: line)
        return still
    }

    private func visionEvent(_ rig: Rig) -> Event? {
        rig.store.events.first { $0.triggeredSensors.contains(.vision) && !$0.isStateChange }
    }

    private func visionTripped(_ rig: Rig) -> Bool { visionEvent(rig) != nil || rig.engine.state == .triggered }

    private func mediaFiles(_ store: EventStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    @discardableResult
    private func pump(until condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return condition()
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private struct ScreenRig {
        let store: EventStore
        let engine: MonitoringEngine
        let entitlements: ProEntitlements
    }

    private func makeScreenRig() -> ScreenRig {
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .free)
        let engine = TestIsolation.track(MonitoringEngine(settings: AppSettings(), eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return ScreenRig(store: store, engine: engine, entitlements: entitlements)
    }

    private func screen<V: View>(_ view: V, _ rig: ScreenRig) -> some View {
        view.environmentObject(rig.store).environmentObject(rig.engine).environmentObject(rig.entitlements)
    }

    /// A slow trip's record naming its still, whose file is in the store's media folder.
    private func recordWithStill(_ store: EventStore, start: Date, takenAt: Date) throws -> Event {
        var record = Event(startDate: start, endDate: start, triggeredSensors: [.vision])
        let name = UUID().uuidString + ".jpg"
        record.visionReferenceFilename = name
        record.visionReferenceTakenAt = takenAt
        let jpeg = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 64, height: 36)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        }.jpegData(compressionQuality: 0.8))
        try jpeg.write(to: store.mediaDirectory.appendingPathComponent(name))
        return record
    }

    /// A frame of the camera's, 1920 by 1080 in its video-range format, of one colour.
    private func pixelBuffer(y: UInt8, cb: UInt8, cr: UInt8) throws -> CVPixelBuffer {
        var made: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         attributes, &made)
        XCTAssertEqual(status, kCVReturnSuccess)
        let buffer = try XCTUnwrap(made)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        memset(luma, Int32(y), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) * CVPixelBufferGetHeightOfPlane(buffer, 0))
        let chroma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
        let count = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1)
        for index in stride(from: 0, to: count - 1, by: 2) {
            chroma[index] = cb
            chroma[index + 1] = cr
        }
        return buffer
    }

    /// A JPEG's size, and its colour averaged over the whole picture.
    struct Decoded {
        let width: Int
        let height: Int
        let red: Int
        let green: Int
        let blue: Int
    }

    private func decoded(_ jpeg: Data) throws -> Decoded {
        let image = try XCTUnwrap(UIImage(data: jpeg)?.cgImage, "a JPEG")
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Decoded(width: image.width, height: image.height, red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }
}
