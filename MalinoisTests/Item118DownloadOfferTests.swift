//
//  Item118DownloadOfferTests.swift
//  MalinoisTests
//
//  BACKLOG 118 (1.8, BACKLOG 128 step 3): the event detail offered "Download full evidence from
//  iCloud" for any event with no photo or clip on this phone (not a status entry, on Pro, its media
//  not discarded), including where no iCloud copy can exist: nothing was captured (the camera could
//  not start, or the camera tripwire was off), or this iPhone's event never uploaded (no verified
//  account, iCloud backup off). A tap there ended with "Nothing came back". Seen on item 82's walk.
//  Written before the fix, red at that commit, where a compile-only stub says a copy may exist for
//  every event; the guards (a capture that did upload, from this iPhone or another device) pass
//  before and after.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item118DownloadOfferTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item118DownloadOfferTests")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let offer = "Download full evidence from iCloud"
    private static let thumbnail = Data([0xFF, 0xD8, 0xFF])

    // MARK: - The rule

    /// Nothing captured, nothing in iCloud: the camera could not start (the record's meta did upload,
    /// so it reads as synced), or the camera tripwire was off.
    func testNoCopyCanExistWhereNothingWasCaptured() {
        let failed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced,
                           captureFailure: CaptureFailureReason.cameraUnavailable.rawValue)
        XCTAssertFalse(failed.fullCaptureMayBeInICloud, "the camera could not start")
        let noCamera = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced)
        XCTAssertFalse(noCamera.fullCaptureMayBeInICloud, "the camera tripwire was off")
    }

    /// This iPhone's capture that never uploaded: still pending (held, no verified account), given up
    /// on, or kept on the phone with iCloud backup off.
    func testNoCopyCanExistForThisIPhonesCaptureThatNeverUploaded() {
        for state in [CloudSyncState.pending, .localOnly] {
            let held = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                             primaryCamera: "front", cloudSyncState: state)
            XCTAssertFalse(held.fullCaptureMayBeInICloud, "\(state)")
        }
        var kept = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                         primaryCamera: "front", cloudSyncState: .pending)
        kept.keptLocal = true
        XCTAssertFalse(kept.fullCaptureMayBeInICloud, "recorded with iCloud backup off")
    }

    /// Guard: where a copy can exist the offer stands, as before: this iPhone's uploaded capture whose
    /// photo the storage limit later removed from the phone, and another device's capture, known by its
    /// thumbnail or by the list of the media it uploaded.
    func testACopyCanExistForAnUploadedOrAnotherDevicesCapture() {
        let pruned = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                           primaryCamera: "front", cloudSyncState: .synced)
        XCTAssertTrue(pruned.fullCaptureMayBeInICloud, "uploaded, then removed from the phone by the storage limit")
        let mirrored = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                             cloudSyncState: .synced, sourceDevice: "iPad")
        XCTAssertTrue(mirrored.fullCaptureMayBeInICloud, "another device's capture")
        let listed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced,
                           sourceDevice: "iPad", cloudMediaManifest: ["front"])
        XCTAssertTrue(listed.fullCaptureMayBeInICloud, "another device's upload list")
    }

    // MARK: - The screen

    /// The event detail, as shown: no offer for a capture that never happened, or for this iPhone's
    /// capture that never uploaded.
    func testTheEventDetailOffersNoDownloadWhereNoCopyCanExist() throws {
        let rig = makeRig()
        let failed = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], cloudSyncState: .synced,
                           captureFailure: CaptureFailureReason.cameraUnavailable.rawValue)
        let held = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                         primaryCamera: "front", cloudSyncState: .localOnly)
        for event in [failed, held] {
            let shown = try shownTexts(on: detail(event, rig))
            XCTAssertFalse(shown.contains(Self.offer), "offered for \(event.cloudSyncState), thumbnail \(event.thumbnailData != nil)")
        }
    }

    /// Guard: the offer stands for this iPhone's uploaded capture no longer on the phone.
    func testTheEventDetailStillOffersTheDownloadForAnUploadedCapture() throws {
        let rig = makeRig()
        let pruned = Event(startDate: Date(), endDate: Date(), triggeredSensors: [.motion], thumbnailData: Self.thumbnail,
                           primaryCamera: "front", cloudSyncState: .synced)
        XCTAssertTrue(try shownTexts(on: detail(pruned, rig)).contains(Self.offer))
    }

    // MARK: - Rig

    private struct Rig {
        let engine: MonitoringEngine
        let store: EventStore
        let entitlements: ProEntitlements
    }

    private func makeRig() -> Rig {
        let settings = AppSettings()
        let store = EventStore()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        XCTAssertTrue(entitlements.proActive, "the offer is a Pro feature")
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: CloudExfiltrator(),
                                                          camera: FakeCamera(), entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return Rig(engine: engine, store: store, entitlements: entitlements)
    }

    private func detail(_ event: Event, _ rig: Rig) -> some View {
        NavigationStack { EventDetailView(event: event) }
            .environmentObject(rig.store)
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
    }

    /// The texts the reporting views of `view` show when it is laid out on a 17 Pro (item 82's
    /// pattern), read before the window closes.
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
