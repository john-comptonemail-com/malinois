//
//  Item82FoldableTests.swift
//  MalinoisTests
//
//  BACKLOG 82 (1.7, the foldable check): on the iPhone Duo simulator's outer display (about
//  387 × 678 points as the app sees it) the PIN setup's explanation and Home's notices were cut
//  off with "…", because neither screen scrolled and a stack squeezes its text to fit; Settings
//  offered the raw "iPhone19,4" as the device label; and item 82's fix 4 (the wordmark sized from
//  the whole screen, not its window) was still open. Written before the fixes, red at that commit.
//  The short screen here is the iPhone SE below its status bar (375 × 647), the smallest the app
//  supports: narrower and shorter than the Duo's outer display. A screen that does not scroll
//  squeezes the text that does not fit; the layout tests check that what does not fit now scrolls,
//  laid out at its full height (inside a scroll view SwiftUI gives text all the lines it needs).
//  SwiftUI offers no accessibility elements to a unit test, so the text's own height cannot be
//  read here; the simulator screenshots in the report show it. The three guards pass before and
//  after: on a tall phone Home and the PIN setup lay out as before, and the countdown, whose
//  helper Home and the PIN setup now share, still scrolls only when it must.
//

import SwiftUI
import UIKit
import XCTest
@testable import Malinois

@MainActor
final class Item82FoldableTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestIsolation.setUp(folderPrefix: "Item82FoldableTests")
    }

    override func tearDown() {
        TestIsolation.tearDown()
        super.tearDown()
    }

    private static let shortPhone = CGSize(width: 375, height: 647)   // iPhone SE, below the status bar
    private static let iPhone17Pro = CGSize(width: 402, height: 874)

    // MARK: - Home

    /// The walk: Home cut each notice to one line ending in "…" ("The camera session failed (The
    /// operation could not be…"). On a short screen, what sits between the wordmark and the buttons
    /// now scrolls at its full height, and the Event Log and Settings buttons stay on screen below it.
    /// The largest standard text size makes the middle certainly taller than the room, whichever
    /// iCloud notice the test host adds; large text cut the notices off the same way.
    func testHomeScrollsInsteadOfCuttingItsNoticesOnAShortScreen() throws {
        let rig = makeHomeRig()
        raiseTwoNotices(rig)
        let screen = home(rig).environment(\.dynamicTypeSize, .xxxLarge)
        let middle = try XCTUnwrap(try scrollers(of: screen, in: Self.shortPhone).first,
                                   "Home does not scroll, so it squeezes its notices to fit")
        XCTAssertGreaterThan(middle.contentHeight, middle.frame.height, "laid out at full height, taller than the room")
        XCTAssertLessThan(middle.frame.maxY, Self.shortPhone.height - 40,
                          "the Event Log and Settings buttons stay below it, on screen")
    }

    /// Guard: on a tall phone Home lays out as before, scrolling only if its content is taller than
    /// the room. Run alone, these two notices fit a 17 Pro; in the full suite an earlier test leaves
    /// the app-wide "settings were reset" flag on, and its notice makes a third, which does not fit.
    func testHomeScrollsOnATallPhoneOnlyWhenItsContentIsTallerThanTheRoom() throws {
        let rig = makeHomeRig()
        raiseTwoNotices(rig)
        for middle in try scrollers(of: home(rig), in: Self.iPhone17Pro) {
            XCTAssertGreaterThan(middle.contentHeight, middle.frame.height,
                                 "scrolls although its content fits: \(middle.contentHeight) in \(middle.frame.height)")
        }
    }

    // MARK: - PIN setup

    /// The walk: the PIN setup cut its explanation short, so "Use a code different from your iPhone
    /// passcode and your Guided Access passcode" was never read in full. On a short screen the setup
    /// now scrolls at its full height.
    func testPINSetupScrollsInsteadOfCuttingItsExplanationOnAShortScreen() throws {
        let setup = try XCTUnwrap(try scrollers(of: pinSetup(), in: Self.shortPhone).first,
                                  "the PIN setup does not scroll, so it squeezes its explanation to fit")
        XCTAssertGreaterThan(setup.contentHeight, setup.frame.height, "laid out at full height, taller than the room")
    }

    /// Guard: on a tall phone the PIN setup lays out as before, without scrolling.
    func testPINSetupDoesNotScrollOnATallPhone() throws {
        XCTAssertEqual(try scrollers(of: pinSetup(), in: Self.iPhone17Pro).count, 0)
    }

    // MARK: - The countdown (item 108's fix, now through the shared helper)

    /// Guard: the countdown has scrolled when it is taller than the screen since 1.6 (65), with no
    /// test until now; it now uses the helper Home and the PIN setup use. On a screen too short for
    /// it, it scrolls; on a 17 Pro it lays out as before, scrolling only if it must.
    func testTheCountdownScrollsOnlyWhenTallerThanTheScreen() throws {
        let rig = makeHomeRig { $0.gracePeriodSeconds = 60 }
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .arming }, timeout: 5), "counting down")
        let countdown = ArmingView()
            .environmentObject(rig.engine)
            .environmentObject(rig.entitlements)
            .environmentObject(rig.settings)
        let short = try XCTUnwrap(try scrollers(of: countdown, in: CGSize(width: 375, height: 420)).first,
                                  "the countdown does not scroll on a screen too short for it")
        XCTAssertGreaterThan(short.contentHeight, short.frame.height)
        for screen in try scrollers(of: countdown, in: Self.iPhone17Pro) {
            XCTAssertGreaterThan(screen.contentHeight, screen.frame.height, "scrolls although it fits a 17 Pro")
        }
        rig.engine.cancelArming()
    }

    // MARK: - The wordmark (item 82, fix 4)

    /// Its size came from the whole screen (`UIScreen.main`), so on the Duo's inner display it would
    /// grow with that screen. It now fills its container up to the width it has on the largest
    /// iPhone (92% of 440 points), whatever the screen.
    func testTheWordmarkIsSizedByItsContainerNotTheScreen() {
        func width(in container: CGFloat) -> CGFloat {
            UIHostingController(rootView: MalinoisLockup())
                .sizeThatFits(in: CGSize(width: container, height: 1_000)).width
        }
        XCTAssertEqual(width(in: 300), 300, accuracy: 0.5, "a narrow container: it fills it, as before")
        XCTAssertEqual(width(in: 1_000), 440 * 0.92, accuracy: 0.5,
                       "a wide container, as on the inner display: the largest iPhone's width")
    }

    // MARK: - Device names

    /// The walk: Settings offered "iPhone19,4" as the Duo's device label, because the model table
    /// stopped at the iPhone 17e. The 2026 iPhones in Xcode's device list now have their names, the
    /// 18 Pro Max under both its identifiers (Codex's sixth look, T1: iPhone19,7 was missed).
    func testThe2026IPhonesHaveTheirNames() {
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone19,4"), "iPhone Duo")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone19,2"), "iPhone 18 Pro")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone19,3"), "iPhone 18 Pro Max")
        XCTAssertEqual(DeviceInfo.marketingName(forIdentifier: "iPhone19,7"), "iPhone 18 Pro Max")
    }

    /// The table follows Xcode's own device list. This reads that list on the Mac running the tests,
    /// so a newer Xcode that adds an iPhone fails here, naming what to add, instead of the app showing
    /// a raw identifier. Every identifier a model answers to counts, not only its main one (Codex's
    /// sixth look, T1: the 18 Pro Max is also iPhone19,7). From the iPhone XS on (iPhone11,x), the
    /// oldest iPhone iOS 17 runs on. The list is a folder on the Mac, which only a simulator run can
    /// read, so on a physical device this test skips, saying why.
    func testEveryIPhoneInXcodesDeviceListHasAName() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == nil,
                      "reads Xcode's device list from the Mac, which only a simulator run can reach")
        let root = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Profiles/DeviceTypes")
        let bundles = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "simdevicetype" }
        var checked: [String] = []
        var missing: [String] = []
        for bundle in bundles {
            let profile = bundle.appendingPathComponent("Contents/Resources/profile.plist")
            guard let data = try? Data(contentsOf: profile),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (plist["supportedProductFamilyIDs"] as? [Int])?.contains(1) == true,   // 1: iPhone
                  let main = plist["modelIdentifier"] as? String
            else { continue }
            let ids = Set([main] + (plist["representedModelIdentifiers"] as? [String] ?? []))
            for id in ids where id.hasPrefix("iPhone") {
                guard let major = Int(id.dropFirst("iPhone".count).prefix(while: \.isNumber)), major >= 11
                else { continue }
                checked.append(id)
                if DeviceInfo.marketingName(forIdentifier: id) == id {
                    missing.append("\(id) (\(bundle.deletingPathExtension().lastPathComponent))")
                }
            }
        }
        XCTAssertGreaterThan(checked.count, 20, "read too few iPhones from \(root.path): \(checked)")
        XCTAssertEqual(missing.sorted(), [], "add these to DeviceInfo.modelNames")
    }

    // MARK: - Rigs

    private struct HomeRig {
        let engine: MonitoringEngine
        let camera: FakeCamera
        let store: EventStore
        let settings: AppSettings
        let cloud: CloudExfiltrator
        let entitlements: ProEntitlements
    }

    private func makeHomeRig(_ configure: (AppSettings) -> Void = { _ in }) -> HomeRig {
        let settings = AppSettings()
        settings.gracePeriodSeconds = 0
        settings.requireGuidedAccess = false
        settings.enabledSensors.insert(.camera)
        settings.cameraReadiness = .instant   // the camera warms at arming
        configure(settings)
        let camera = FakeCamera()
        camera.micUnavailableForClips = true  // so the warm-up raises the microphone notice
        let store = EventStore()
        let cloud = CloudExfiltrator()
        let entitlements = ProEntitlements(resolvedAs: .trial)
        let engine = TestIsolation.track(MonitoringEngine(settings: settings, eventStore: store, cloud: cloud,
                                                          camera: camera, entitlements: entitlements,
                                                          timing: EngineCharacterizationTests.fastTiming))
        return HomeRig(engine: engine, camera: camera, store: store, settings: settings, cloud: cloud,
                       entitlements: entitlements)
    }

    /// Two notices on Home, as on the walk, raised the app's own way: the microphone notice by the
    /// warm-up at arming, the camera notice by a session failure while armed. Both outlast the disarm.
    private func raiseTwoNotices(_ rig: HomeRig) {
        rig.engine.beginArming()
        rig.engine.confirmGuidedAccessAndStartGrace()
        XCTAssertTrue(pump(until: { rig.engine.state == .armed && rig.engine.audioNotice != nil }, timeout: 5),
                      "armed, with the warm-up's microphone notice")
        rig.camera.onSessionEvent?(.runtimeError("The operation could not be completed. (AVFoundationErrorDomain error -11819.)"))
        XCTAssertNotNil(rig.engine.cameraNotice, "the session failure's notice")
        rig.engine.disarm()
        XCTAssertTrue(pump(until: { rig.engine.state == .disarmed }, timeout: 5))
        XCTAssertNotNil(rig.engine.cameraNotice, "still on Home after the disarm")
        XCTAssertNotNil(rig.engine.audioNotice, "still on Home after the disarm")
    }

    private func home(_ rig: HomeRig) -> some View {
        HomeView()
            .environmentObject(rig.engine)
            .environmentObject(rig.settings)
            .environmentObject(rig.cloud)
            .environmentObject(rig.store)
            .environmentObject(rig.entitlements)
    }

    private func pinSetup() -> some View {
        PINSetupView(savePIN: { _ in true }, onDone: {})
    }

    // MARK: - Laying out a real screen

    /// A scroll view's laid-out content height and its frame on screen.
    private struct Scroller {
        let contentHeight: CGFloat
        let frame: CGRect
    }

    /// The scroll views on screen when `view` is shown in a window of `size` (at the origin, safe
    /// areas ignored, so `size` is exactly the room the screen gets), measured before the window closes.
    private func scrollers<V: View>(of view: V, in size: CGSize) throws -> [Scroller] {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "the test host has no window scene")
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        let controller = UIHostingController(rootView: view)
        controller.safeAreaRegions = []
        window.rootViewController = controller
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        controller.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        controller.view.layoutIfNeeded()
        var found: [Scroller] = []
        var pending: [UIView] = [window]
        while let next = pending.popLast() {
            pending.append(contentsOf: next.subviews)
            guard let scroll = next as? UIScrollView, !scroll.isHidden, scroll.alpha > 0, scroll.bounds.height > 0
            else { continue }
            found.append(Scroller(contentHeight: scroll.contentSize.height,
                                  frame: scroll.convert(scroll.bounds, to: window)))
        }
        return found
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
}
